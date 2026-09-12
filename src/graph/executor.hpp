#pragma once

#include "../core/config.hpp"
#include "../core/state.hpp"
#include "../core/errors.hpp"
#include "graph.hpp"
#include "node_runner.hpp"
#include "router.hpp"
#include "../tools/tool.hpp"
#include "BS_thread_pool.hpp"
#include <functional>
#include <memory>
#include <thread>

namespace agentgraph {

using EventCallback = std::function<void(const std::string& event_type, const json& data)>;

inline constexpr const char* INTERRUPTED_KEY = "__interrupted__";
inline constexpr const char* RESUME_NODE_KEY = "__resume_node__";
inline constexpr const char* RESUME_PATH_KEY = "__resume_path__";

class Executor {
public:
    Executor(ToolRegistry& tools,
             unsigned n_threads = 0,
             const TokenCallback& on_token = nullptr,
             const EventCallback& on_event = nullptr)
        : tools_(tools), n_threads_(n_threads == 0 ? std::thread::hardware_concurrency() : n_threads),
          on_token_(on_token), on_event_(on_event)
    {
        if (n_threads_ < 1) n_threads_ = 1;
        pool_ = std::make_unique<BS::light_thread_pool>(n_threads_);
    }

    Result<GraphState> run(const GraphConfig& config,
                           GraphState initial_state,
                           const std::string& resume_from = "");

private:
    Result<void> run_impl(const Graph& graph, GraphState& state, const std::string& resume_from);
    Result<void> run_parallel_node(const Graph& graph, const NodeConfig& node, GraphState& state);
    Result<void> run_subgraph_node(const NodeConfig& node, GraphState& state);

    ToolRegistry& tools_;
    unsigned n_threads_;
    TokenCallback on_token_;
    EventCallback on_event_;
    std::unique_ptr<BS::light_thread_pool> pool_;
};

} // namespace agentgraph
