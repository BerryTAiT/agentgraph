#include "executor.hpp"

namespace agentgraph {

namespace {

bool is_interrupted(const GraphState& state) {
    if (!state.has(INTERRUPTED_KEY)) return false;
    json v = state.get(INTERRUPTED_KEY);
    return (v.is_boolean() && v.get<bool>()) ||
           (v.is_string() && v.get<std::string>() == "true");
}

} // namespace

Result<void> Executor::run_parallel_node(const Graph& graph, const NodeConfig& node, GraphState& state) {
    int n = static_cast<int>(node.sub_node_ids.size());
    if (n == 0) {
        return Result<void>::err("Parallel node '" + node.id + "' has no sub-nodes");
    }

    if (on_event_) {
        on_event_("parallel_start", json{{"node_id", node.id}, {"count", n}});
    }

    std::vector<std::string> errors(n);

    pool_->detach_sequence(0, n, [&](int i) {
        const std::string& sub_id = node.sub_node_ids[i];
        const NodeConfig& sub_node = graph.get_node(sub_id);
        NodeRunner runner(tools_, nullptr, nullptr, usage_);  // no token/event callbacks from worker threads
        auto r = runner.run_node(sub_node, state);
        if (r.is_err()) {
            errors[i] = r.error().message;
        }
    });
    pool_->wait();

    for (int i = 0; i < n; i++) {
        if (!errors[i].empty()) {
            return Result<void>::err(
                "Error in parallel sub-node '" + node.sub_node_ids[i] + "': " + errors[i]);
        }
    }

    if (on_event_) {
        on_event_("parallel_end", json{{"node_id", node.id}, {"count", n}});
    }

    return Result<void>::ok();
}

Result<void> Executor::run_subgraph_node(const NodeConfig& node, GraphState& state) {
    if (!node.sub_graph) {
        return Result<void>::err("Subgraph node '" + node.id + "' has no nested graph");
    }

    Graph subgraph(*node.sub_graph);
    auto validation = subgraph.validate();
    if (validation.is_err()) {
        return Result<void>::err(
            "Subgraph '" + node.id + "': " + validation.error().message);
    }

    // If we are resuming into this subgraph, consume the front of the resume
    // path: path[0] is this node, path[1] is the node to resume inside this
    // subgraph, and path[2:] descends into deeper subgraphs.
    std::string inner_resume;
    if (state.has(RESUME_PATH_KEY)) {
        json path = state.get(RESUME_PATH_KEY);
        if (path.is_array() && !path.empty() &&
            path[0].is_string() && path[0].get<std::string>() == node.id) {
            if (path.size() > 1 && path[1].is_string()) {
                inner_resume = path[1].get<std::string>();
            }
            if (path.size() > 2) {
                json rest = json::array();
                for (size_t i = 1; i < path.size(); i++) rest.push_back(path[i]);
                state.set(RESUME_PATH_KEY, rest);
            } else {
                state.erase(RESUME_PATH_KEY);
            }
        }
    }

    // A subgraph gets its own thread pool to avoid nested-pool deadlock when the
    // parent is already running a parallel section. It shares the parent's
    // budget + usage tracker so token limits accumulate across the whole run.
    Executor sub(tools_, n_threads_, on_token_, on_event_, on_checkpoint_, budget_, usage_);
    auto result = sub.run_impl(subgraph, state, inner_resume);
    if (result.is_err()) return result;

    // If the subgraph paused on an interrupt, propagate the resume point up to
    // this subgraph node and prepend our id to the resume path, so a top-level
    // resume() re-enters the subgraph and continues at the exact inner resume
    // node (not from the subgraph entry point).
    if (is_interrupted(state)) {
        json new_path = json::array({json(node.id)});
        if (state.has(RESUME_PATH_KEY)) {
            json existing = state.get(RESUME_PATH_KEY);
            if (existing.is_array()) {
                for (auto& el : existing) new_path.push_back(el);
            }
        } else {
            // Deepest level: append the local resume target set by the inner
            // interrupt node (its outgoing edge).
            json local = state.get(RESUME_NODE_KEY);
            if (local.is_string()) new_path.push_back(local);
        }
        state.set(RESUME_PATH_KEY, new_path);
        state.set(RESUME_NODE_KEY, node.id);
    }

    return Result<void>::ok();
}

Result<void> Executor::run_impl(const Graph& graph, GraphState& state, const std::string& resume_from) {
    NodeRunner runner(tools_, on_token_, on_event_, usage_);

    std::string current = resume_from.empty() ? graph.entry_point() : resume_from;
    int iterations = 0;
    int max_iter = graph.config().max_iterations;
    auto start = std::chrono::steady_clock::now();

    // Abort the run once a budget limit is exceeded. Token usage accumulates
    // in the shared UsageTracker across the whole run (incl. parallel/subgraph
    // nodes); wall-clock time is measured from the start of this run_impl.
    auto check_budget = [&]() -> Result<void> {
        if (budget_.max_total_tokens > 0 && usage_ &&
            usage_->total_tokens.load() > budget_.max_total_tokens) {
            return Result<void>::err(
                "Budget exceeded: max_total_tokens (" +
                std::to_string(budget_.max_total_tokens) + ")");
        }
        if (budget_.max_time_sec > 0) {
            double elapsed = std::chrono::duration<double>(
                std::chrono::steady_clock::now() - start).count();
            if (elapsed > budget_.max_time_sec) {
                return Result<void>::err(
                    "Budget exceeded: max_time_sec (" +
                    std::to_string(budget_.max_time_sec) + "s)");
            }
        }
        if (budget_.max_cost_usd > 0 && usage_ &&
            usage_->cost_usd.load() > budget_.max_cost_usd) {
            return Result<void>::err(
                "Budget exceeded: max_cost_usd (" +
                std::to_string(budget_.max_cost_usd) + ")");
        }
        return Result<void>::ok();
    };

    // Persist a crash-durable snapshot after each node completes. resume_node
    // records where execution should continue from: the outgoing target of the
    // just-finished node (or END_NODE when the graph is done), or the interrupt
    // node's resume target when execution paused.
    auto save_checkpoint = [&](const std::string& resume_node) {
        if (on_checkpoint_) on_checkpoint_(state, resume_node);
        if (on_event_) on_event_("checkpoint", json{{"resume_node", resume_node}});
    };

    while (current != END_NODE && iterations < max_iter) {
        iterations++;

        if (on_event_) {
            on_event_("iteration", json{
                {"iteration", iterations},
                {"current_node", current}
            });
        }

        auto& node = graph.get_node(current);

        Result<void> result;
        if (node.type == NodeType::Parallel) {
            result = run_parallel_node(graph, node, state);
        } else if (node.type == NodeType::Subgraph) {
            result = run_subgraph_node(node, state);
        } else if (node.type == NodeType::Interrupt) {
            // Pause execution. Record where to resume (the interrupt node's
            // outgoing target) and return the state to the caller.
            auto edges = graph.get_edges_from(current);
            std::string next = Router::resolve_next(edges, state);
            state.set(INTERRUPTED_KEY, true);
            state.set(RESUME_NODE_KEY, next);
            if (on_event_) {
                on_event_("interrupt", json{{"node_id", node.id}, {"resume_node", next}});
            }
            save_checkpoint(next);
            return Result<void>::ok();
        } else {
            result = runner.run_node(node, state);
        }

        if (result.is_err()) {
            return Result<void>::err(
                "Error in node '" + current + "': " + result.error().message);
        }

        // Enforce the run-level budget after every node completes.
        auto budget_check = check_budget();
        if (budget_check.is_err()) {
            return budget_check;
        }

        // If execution was paused (an interrupt node fired directly, or a
        // subgraph paused on an inner interrupt), stop without advancing.
        if (is_interrupted(state)) {
            std::string resume_node = current;
            if (state.has(RESUME_NODE_KEY) && state.get(RESUME_NODE_KEY).is_string()) {
                resume_node = state.get(RESUME_NODE_KEY).get<std::string>();
            }
            save_checkpoint(resume_node);
            return Result<void>::ok();
        }

        auto edges = graph.get_edges_from(current);
        std::string next = Router::resolve_next(edges, state);
        save_checkpoint(next);
        current = next;
    }

    if (iterations >= max_iter) {
        return Result<void>::err(
            "Graph exceeded maximum iterations (" + std::to_string(max_iter) + ")");
    }

    return Result<void>::ok();
}

Result<GraphState> Executor::run(const GraphConfig& config,
                                 GraphState initial_state,
                                 const std::string& resume_from) {
    Graph graph(config);
    auto validation = graph.validate();
    if (validation.is_err()) {
        return Result<GraphState>::err(validation.error().message);
    }

    auto state = std::move(initial_state);
    auto result = run_impl(graph, state, resume_from);

    if (result.is_err()) {
        return Result<GraphState>::err(result.error().message);
    }

    if (on_event_) {
        on_event_("complete", json{{"resumed", !resume_from.empty()}});
    }

    return Result<GraphState>::ok(std::move(state));
}

} // namespace agentgraph
