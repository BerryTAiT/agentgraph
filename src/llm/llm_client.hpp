#pragma once

#include "../core/types.hpp"
#include "../core/config.hpp"
#include "../core/errors.hpp"
#include "http_client.hpp"
#include "sse_parser.hpp"
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
    std::unordered_map<std::string, std::string> build_headers() const;
};

inline std::unique_ptr<LLMClient> create_llm_client(const ProviderConfig& config) {
    return std::make_unique<OpenAIClient>(config);
}

} // namespace agentgraph
