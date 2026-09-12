#include <Rcpp.h>
#include "core/types.hpp"
#include "core/config.hpp"
#include "core/state.hpp"
#include "core/errors.hpp"
#include "llm/llm_client.hpp"
#include "tools/tool.hpp"
#include "tools/rpc_tool_client.hpp"
#include "tools/builtin/builtin_tools.hpp"
#include "graph/executor.hpp"
#include "type_converters.h"
#include "BS_thread_pool.hpp"

#include <memory>

using namespace agentgraph;

static bool list_has(const Rcpp::List& l, const std::string& name) {
    Rcpp::CharacterVector names = l.names();
    if (names.isNULL()) return false;
    for (int i = 0; i < names.size(); i++) {
        if (Rcpp::as<std::string>(names[i]) == name) return true;
    }
    return false;
}

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
Rcpp::List chat_native_cpp(std::string api_key,
                           std::string model,
                           std::string base_url,
                           Rcpp::List messages_r,
                           std::string system_prompt)
{
    ProviderConfig config;
    config.name = "openai";
    config.api_key = api_key;
    config.model = model;
    config.base_url = base_url;

    auto client = create_llm_client(config);
    auto messages = messages_from_list(messages_r);

    auto result = client->complete(messages, {}, system_prompt);
    if (result.is_err()) {
        Rcpp::stop(result.error().message);
    }

    return response_to_list(result.value());
}

// [[Rcpp::export]]
Rcpp::List chat_parallel_cpp(std::string api_key,
                             std::string model,
                             std::string base_url,
                             Rcpp::List messages_list,
                             std::string system_prompt,
                             int n_threads)
{
    // Each element of messages_list is itself a list of messages.
    int n = messages_list.size();
    if (n == 0) {
        return Rcpp::List();
    }

    ProviderConfig config;
    config.name = "openai";
    config.api_key = api_key;
    config.model = model;
    config.base_url = base_url;

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
            response.content = message["content"].get<std::string>();
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
                          int tool_server_port = 0)
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
            "127.0.0.1", static_cast<std::uint16_t>(tool_server_port));
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

    Executor executor(registry, static_cast<unsigned>(n_threads), token_cb);
    auto result = executor.run(config, std::move(state), resume_from);

    if (result.is_err()) {
        Rcpp::stop(result.error().message);
    }

    return state_to_list(result.value());
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
Rcpp::List rpc_call_cpp(int port, std::string tool_name, std::string args_json) {
    RpcToolClient client("127.0.0.1", static_cast<std::uint16_t>(port));
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
                          int n_calls = 8, int n_threads = 4) {
    RpcToolClient client("127.0.0.1", static_cast<std::uint16_t>(port));
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
