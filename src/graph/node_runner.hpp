#pragma once

#include "../core/types.hpp"
#include "../core/config.hpp"
#include "../core/state.hpp"
#include "../core/errors.hpp"
#include "../tools/tool.hpp"
#include <string>
#include <functional>

namespace agentgraph {

using NodeEventCallback = std::function<void(const std::string& event_type, const json& data)>;
using TokenCallback = std::function<void(const std::string& token)>;

class NodeRunner {
public:
    NodeRunner(ToolRegistry& tools,
               const TokenCallback& on_token = nullptr,
               const NodeEventCallback& on_event = nullptr,
               UsageTrackerPtr usage = nullptr)
        : tools_(tools), on_token_(on_token), on_event_(on_event), usage_(usage) {}

    Result<void> run_node(const NodeConfig& node, GraphState& state);

private:
    Result<void> run_llm_node(const NodeConfig& node, GraphState& state);
    Result<void> run_tool_node(const NodeConfig& node, GraphState& state);

    ToolRegistry& tools_;
    TokenCallback on_token_;
    NodeEventCallback on_event_;
    UsageTrackerPtr usage_;
};

} // namespace agentgraph
