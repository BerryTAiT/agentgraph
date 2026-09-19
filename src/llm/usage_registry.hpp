#pragma once

#include "../core/types.hpp"
#include <atomic>

namespace agentgraph {

// Process-global accumulator for token usage + estimated cost across every LLM
// call in the session. Mirrors the per-run UsageTracker but lives for the whole
// process, powering agentgraph_usage(). Cost is accumulated here (rather than
// computed later from token totals) because different providers/models have
// different per-token prices known at call time.
struct UsageRegistry {
    std::atomic<long long> prompt_tokens{0};
    std::atomic<long long> completion_tokens{0};
    std::atomic<long long> total_tokens{0};
    std::atomic<double> cost_usd{0.0};

    static UsageRegistry& instance() {
        static UsageRegistry inst;
        return inst;
    }

    void add(const TokenUsage& u, double cost) {
        prompt_tokens.fetch_add(u.prompt_tokens);
        completion_tokens.fetch_add(u.completion_tokens);
        total_tokens.fetch_add(u.total_tokens);
        cost_usd.fetch_add(cost);
    }

    void reset() {
        prompt_tokens = 0;
        completion_tokens = 0;
        total_tokens = 0;
        cost_usd = 0.0;
    }
};

} // namespace agentgraph
