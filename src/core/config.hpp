#pragma once

#include "types.hpp"
#include <string>
#include <vector>
#include <unordered_map>
#include <functional>
#include <memory>

namespace agentgraph {

enum class NodeType {
    LLM,
    Tool,
    Router,
    Subgraph,
    Function,
    Parallel,
    Interrupt
};

inline std::string node_type_to_string(NodeType t) {
    switch (t) {
        case NodeType::LLM:       return "llm";
        case NodeType::Tool:      return "tool";
        case NodeType::Router:    return "router";
        case NodeType::Subgraph:  return "subgraph";
        case NodeType::Function:  return "function";
        case NodeType::Parallel:  return "parallel";
        case NodeType::Interrupt: return "interrupt";
    }
    return "llm";
}

struct ProviderConfig {
    std::string name;       // "openai", "anthropic", "ollama"
    std::string api_key;
    std::string base_url;
    std::string model;
    int max_tokens = 4096;
    double temperature = 0.7;

    static ProviderConfig openai(const std::string& api_key,
                                  const std::string& model = "gpt-4o",
                                  const std::string& base_url = "https://api.openai.com/v1") {
        ProviderConfig c;
        c.name = "openai";
        c.api_key = api_key;
        c.model = model;
        c.base_url = base_url;
        return c;
    }

    static ProviderConfig anthropic(const std::string& api_key,
                                     const std::string& model = "claude-sonnet-4-20250514",
                                     const std::string& base_url = "https://api.anthropic.com") {
        ProviderConfig c;
        c.name = "anthropic";
        c.api_key = api_key;
        c.model = model;
        c.base_url = base_url;
        return c;
    }

    static ProviderConfig ollama(const std::string& model = "llama3",
                                  const std::string& base_url = "http://localhost:11434/v1") {
        ProviderConfig c;
        c.name = "openai";
        c.api_key = "ollama";
        c.model = model;
        c.base_url = base_url;
        return c;
    }
};

struct GraphConfig;  // forward declaration for subgraphs

struct NodeConfig {
    std::string id;
    NodeType type = NodeType::LLM;
    ProviderConfig provider;
    std::string system_prompt;
    std::vector<std::string> tool_names;
    std::string description;
    std::vector<std::string> sub_node_ids;  // for Parallel nodes: run these concurrently
    std::shared_ptr<GraphConfig> sub_graph;  // for Subgraph nodes: nested graph
};

struct EdgeConfig {
    std::string from;
    std::string to;
    bool is_conditional = false;
    std::string route_field;
    std::unordered_map<std::string, std::string> route_map;
    std::string default_route;
};

struct GraphConfig {
    std::string entry_point;
    std::unordered_map<std::string, NodeConfig> nodes;
    std::vector<EdgeConfig> edges;
    int max_iterations = 25;
};

inline constexpr const char* END_NODE = "__end__";

} // namespace agentgraph
