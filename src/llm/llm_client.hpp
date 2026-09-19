#pragma once

#include "../core/types.hpp"
#include "../core/config.hpp"
#include "../core/errors.hpp"
#include "http_client.hpp"
#include "sse_parser.hpp"
#include "llm_cache.hpp"
#include <memory>
#include <string>
#include <vector>
#include <functional>

namespace agentgraph {

using TokenCallback = std::function<void(const std::string& token)>;

class LLMClient {
public:
    virtual ~LLMClient() = default;

    virtual Result<LLMResponse> complete(
        const std::vector<Message>& messages,
        const std::vector<ToolSchema>& tools = {},
        const std::string& system_prompt = "") = 0;

    virtual Result<LLMResponse> complete_stream(
        const std::vector<Message>& messages,
        const TokenCallback& on_token,
        const std::vector<ToolSchema>& tools = {},
        const std::string& system_prompt = "") = 0;
};

class OpenAIClient : public LLMClient {
public:
    explicit OpenAIClient(const ProviderConfig& config);

    Result<LLMResponse> complete(
        const std::vector<Message>& messages,
        const std::vector<ToolSchema>& tools = {},
        const std::string& system_prompt = "") override;

    Result<LLMResponse> complete_stream(
        const std::vector<Message>& messages,
        const TokenCallback& on_token,
        const std::vector<ToolSchema>& tools = {},
        const std::string& system_prompt = "") override;

private:
    ProviderConfig config_;
    HttpClient http_;

    json build_request(const std::vector<Message>& messages,
                       const std::vector<ToolSchema>& tools,
                       const std::string& system_prompt,
                       bool stream) const;

    json build_tool_schema(const ToolSchema& tool) const;
    LLMResponse parse_response(const json& resp) const;

    // Full endpoint URL (adds ?api-version= for Azure).
    std::string url_for() const;
    // Auth headers; the request body is needed for Bedrock SigV4 signing.
    std::unordered_map<std::string, std::string> build_headers(const std::string& body) const;
};

// A client that tries a chain of underlying clients in order. Each entry is
// attempted only after the previous one fails hard (its own retries are
// exhausted or it returned a non-transient error). The first successful
// result is returned; if every provider fails, the last error is surfaced.
// This is a transparent LLMClient, so graph nodes and chat() use it exactly
// like any single provider.
class FallbackClient : public LLMClient {
public:
    explicit FallbackClient(std::vector<std::unique_ptr<LLMClient>> chain);

    Result<LLMResponse> complete(
        const std::vector<Message>& messages,
        const std::vector<ToolSchema>& tools = {},
        const std::string& system_prompt = "") override;

    Result<LLMResponse> complete_stream(
        const std::vector<Message>& messages,
        const TokenCallback& on_token,
        const std::vector<ToolSchema>& tools = {},
        const std::string& system_prompt = "") override;

private:
    std::vector<std::unique_ptr<LLMClient>> chain_;
};

// Transparent exact-cache wrapper. It computes a deterministic key from the
// full request (messages + tools + system prompt + provider/model/sampling
// identity) and serves identical requests from an in-memory cache shared
// process-wide via LLMCacheRegistry. Only successful responses are cached;
// failures always fall through to the inner client. Caching applies to the
// whole fallback chain (the final answer), not each hop individually.
class CachedLLMClient : public LLMClient {
public:
    CachedLLMClient(std::unique_ptr<LLMClient> inner, const ProviderConfig& config);

    Result<LLMResponse> complete(
        const std::vector<Message>& messages,
        const std::vector<ToolSchema>& tools = {},
        const std::string& system_prompt = "") override;

    Result<LLMResponse> complete_stream(
        const std::vector<Message>& messages,
        const TokenCallback& on_token,
        const std::vector<ToolSchema>& tools = {},
        const std::string& system_prompt = "") override;

private:
    std::unique_ptr<LLMClient> inner_;
    ProviderConfig config_;
    std::string ns_;
    std::shared_ptr<LLMCache> cache_;

    std::string make_key(const std::vector<Message>& messages,
                         const std::vector<ToolSchema>& tools,
                         const std::string& system_prompt) const;
};

// Builds a client with no caching wrapper. Used as the inner client of
// CachedLLMClient and for each fallback entry, so a fallback chain is cached
// once (by its top-level config) rather than per hop.
inline std::unique_ptr<LLMClient> create_uncached_client(const ProviderConfig& config) {
    if (!config.fallbacks.empty()) {
        std::vector<std::unique_ptr<LLMClient>> chain;
        chain.reserve(config.fallbacks.size());
        for (const auto& fb : config.fallbacks) {
            chain.push_back(create_uncached_client(fb));
        }
        return std::make_unique<FallbackClient>(std::move(chain));
    }
    return std::make_unique<OpenAIClient>(config);
}

inline std::unique_ptr<LLMClient> create_llm_client(const ProviderConfig& config) {
    auto base = create_uncached_client(config);
    if (config.cache_ttl_seconds > 0) {
        return std::make_unique<CachedLLMClient>(std::move(base), config);
    }
    return base;
}

} // namespace agentgraph
