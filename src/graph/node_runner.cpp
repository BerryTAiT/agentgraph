#include "node_runner.hpp"
#include "../llm/llm_client.hpp"
#include <chrono>
#include <sstream>

namespace agentgraph {

namespace {

// Flatten a message to its textual content (multimodal parts contribute text).
std::string message_to_text(const Message& m) {
    if (!m.parts.empty()) {
        std::string out;
        for (const auto& p : m.parts) {
            if (p.type == "text" && !p.text.empty()) {
                if (!out.empty()) out += "\n";
                out += p.text;
            }
        }
        return out;
    }
    return m.content;
}

std::string build_summary_input(const std::string& prev_summary,
                                const std::vector<Message>& evicted) {
    std::ostringstream oss;
    if (!prev_summary.empty()) {
        oss << "Previous summary:\n" << prev_summary << "\n\n";
    }
    oss << "New messages:\n";
    for (const auto& m : evicted) {
        std::string text = message_to_text(m);
        if (text.empty()) continue;
        oss << role_to_string(m.role) << ": " << text << "\n";
    }
    return oss.str();
}

const char* kDefaultSummaryPrompt =
    "Summarize the conversation concisely, preserving key facts, decisions, "
    "and user preferences. Return only the summary text.";

const char* kDefaultEntityPrompt =
    "Extract stable, reusable facts about the user (e.g. name, preferences, "
    "goals, constraints) from the exchange below. Respond with ONLY a JSON "
    "object mapping each fact key to its value. If there is nothing new, "
    "return {}.";

// Compress evicted messages into (and return) an updated running summary.
// Non-fatal: on any failure, the previous summary is preserved.
std::string summarize_evicted(LLMClient& client,
                              const GraphState& state,
                              const std::vector<Message>& evicted,
                              const MemoryConfig& mem) {
    std::string prev;
    json prev_json = state.get("conversation_summary");
    if (prev_json.is_string()) prev = prev_json.get<std::string>();

    std::string input = build_summary_input(prev, evicted);
    if (input.empty()) return prev;

    std::string sys = mem.summary_system_prompt.empty()
                          ? std::string(kDefaultSummaryPrompt)
                          : mem.summary_system_prompt;

    auto r = client.complete({Message::user(input)}, {}, sys);
    if (r.is_err()) return prev;
    std::string summary = r.value().content;
    return summary.empty() ? prev : summary;
}

// Extract named facts from the latest exchange and merge them into
// state["entities"]. Non-fatal: invalid JSON or an empty result is ignored.
void extract_and_store_entities(LLMClient& client,
                                GraphState& state,
                                const std::vector<Message>& messages,
                                const Message& assistant) {
    std::string user_text;
    for (auto it = messages.rbegin(); it != messages.rend(); ++it) {
        if (it->role == Role::User) {
            user_text = message_to_text(*it);
            break;
        }
    }
    std::string assistant_text = message_to_text(assistant);

    std::ostringstream oss;
    if (!user_text.empty()) oss << "User: " << user_text << "\n";
    if (!assistant_text.empty()) oss << "Assistant: " << assistant_text << "\n";
    std::string input = oss.str();
    if (input.empty()) return;

    auto r = client.complete({Message::user(input)}, {}, kDefaultEntityPrompt);
    if (r.is_err()) return;

    json extracted;
    try {
        extracted = json::parse(r.value().content);
    } catch (...) {
        return;
    }
    if (!extracted.is_object() || extracted.empty()) return;

    json entities = state.get("entities");
    if (!entities.is_object()) entities = json::object();
    for (auto it = extracted.begin(); it != extracted.end(); ++it) {
        entities[it.key()] = it.value();
    }
    state.set("entities", entities);
}

} // namespace

Result<void> NodeRunner::run_node(const NodeConfig& node, GraphState& state) {
    if (on_event_) {
        on_event_("node_start", json{{"node_id", node.id}, {"type", node_type_to_string(node.type)}});
    }

    Result<void> result;

    switch (node.type) {
        case NodeType::LLM:
            result = run_llm_node(node, state);
            break;
        case NodeType::Tool:
            result = run_tool_node(node, state);
            break;
        default:
            result = Result<void>::err("Unsupported node type: " + node_type_to_string(node.type));
    }

    if (on_event_) {
        if (result.is_ok()) {
            on_event_("node_end", json{{"node_id", node.id}, {"status", "success"}});
        } else {
            on_event_("node_end", json{{"node_id", node.id}, {"status", "error"},
                                        {"error", result.error().message}});
        }
    }

    return result;
}

Result<void> NodeRunner::run_llm_node(const NodeConfig& node, GraphState& state) {
    auto messages = state.get_messages();

    std::vector<ToolSchema> tool_schemas;
    if (!node.tool_names.empty()) {
        tool_schemas = tools_.get_schemas(node.tool_names);
    }

    auto client = create_llm_client(node.provider);

    // ---- Context-window memory management ----
    // Window buffer keeps only the last N messages; summary memory compresses
    // evicted messages into a running summary; entity memory injects known
    // facts. All are assembled into `to_send`, which replaces `messages` below.
    std::vector<Message> to_send;
    std::vector<Message> window = messages;

    if (node.memory.window_size > 0 &&
        static_cast<int>(window.size()) > node.memory.window_size) {
        std::vector<Message> evicted(
            window.begin(), window.end() - node.memory.window_size);
        window.assign(window.end() - node.memory.window_size, window.end());

        if (node.memory.summarize) {
            std::string summary = summarize_evicted(*client, state, evicted, node.memory);
            if (!summary.empty()) {
                state.set("conversation_summary", summary);
                to_send.push_back(Message::system(summary));
            }
        }
    }

    if (node.memory.entity_memory) {
        json entities = state.get("entities");
        if (entities.is_object() && !entities.empty()) {
            to_send.push_back(Message::system(
                "Known user facts (entity memory):\n" + entities.dump(2)));
        }
    }

    to_send.insert(to_send.end(), window.begin(), window.end());
    if (to_send.empty()) to_send = messages;

    if (on_event_) {
        on_event_("llm_start", json{{"node_id", node.id}, {"model", node.provider.model}});
    }

    auto t0 = std::chrono::steady_clock::now();
    Result<LLMResponse> result;
    if (on_token_) {
        result = client->complete_stream(to_send, on_token_, tool_schemas, node.system_prompt);
    } else {
        result = client->complete(to_send, tool_schemas, node.system_prompt);
    }
    auto t1 = std::chrono::steady_clock::now();
    double duration_ms = std::chrono::duration<double, std::milli>(t1 - t0).count();

    if (on_event_) {
        std::string err = result.is_ok() ? "" : result.error().message;
        on_event_("llm_end", json{
            {"node_id", node.id},
            {"duration_ms", duration_ms},
            {"success", result.is_ok()},
            {"error", err}
        });
    }

    if (result.is_err()) {
        return Result<void>::err(result.error().message);
    }

    auto& response = result.value();

    // Per-run budget accounting (max_total_tokens / max_cost_usd). The global
    // session accumulator lives in the LLM client so it also covers chat().
    if (usage_) usage_->total_tokens.fetch_add(response.usage.total_tokens);
    double cost = (response.usage.prompt_tokens * node.provider.input_price_per_1m +
                   response.usage.completion_tokens * node.provider.output_price_per_1m) / 1e6;
    if (usage_) usage_->cost_usd.fetch_add(cost);

    Message assistant_msg;
    assistant_msg.role = Role::Assistant;
    assistant_msg.content = response.content;
    assistant_msg.tool_calls = response.tool_calls;
    state.add_message(assistant_msg);

    if (node.memory.entity_memory) {
        extract_and_store_entities(*client, state, messages, assistant_msg);
    }

    state.set("last_response", json(response));
    state.set("last_finish_reason", finish_reason_to_string(response.finish_reason));

    bool has_tool_calls = response.finish_reason == FinishReason::ToolCalls ||
                          !response.tool_calls.empty();
    state.set("has_tool_calls", has_tool_calls);

    if (on_event_) {
        on_event_("llm_response", json(response));
    }

    return Result<void>::ok();
}

Result<void> NodeRunner::run_tool_node(const NodeConfig& node, GraphState& state) {
    auto messages = state.get_messages();
    if (messages.empty()) {
        return Result<void>::err("No messages in state for tool node");
    }

    auto& last_msg = messages.back();
    if (last_msg.tool_calls.empty()) {
        return Result<void>::err("Last message has no tool calls");
    }

    for (auto& tc : last_msg.tool_calls) {
        if (on_event_) {
            on_event_("tool_call", json{{"name", tc.name}, {"arguments", tc.arguments}});
        }

        auto result = tools_.execute(tc.name, tc.arguments);

        Message tool_result_msg;
        tool_result_msg.role = Role::Tool;
        tool_result_msg.tool_call_id = tc.id;
        tool_result_msg.name = tc.name;

        if (result.is_ok()) {
            tool_result_msg.content = result.value().dump();
        } else {
            tool_result_msg.content = json{{"error", result.error().message}}.dump();
        }

        state.add_message(tool_result_msg);

        if (on_event_) {
            on_event_("tool_result", json{
                {"name", tc.name},
                {"result", tool_result_msg.content},
                {"success", result.is_ok()}
            });
        }
    }

    state.set("has_tool_calls", false);

    return Result<void>::ok();
}

} // namespace agentgraph
