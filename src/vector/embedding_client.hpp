#pragma once

#include "../core/config.hpp"
#include "../core/types.hpp"
#include "../core/errors.hpp"
#include "../llm/http_client.hpp"
#include <string>
#include <vector>
#include <unordered_map>

namespace agentgraph {

// OpenAI-compatible embeddings client. Talks to any server that exposes
// POST {base_url}/embeddings with {"input": ..., "model": ...} and returns
// {"data": [{"embedding": [...]}]}. Works with OpenAI, Azure OpenAI, Ollama,
// and most OpenAI-compatible gateways.
class EmbeddingClient {
public:
    explicit EmbeddingClient(const ProviderConfig& config);

    // Embed a single text into a float vector.
    Result<std::vector<float>> embed(const std::string& text);

    // Embed multiple texts in one request (server batch support permitting).
    Result<std::vector<std::vector<float>>> embed_batch(
        const std::vector<std::string>& texts);

private:
    ProviderConfig config_;
    HttpClient http_;

    std::string url_for() const;
    std::unordered_map<std::string, std::string> build_headers() const;
    Result<std::vector<std::vector<float>>> request(const json& input);
};

} // namespace agentgraph
