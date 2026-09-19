#pragma once

#include "vector_store.hpp"
#include "../llm/http_client.hpp"
#include <string>

namespace agentgraph {

// Shared helper for JSON-over-HTTP vector stores.
class RestVectorStoreBase : public VectorStore {
public:
    RestVectorStoreBase() = default;
    virtual ~RestVectorStoreBase() = default;

protected:
    HttpClient http_;

    // POST JSON to url; returns parsed JSON or error on transport/non-2xx.
    Result<json> post_json(const std::string& url,
                           const json& body,
                           const std::unordered_map<std::string, std::string>& headers = {});

    Result<json> get_json(const std::string& url,
                          const std::unordered_map<std::string, std::string>& headers = {});

    Result<json> put_json(const std::string& url,
                          const json& body,
                          const std::unordered_map<std::string, std::string>& headers = {});

    static std::string url_encode(const std::string& s);
};

class ChromaVectorStore : public RestVectorStoreBase {
public:
    explicit ChromaVectorStore(const VectorStoreConfig& cfg);

    Result<void> add(const std::string& id, const std::vector<float>& vec,
                     const json& metadata) override;
    Result<std::vector<SearchHit>> search(const std::vector<float>& query, int k) override;
    Result<void> remove(const std::string& id) override;
    Result<void> clear() override;
    Result<long> count() override;

private:
    VectorStoreConfig cfg_;
    std::string coll_url() const;
    Result<void> ensure_collection();
};

class QdrantVectorStore : public RestVectorStoreBase {
public:
    explicit QdrantVectorStore(const VectorStoreConfig& cfg);

    Result<void> add(const std::string& id, const std::vector<float>& vec,
                     const json& metadata) override;
    Result<std::vector<SearchHit>> search(const std::vector<float>& query, int k) override;
    Result<void> remove(const std::string& id) override;
    Result<void> clear() override;
    Result<long> count() override;

private:
    VectorStoreConfig cfg_;
    std::string base() const;
    Result<void> ensure_collection();
    static std::string qdrant_distance(VectorDistance d);
};

class PineconeVectorStore : public RestVectorStoreBase {
public:
    explicit PineconeVectorStore(const VectorStoreConfig& cfg);

    Result<void> add(const std::string& id, const std::vector<float>& vec,
                     const json& metadata) override;
    Result<std::vector<SearchHit>> search(const std::vector<float>& query, int k) override;
    Result<void> remove(const std::string& id) override;
    Result<void> clear() override;
    Result<long> count() override;

private:
    VectorStoreConfig cfg_;
    std::string base() const;
    std::unordered_map<std::string, std::string> headers() const;
};

} // namespace agentgraph
