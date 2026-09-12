#include "node_runner.hpp"
#include "../llm/llm_client.hpp"

namespace agentgraph {

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
    Result<LLMResponse> result;
    if (on_token_) {
        result = client->complete_stream(messages, on_token_, tool_schemas, node.system_prompt);
    } else {
        result = client->complete(messages, tool_schemas, node.system_prompt);
    }
    if (result.is_err()) {
        return Result<void>::err(result.error().message);
    }

    auto& response = result.value();

    Message assistant_msg;
    assistant_msg.role = Role::Assistant;
    assistant_msg.content = response.content;
    assistant_msg.tool_calls = response.tool_calls;
    state.add_message(assistant_msg);

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
