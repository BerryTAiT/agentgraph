#include <Rcpp.h>
#include "core/types.hpp"
#include "core/config.hpp"
#include "core/state.hpp"
#include "core/errors.hpp"
#include "llm/llm_client.hpp"
#include "llm/usage_registry.hpp"
#include "tools/tool.hpp"
#include "tools/rpc_tool_client.hpp"
#include "tools/builtin/builtin_tools.hpp"
#include "graph/executor.hpp"
#include "type_converters.h"
#include "BS_thread_pool.hpp"

#include <memory>
#include <fstream>
#include <sstream>
#include <cstdio>
#include <chrono>
#include <mutex>

#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#endif

using namespace agentgraph;

static bool list_has(const Rcpp::List& l, const std::string& name) {
    Rcpp::CharacterVector names = l.names();
    if (names.isNULL()) return false;
    for (int i = 0; i < names.size(); i++) {
        if (Rcpp::as<std::string>(names[i]) == name) return true;
    }
    return false;
}

// Atomic write of a checkpoint file: serialize to a temp file, flush, then
// atomically rename over the destination. This keeps the checkpoint intact if
// the process is killed mid-write. Best-effort: a failed write leaves the
// previous checkpoint (if any) untouched.
static void atomic_write_file(const std::string& path, const std::string& content) {
    std::string tmp = path + ".tmp";
    {
        std::ofstream out(tmp, std::ios::binary | std::ios::trunc);
        if (!out.is_open()) return;
        out.write(content.data(), static_cast<std::streamsize>(content.size()));
        out.flush();
        if (!out.good()) {
            out.close();
            std::remove(tmp.c_str());
            return;
        }
        out.close();
    }
#ifdef _WIN32
    if (!MoveFileExA(tmp.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING)) {
        std::remove(path.c_str());
        std::rename(tmp.c_str(), path.c_str());
    }
#else
    if (std::rename(tmp.c_str(), path.c_str()) != 0) {
        std::remove(tmp.c_str());
    }
#endif
}

// Serialize a GraphState plus a resume marker into the checkpoint JSON format:
//   {"version":1, "resume_node":"...", "state":{"data":{...},"messages":[...]}}
static void write_checkpoint(const std::string& path,
                             const GraphState& state,
                             const std::string& resume_node) {
    json j;
    j["version"] = 1;
    j["resume_node"] = resume_node;
    j["state"] = state.to_json();
    atomic_write_file(path, j.dump(2));
}

// Structured JSONL tracer: appends one JSON object per line for every engine
// event (node / llm / tool / checkpoint lifecycle), so a run can be inspected
// and replayed offline. spdlog is not vendored, so this is a minimal,
// dependency-free equivalent: thread-safe appends with a millisecond epoch
// timestamp. Events are also forwarded to the R on_event callback when one is
// supplied, so a single run can drive both a live UI and a durable trace file.
struct TraceLogger {
    std::mutex mu;
    std::ofstream out;
    explicit TraceLogger(const std::string& path) {
        out.open(path, std::ios::app | std::ios::binary);
    }
    void log(const std::string& event_type, const json& data) {
        if (!out.is_open()) return;
        json entry;
        entry["ts_ms"] = std::chrono::duration_cast<std::chrono::milliseconds>(
                             std::chrono::system_clock::now().time_since_epoch())
                             .count();
        entry["event"] = event_type;
        entry["data"] = data;
        std::lock_guard<std::mutex> lk(mu);
        out << entry.dump() << "\n";
        out.flush();
    }
};

// [[Rcpp::export]]
std::string hello_cpp() {
    return "agentgraph C++ engine is alive";
}

// Diagnostic: raw HTTP GET to verify the native client + OpenSSL stack.
// [[Rcpp::export]]
Rcpp::List http_get_cpp(std::string url) {
    HttpClient http;
    auto result = http.get(url);
    if (result.is_err()) {
        Rcpp::stop(result.error().message);
    }
    auto& resp = result.value();
    Rcpp::List out;
    out["status_code"] = resp.status_code;
    out["body_length"] = static_cast<int>(resp.body.size());
    out["body_preview"] = resp.body.substr(0, 200);
    return out;
}

// [[Rcpp::export]]
Rcpp::List chat_native_cpp(Rcpp::List provider,
                           Rcpp::List messages_r,
                           std::string system_prompt)
{
    ProviderConfig config = provider_from_list(provider);

    auto client = create_llm_client(config);
    auto messages = messages_from_list(messages_r);

    auto result = client->complete(messages, {}, system_prompt);
    if (result.is_err()) {
        Rcpp::stop(result.error().message);
    }

    return response_to_list(result.value());
}

// [[Rcpp::export]]
Rcpp::List chat_parallel_cpp(Rcpp::List provider,
                             Rcpp::List messages_list,
                             std::string system_prompt,
                             int n_threads)
{
    // Each element of messages_list is itself a list of messages.
    int n = messages_list.size();
    if (n == 0) {
        return Rcpp::List();
    }

    ProviderConfig config = provider_from_list(provider);

    // Pre-convert all messages to C++ on the main thread (R API is not
    // thread-safe, so all R object access happens here).
    std::vector<std::vector<Message>> all_messages(n);
    for (int i = 0; i < n; i++) {
        all_messages[i] = messages_from_list(messages_list[i]);
    }

    // Results indexed by request order.
    std::vector<LLMResponse> results(n);
    std::vector<std::string> errors(n);

    if (n_threads <= 1 || n == 1) {
        // Sequential fallback.
        for (int i = 0; i < n; i++) {
            auto client = create_llm_client(config);
            auto r = client->complete(all_messages[i], {}, system_prompt);
            if (r.is_err()) errors[i] = r.error().message;
            else results[i] = std::move(r.value());
        }
    } else {
        // Parallel execution on a thread pool. No R API calls happen inside
        // the worker threads; each thread uses its own HTTP client.
        BS::thread_pool pool(static_cast<unsigned int>(n_threads));
        pool.detach_sequence(0, n, [&](int i) {
            auto client = create_llm_client(config);
            auto r = client->complete(all_messages[i], {}, system_prompt);
            if (r.is_err()) errors[i] = r.error().message;
            else results[i] = std::move(r.value());
        });
        pool.wait();
    }

    Rcpp::List out;
    for (int i = 0; i < n; i++) {
        if (!errors[i].empty()) {
            Rcpp::List err_list;
            err_list["error"] = errors[i];
            out.push_back(err_list);
        } else {
            out.push_back(response_to_list(results[i]));
        }
    }
    return out;
}

// [[Rcpp::export]]
Rcpp::List parse_llm_response_cpp(std::string response_json) {
    try {
        auto parsed = json::parse(response_json);
        LLMResponse response;

        if (parsed.contains("error")) {
            response.error_message = parsed["error"].value("message", "Unknown error");
            response.finish_reason = FinishReason::Error;
            return response_to_list(response);
        }

        auto& choice = parsed["choices"][0];
        auto& message = choice["message"];

        if (message.contains("content") && !message["content"].is_null()) {
            response.content = content_to_string(message["content"]);
        } else {
            response.content = "";
        }

        if (message.contains("tool_calls") && !message["tool_calls"].is_null()) {
            for (auto& tc : message["tool_calls"]) {
                ToolCall call;
                call.id = tc["id"].get<std::string>();
                call.name = tc["function"]["name"].get<std::string>();
                try {
                    call.arguments = json::parse(tc["function"]["arguments"].get<std::string>());
                } catch (...) {
                    call.arguments = json::object();
                }
                response.tool_calls.push_back(call);
            }
        }

        if (choice.contains("finish_reason") && !choice["finish_reason"].is_null()) {
            response.finish_reason = string_to_finish_reason(choice["finish_reason"].get<std::string>());
        }

        if (parsed.contains("usage")) {
            auto& u = parsed["usage"];
            response.usage.prompt_tokens = u.value("prompt_tokens", 0);
            response.usage.completion_tokens = u.value("completion_tokens", 0);
            response.usage.total_tokens = u.value("total_tokens", 0);
        }

        response.model = parsed.value("model", "");
        return response_to_list(response);
    } catch (const std::exception& e) {
        Rcpp::stop(std::string("Failed to parse LLM response: ") + e.what());
    }
}

// [[Rcpp::export]]
Rcpp::List run_graph_cpp(Rcpp::List graph_config,
                          Rcpp::List state_data,
                          Rcpp::List messages_r,
                          Rcpp::List tools_r,
                          int n_threads = 0,
                          Rcpp::Nullable<Rcpp::Function> on_token = R_NilValue,
                          std::string resume_from = "",
                          int tool_server_port = 0,
                          std::string tool_server_token = "",
                          Rcpp::Nullable<Rcpp::Function> on_event = R_NilValue,
                          std::string checkpoint_path = "",
                          std::string log_path = "",
                          int max_total_tokens = 0,
                          double max_time_sec = 0.0,
                          double max_cost_usd = 0.0)
{
    auto config = graph_from_list(graph_config);

    GraphState state;
    auto messages = messages_from_list(messages_r);
    state.set_messages(messages);

    if (state_data.size() > 0) {
        Rcpp::CharacterVector keys = state_data.names();
        for (int i = 0; i < keys.size(); i++) {
            std::string key = Rcpp::as<std::string>(keys[i]);
            std::string val_str = Rcpp::as<std::string>(
                Rcpp::as<Rcpp::CharacterVector>(state_data[i])[0]);
            state.set(key, json::parse(val_str));
        }
    }

    ToolRegistry registry;
    register_builtin_tools(registry);

    // Custom R tools are executed in an isolated R tool-server process and
    // reached over TCP. This keeps R callbacks off the C++ worker threads
    // (the main R thread is blocked inside this call, and R is not
    // thread-safe), so parallel fan-out stays safe.
    std::unique_ptr<RpcToolClient> rpc_client;
    if (tool_server_port > 0) {
        rpc_client = std::make_unique<RpcToolClient>(
            "127.0.0.1", static_cast<std::uint16_t>(tool_server_port),
            tool_server_token);
    }

    if (tools_r.size() > 0) {
        for (int i = 0; i < tools_r.size(); i++) {
            Rcpp::List tool_list = tools_r[i];
            std::string name = Rcpp::as<std::string>(tool_list["name"]);
            std::string desc = "";
            if (list_has(tool_list, "description")) {
                desc = Rcpp::as<std::string>(tool_list["description"]);
            }
            json params = json::object();
            if (list_has(tool_list, "parameters_json")) {
                std::string pj = Rcpp::as<std::string>(
                    Rcpp::as<Rcpp::CharacterVector>(tool_list["parameters_json"])[0]);
                params = json::parse(pj);
            }

            if (rpc_client) {
                RpcToolClient* client = rpc_client.get();
                std::string tool_name = name;
                registry.register_tool(name, desc, params,
                    [client, tool_name](const json& args) -> Result<json> {
                        return client->call(tool_name, args);
                    });
            } else {
                // Direct in-process callback. Only safe for sequential graph
                // execution; run() always uses the tool server instead.
                Rcpp::Function handler = tool_list["handler"];
                registry.register_tool(name, desc, params,
                    [handler](const json& args) -> Result<json> {
                        try {
                            std::string args_str = args.dump();
                            Rcpp::CharacterVector r_result = handler(
                                Rcpp::wrap(Rcpp::CharacterVector(args_str)));
                            std::string result_str = Rcpp::as<std::string>(r_result[0]);
                            return Result<json>::ok(json::parse(result_str));
                        } catch (std::exception& e) {
                            return Result<json>::err(e.what());
                        }
                    });
            }
        }
    }

    TokenCallback token_cb = nullptr;
    if (on_token.isNotNull()) {
        Rcpp::Function f = on_token.get();
        token_cb = [f](const std::string& token) {
            f(Rcpp::wrap(token));
        };
    }

    // Event callback: fires on the main thread for node/tool/LLM lifecycle
    // events. The engine already emits node_start/node_end/llm_response/
    // tool_call/tool_result/iteration/parallel_start/parallel_end; expose them
    // to R so dashboards, tracers, and UIs can observe execution live. When
    // log_path is set, every event is also appended to a JSONL trace file.
    std::shared_ptr<TraceLogger> tracer;
    if (!log_path.empty()) {
        tracer = std::make_shared<TraceLogger>(log_path);
    }

    EventCallback event_cb = nullptr;
    if (on_event.isNotNull()) {
        Rcpp::Function f = on_event.get();
        event_cb = [f, tracer](const std::string& event_type, const json& data) {
            if (tracer) tracer->log(event_type, data);
            f(Rcpp::wrap(event_type), Rcpp::wrap(data.dump()));
        };
    } else if (tracer) {
        event_cb = [tracer](const std::string& event_type, const json& data) {
            tracer->log(event_type, data);
        };
    }

    // Crash-durable checkpointing: when checkpoint_path is set, persist the
    // state (plus a resume marker) after every node and on interrupt. Runs on
    // the main thread, never on the worker pool.
    CheckpointCallback checkpoint_cb = nullptr;
    if (!checkpoint_path.empty()) {
        std::string cp_path = checkpoint_path;
        checkpoint_cb = [cp_path](const GraphState& st, const std::string& resume_node) {
            write_checkpoint(cp_path, st, resume_node);
        };
    }

    BudgetConfig budget;
    budget.max_total_tokens = max_total_tokens;
    budget.max_time_sec = max_time_sec;
    budget.max_cost_usd = max_cost_usd;
    auto usage = std::make_shared<UsageTracker>();

    Executor executor(registry, static_cast<unsigned>(n_threads), token_cb, event_cb, checkpoint_cb,
                      budget, usage);
    auto result = executor.run(config, std::move(state), resume_from);

    if (result.is_err()) {
        Rcpp::stop(result.error().message);
    }

    return state_to_list(result.value());
}

// Load a checkpoint file into (state, resume_node). Returns a list with
// `state` (same shape as run()'s return: `data` + `messages`) and `resume_node`
// (empty or "__end__" means the run had already completed).
// [[Rcpp::export]]
Rcpp::List checkpoint_load_cpp(std::string checkpoint_path) {
    std::ifstream in(checkpoint_path, std::ios::binary);
    if (!in.is_open()) {
        Rcpp::stop("Checkpoint file not found: " + checkpoint_path);
    }
    std::stringstream ss;
    ss << in.rdbuf();
    std::string content = ss.str();

    json j;
    try {
        j = json::parse(content);
    } catch (const std::exception& e) {
        Rcpp::stop(std::string("Failed to parse checkpoint file: ") + e.what());
    }

    GraphState state;
    if (j.is_object() && j.contains("state") && j["state"].is_object()) {
        state = GraphState::from_json(j["state"]);
    } else {
        // Legacy format: the whole file is the state object.
        state = GraphState::from_json(j);
    }

    std::string resume_node;
    if (j.is_object() && j.contains("resume_node") && j["resume_node"].is_string()) {
        resume_node = j["resume_node"].get<std::string>();
    }

    Rcpp::List out;
    out["state"] = state_to_list(state);
    out["resume_node"] = resume_node;
    return out;
}

// Clear the process-wide LLM exact cache. With an empty namespace, all
// provider caches are cleared; with a namespace, only that provider's cache.
// [[Rcpp::export]]
void cache_clear_cpp(std::string ns = "") {
    if (ns.empty()) {
        LLMCacheRegistry::instance().clear_all();
    } else {
        LLMCacheRegistry::instance().clear(ns);
    }
}

// Snapshot of the process-wide LLM exact cache: one row per provider
// namespace with its current entry count. Namespace strings encode
// name|base_url|model|api_version (the same key used by CachedLLMClient).
// [[Rcpp::export]]
Rcpp::DataFrame cache_stats_cpp() {
    auto snap = LLMCacheRegistry::instance().snapshot();
    int n = static_cast<int>(snap.size());
    Rcpp::CharacterVector ns(n);
    Rcpp::IntegerVector counts(n);
    for (int i = 0; i < n; i++) {
        ns[i] = snap[static_cast<size_t>(i)].first;
        counts[i] = static_cast<int>(snap[static_cast<size_t>(i)].second);
    }
    return Rcpp::DataFrame::create(
        Rcpp::Named("namespace") = ns,
        Rcpp::Named("entries") = counts);
}

// Reset the process-wide session usage accumulator (tokens + estimated cost).
// [[Rcpp::export]]
void usage_reset_cpp() {
    UsageRegistry::instance().reset();
}

// Snapshot of the process-wide session usage accumulator.
// [[Rcpp::export]]
Rcpp::List usage_stats_cpp() {
    auto& u = UsageRegistry::instance();
    return Rcpp::List::create(
        Rcpp::Named("prompt_tokens") = static_cast<double>(u.prompt_tokens.load()),
        Rcpp::Named("completion_tokens") = static_cast<double>(u.completion_tokens.load()),
        Rcpp::Named("total_tokens") = static_cast<double>(u.total_tokens.load()),
        Rcpp::Named("cost_usd") = u.cost_usd.load());
}

// Process-global LLM cache hit/miss counters (for metrics).
// [[Rcpp::export]]
Rcpp::List cache_hit_stats_cpp() {
    auto& reg = LLMCacheRegistry::instance();
    return Rcpp::List::create(
        Rcpp::Named("hits") = static_cast<double>(reg.hits()),
        Rcpp::Named("misses") = static_cast<double>(reg.misses()));
}

// [[Rcpp::export]]
Rcpp::List test_tool_cpp(std::string tool_name, std::string args_json) {
    ToolRegistry registry;
    register_builtin_tools(registry);

    json args = json::parse(args_json);
    auto result = registry.execute(tool_name, args);

    Rcpp::List out;
    if (result.is_ok()) {
        out["success"] = true;
        out["result"] = result.value().dump();
    } else {
        out["success"] = false;
        out["error"] = result.error().message;
    }
    return out;
}

// Test hook: execute one RPC tool call against a running tool server.
// [[Rcpp::export]]
Rcpp::List rpc_call_cpp(int port, std::string tool_name, std::string args_json,
                        std::string token = "") {
    RpcToolClient client("127.0.0.1", static_cast<std::uint16_t>(port), token);
    json args;
    try { args = json::parse(args_json); } catch (...) { args = json::object(); }

    auto r = client.call(tool_name, args);
    Rcpp::List out;
    if (r.is_ok()) {
        out["ok"] = true;
        out["result"] = r.value().dump();
    } else {
        out["ok"] = false;
        out["error"] = r.error().message;
    }
    return out;
}

// Test hook: concurrent RPC tool calls from C++ worker threads. Proves the
// client (shared connection + mutex) and the tool server stay correct under
// parallel fan-out.
// [[Rcpp::export]]
Rcpp::List rpc_stress_cpp(int port, std::string tool_name, std::string args_json,
                          int n_calls = 8, int n_threads = 4,
                          std::string token = "") {
    RpcToolClient client("127.0.0.1", static_cast<std::uint16_t>(port), token);
    json args;
    try { args = json::parse(args_json); } catch (...) { args = json::object(); }

    int n = std::max(n_calls, 1);
    std::vector<std::string> results(static_cast<size_t>(n));
    std::vector<std::string> errors(static_cast<size_t>(n));

    BS::thread_pool pool(static_cast<unsigned int>(std::max(n_threads, 1)));
    pool.detach_sequence(0, n, [&](int i) {
        auto r = client.call(tool_name, args);
        if (r.is_ok()) results[static_cast<size_t>(i)] = r.value().dump();
        else errors[static_cast<size_t>(i)] = r.error().message;
    });
    pool.wait();

    int ok_count = 0;
    Rcpp::List calls;
    for (int i = 0; i < n; i++) {
        Rcpp::List item;
        item["ok"] = errors[static_cast<size_t>(i)].empty();
        item["result"] = results[static_cast<size_t>(i)];
        item["error"] = errors[static_cast<size_t>(i)];
        calls.push_back(item);
        if (errors[static_cast<size_t>(i)].empty()) ok_count++;
    }

    Rcpp::List out;
    out["n"] = n;
    out["ok"] = ok_count;
    out["calls"] = calls;
    return out;
}
