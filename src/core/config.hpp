#pragma once

#include "types.hpp"
#include <string>
#include <vector>
#include <unordered_map>
#include <functional>
#include <memory>
#include <atomic>

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
    std::string name;       // "openai", "anthropic", "azure", "bedrock", "ollama"
    std::string api_key;
    std::string base_url;
    std::string model;
    int max_tokens = 4096;
    double temperature = 0.7;

    // Retry + backoff for transient HTTP failures (429, 5xx) and network errors.
    // max_retries == 0 disables retrying; delays grow exponentially from
    // retry_base_delay_ms up to retry_max_delay_ms.
    int max_retries = 3;
    int retry_base_delay_ms = 500;
    int retry_max_delay_ms = 8000;

    // Requests-per-minute cap (token bucket). 0 means no rate limiting.
    int requests_per_minute = 0;

    // Azure OpenAI: appended as ?api-version=... to the chat URL
    std::string api_version;

    // AWS Bedrock: SigV4 credentials (region is also embedded in base_url)
    std::string aws_access_key_id;
    std::string aws_secret_access_key;
    std::string aws_session_token;
    std::string aws_region;

    // Provider fallback chain. When non-empty, this config represents a
    // fallback provider: each entry is tried in order and the first hard
    // success wins. create_llm_client() builds a FallbackClient from this
    // list (entry 0 is the primary). Empty for every normal provider.
    std::vector<ProviderConfig> fallbacks;

    // LLM exact cache. When cache_ttl_seconds > 0, successful completions are
    // cached in-memory and reused for an identical request (messages + tools +
    // system prompt + provider/model/sampling identity), skipping the HTTP
    // round-trip. Entries are shared across chat() and graph calls within the
    // process. 0 disables caching. cache_max_entries caps the per-provider
    // cache; 0 means unlimited.
    int cache_ttl_seconds = 0;
    int cache_max_entries = 0;

    // PII filter: when true, message content, text parts, tool results, and
    // the system prompt are redacted (emails, phone numbers, credit cards,
    // SSNs, API keys, IPs) before being sent to the LLM endpoint. pii_redact
    // is the replacement text.
    bool pii_filter = false;
    std::string pii_redact = "[REDACTED]";

    // Per-token pricing in USD per 1M tokens. 0 means "cost not tracked" for
    // this provider. Used to estimate cost (max_cost_usd budget + usage stats).
    double input_price_per_1m = 0.0;
    double output_price_per_1m = 0.0;

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

// Context-window memory management for LLM nodes, applied before each LLM
// call so a long conversation never overflows the model's context limit.
struct MemoryConfig {
    // Window buffer: when > 0, only the last `window_size` messages are sent
    // to the model. 0 disables windowing (send everything).
    int window_size = 0;

    // Summary memory: when true (and window_size > 0), messages evicted by the
    // window are compressed into a running summary stored under
    // state["conversation_summary"] and injected as a leading system message.
    bool summarize = false;

    // Entity memory: when true, named facts are extracted from each turn and
    // stored under state["entities"] (a JSON object); existing facts are
    // injected as context on subsequent turns.
    bool entity_memory = false;

    // Optional custom system prompt for the summarization LLM call. When empty,
    // a built-in prompt is used.
    std::string summary_system_prompt;
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
    MemoryConfig memory;  // context-window / summary / entity memory settings
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

// Shared, thread-safe accumulator for token usage across an entire graph run
// (including parallel and subgraph nodes). Used by the budget/kill switch.
struct UsageTracker {
    std::atomic<long long> total_tokens{0};
    std::atomic<double> cost_usd{0.0};
};
using UsageTrackerPtr = std::shared_ptr<UsageTracker>;

// Run-level budget limits. 0 means unlimited. When a limit is exceeded the
// executor aborts the run with a "Budget exceeded" error. These are per-run
// (passed to run()), not stored on the graph.
struct BudgetConfig {
    int max_total_tokens = 0;   // cumulative prompt+completion tokens across LLM calls
    double max_time_sec = 0.0;  // wall-clock seconds since the run started
    double max_cost_usd = 0.0;  // estimated cost in USD (needs provider pricing set)
};

inline constexpr const char* END_NODE = "__end__";

} // namespace agentgraph
