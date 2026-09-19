#include "embedding_client.hpp"

namespace agentgraph {

EmbeddingClient::EmbeddingClient(const ProviderConfig& config) : config_(config) {}

std::string EmbeddingClient::url_for() const {
    if (config_.name == "azure" && !config_.api_version.empty()) {
        return config_.base_url + "/embeddings?api-version=" + config_.api_version;
    }
    return config_.base_url + "/embeddings";
}

std::unordered_map<std::string, std::string> EmbeddingClient::build_headers() const {
    std::unordered_map<std::string, std::string> headers;
    headers["Content-Type"] = "application/json";
    if (config_.name == "azure") {
        headers["api-key"] = config_.api_key;
    } else if (config_.name == "ollama" || config_.api_key.empty()) {
        // no Authorization header
    } else {
        headers["Authorization"] = "Bearer " + config_.api_key;
    }
    return headers;
}

Result<std::vector<std::vector<float>>> EmbeddingClient::request(const json& input) {
    json req;
    req["model"] = config_.model;
    req["input"] = input;

    std::string url = url_for();
    auto headers = build_headers();

    auto http_result = http_.post(url, req.dump(), headers);
    if (http_result.is_err()) {
        return Result<std::vector<std::vector<float>>>::err(http_result.error().message);
    }

    auto& resp = http_result.value();
    if (resp.status_code != 200) {
        std::string msg = resp.body;
        try {
            auto err_json = json::parse(resp.body);
            if (err_json.contains("error")) {
                auto& e = err_json["error"];
                if (e.is_object()) msg = e.value("message", resp.body);
                else msg = e.is_string() ? e.get<std::string>() : resp.body;
            }
        } catch (...) {}
        return Result<std::vector<std::vector<float>>>::err(
            "embeddings API error (" + std::to_string(resp.status_code) + "): " + msg);
    }

    try {
        auto parsed = json::parse(resp.body);
        if (!parsed.contains("data") || !parsed["data"].is_array()) {
            return Result<std::vector<std::vector<float>>>::err(
                "embeddings response missing 'data' array");
        }

        std::vector<std::vector<float>> out;
        for (auto& item : parsed["data"]) {
            if (!item.contains("embedding") || !item["embedding"].is_array()) {
                return Result<std::vector<std::vector<float>>>::err(
                    "embeddings response item missing 'embedding'");
            }
            std::vector<float> v;
            for (auto& x : item["embedding"]) {
                v.push_back(x.get<float>());
            }
            out.push_back(std::move(v));
        }
        if (out.empty()) {
            return Result<std::vector<std::vector<float>>>::err(
                "embeddings response contained no vectors");
        }
        return Result<std::vector<std::vector<float>>>::ok(std::move(out));
    } catch (const std::exception& e) {
        return Result<std::vector<std::vector<float>>>::err(
            std::string("Failed to parse embeddings response: ") + e.what());
    }
}

Result<std::vector<float>> EmbeddingClient::embed(const std::string& text) {
    auto r = request(text);
    if (r.is_err()) return Result<std::vector<float>>::err(r.error().message);
    return Result<std::vector<float>>::ok(std::move(r.value()[0]));
}

Result<std::vector<std::vector<float>>> EmbeddingClient::embed_batch(
    const std::vector<std::string>& texts)
{
    if (texts.empty()) {
        return Result<std::vector<std::vector<float>>>::err("embed_batch: empty input");
    }
    return request(json(texts));
}

} // namespace agentgraph
