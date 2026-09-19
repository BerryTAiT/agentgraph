#include "rest_stores.hpp"

#include <sstream>
#include <cctype>
#include <cstdio>

namespace agentgraph {

// ---- RestVectorStoreBase ---------------------------------------------------

Result<json> RestVectorStoreBase::post_json(
    const std::string& url,
    const json& body,
    const std::unordered_map<std::string, std::string>& headers)
{
    auto r = http_.post(url, body.dump(), headers);
    if (r.is_err()) return Result<json>::err(r.error().message);

    auto& resp = r.value();
    if (resp.status_code < 200 || resp.status_code >= 300) {
        return Result<json>::err("HTTP " + std::to_string(resp.status_code) + ": " + resp.body);
    }
    try {
        if (resp.body.empty()) return Result<json>::ok(json::object());
        return Result<json>::ok(json::parse(resp.body));
    } catch (const std::exception& e) {
        return Result<json>::err(std::string("bad JSON: ") + e.what());
    }
}

Result<json> RestVectorStoreBase::get_json(
    const std::string& url,
    const std::unordered_map<std::string, std::string>& headers)
{
    auto r = http_.get(url, headers);
    if (r.is_err()) return Result<json>::err(r.error().message);

    auto& resp = r.value();
    if (resp.status_code < 200 || resp.status_code >= 300) {
        return Result<json>::err("HTTP " + std::to_string(resp.status_code) + ": " + resp.body);
    }
    try {
        if (resp.body.empty()) return Result<json>::ok(json::object());
        return Result<json>::ok(json::parse(resp.body));
    } catch (const std::exception& e) {
        return Result<json>::err(std::string("bad JSON: ") + e.what());
    }
}

Result<json> RestVectorStoreBase::put_json(
    const std::string& url,
    const json& body,
    const std::unordered_map<std::string, std::string>& headers)
{
    auto r = http_.put(url, body.dump(), headers);
    if (r.is_err()) return Result<json>::err(r.error().message);

    auto& resp = r.value();
    if (resp.status_code < 200 || resp.status_code >= 300) {
        return Result<json>::err("HTTP " + std::to_string(resp.status_code) + ": " + resp.body);
    }
    try {
        if (resp.body.empty()) return Result<json>::ok(json::object());
        return Result<json>::ok(json::parse(resp.body));
    } catch (const std::exception& e) {
        return Result<json>::err(std::string("bad JSON: ") + e.what());
    }
}

std::string RestVectorStoreBase::url_encode(const std::string& s) {
    std::ostringstream out;
    for (unsigned char c : s) {
        if (isalnum(c) || c == '-' || c == '_' || c == '.' || c == '~') {
            out << c;
        } else {
            char buf[4];
            snprintf(buf, sizeof(buf), "%%%02X", c);
            out << buf;
        }
    }
    return out.str();
}

// ---- Chroma ----------------------------------------------------------------

ChromaVectorStore::ChromaVectorStore(const VectorStoreConfig& cfg) : cfg_(cfg) {}

std::string ChromaVectorStore::coll_url() const {
    return cfg_.url + "/api/v1/collections/" + url_encode(cfg_.collection);
}

Result<void> ChromaVectorStore::ensure_collection() {
    auto headers = std::unordered_map<std::string, std::string>{
        {"Content-Type", "application/json"}
    };
    if (!cfg_.api_key.empty()) headers["Authorization"] = "Bearer " + cfg_.api_key;

    // Check if it exists.
    auto list_r = get_json(cfg_.url + "/api/v1/collections", headers);
    if (list_r.is_ok()) {
        for (auto& c : list_r.value()) {
            if (c.value("name", "") == cfg_.collection) return Result<void>::ok();
        }
    }

    // Create it.
    std::string space = "cosine";
    if (cfg_.distance == VectorDistance::L2) space = "l2";
    else if (cfg_.distance == VectorDistance::InnerProduct) space = "ip";

    json body = {
        {"name", cfg_.collection},
        {"metadata", {{"hnsw:space", space}}}
    };
    auto r = post_json(cfg_.url + "/api/v1/collections", body, headers);
    if (r.is_err()) return Result<void>::err(r.error().message);
    return Result<void>::ok();
}

Result<void> ChromaVectorStore::add(const std::string& id,
                                    const std::vector<float>& vec,
                                    const json& metadata) {
    auto ensure = ensure_collection();
    if (ensure.is_err()) return ensure;

    auto headers = std::unordered_map<std::string, std::string>{
        {"Content-Type", "application/json"}
    };
    if (!cfg_.api_key.empty()) headers["Authorization"] = "Bearer " + cfg_.api_key;

    json meta = metadata.is_object() ? metadata : json::object();

    json body = {
        {"ids", json::array({id})},
        {"embeddings", json::array({vec})},
        {"metadatas", json::array({meta})}
    };
    if (meta.contains("text")) body["documents"] = json::array({meta["text"]});

    auto r = post_json(coll_url() + "/add", body, headers);
    if (r.is_err()) return Result<void>::err(r.error().message);
    return Result<void>::ok();
}

Result<std::vector<SearchHit>> ChromaVectorStore::search(const std::vector<float>& query,
                                                         int k) {
    auto headers = std::unordered_map<std::string, std::string>{
        {"Content-Type", "application/json"}
    };
    if (!cfg_.api_key.empty()) headers["Authorization"] = "Bearer " + cfg_.api_key;

    json body = {
        {"query_embeddings", json::array({query})},
        {"n_results", k},
        {"include", json::array({"metadatas", "distances", "documents"})}
    };

    auto r = post_json(coll_url() + "/query", body, headers);
    if (r.is_err()) return Result<std::vector<SearchHit>>::err(r.error().message);

    auto& resp = r.value();
    std::vector<SearchHit> hits;

    auto ids = resp.value("ids", json::array());
    auto dists = resp.value("distances", json::array());
    auto metas = resp.value("metadatas", json::array());
    auto docs = resp.value("documents", json::array());

    if (ids.empty() || !ids[0].is_array()) return Result<std::vector<SearchHit>>::ok({});

    auto& id_row = ids[0];
    for (size_t i = 0; i < id_row.size(); i++) {
        SearchHit hit;
        hit.id = id_row[i].get<std::string>();

        double d = 0.0;
        if (!dists.empty() && dists[0].is_array() && i < dists[0].size()) {
            d = dists[0][i].get<double>();
        }
        // Chroma: cosine/ip distance = 1 - similarity; l2 distance = euclidean.
        if (cfg_.distance == VectorDistance::L2) hit.score = -d;
        else hit.score = 1.0 - d;

        if (!metas.empty() && metas[0].is_array() && i < metas[0].size() &&
            metas[0][i].is_object()) {
            hit.metadata = metas[0][i];
            if (hit.metadata.contains("text")) hit.text = hit.metadata["text"].get<std::string>();
        }
        if (!docs.empty() && docs[0].is_array() && i < docs[0].size() &&
            docs[0][i].is_string()) {
            hit.text = docs[0][i].get<std::string>();
        }
        hits.push_back(std::move(hit));
    }
    return Result<std::vector<SearchHit>>::ok(std::move(hits));
}

Result<void> ChromaVectorStore::remove(const std::string& id) {
    auto headers = std::unordered_map<std::string, std::string>{
        {"Content-Type", "application/json"}
    };
    if (!cfg_.api_key.empty()) headers["Authorization"] = "Bearer " + cfg_.api_key;

    json body = {{"ids", json::array({id})}};
    auto r = post_json(coll_url() + "/delete", body, headers);
    if (r.is_err()) return Result<void>::err(r.error().message);
    return Result<void>::ok();
}

Result<void> ChromaVectorStore::clear() {
    // Chroma has no "clear" endpoint; delete and recreate the collection.
    auto headers = std::unordered_map<std::string, std::string>{
        {"Content-Type", "application/json"}
    };
    if (!cfg_.api_key.empty()) headers["Authorization"] = "Bearer " + cfg_.api_key;

    auto del = http_.del(coll_url(), "", headers);
    if (del.is_err()) return Result<void>::err(del.error().message);

    return ensure_collection();
}

Result<long> ChromaVectorStore::count() {
    auto headers = std::unordered_map<std::string, std::string>{
        {"Content-Type", "application/json"}
    };
    if (!cfg_.api_key.empty()) headers["Authorization"] = "Bearer " + cfg_.api_key;

    auto r = get_json(coll_url() + "/count", headers);
    if (r.is_err()) return Result<long>::err(r.error().message);
    return Result<long>::ok(r.value().get<long>());
}

// ---- Qdrant ----------------------------------------------------------------

QdrantVectorStore::QdrantVectorStore(const VectorStoreConfig& cfg) : cfg_(cfg) {}

std::string QdrantVectorStore::base() const {
    return cfg_.url;
}

std::string QdrantVectorStore::qdrant_distance(VectorDistance d) {
    switch (d) {
        case VectorDistance::InnerProduct: return "Dot";
        case VectorDistance::L2:           return "Euclid";
        case VectorDistance::Cosine:
        default:                           return "Cosine";
    }
}

Result<void> QdrantVectorStore::ensure_collection() {
    json body = {
        {"vectors", {
            {"size", cfg_.dim},
            {"distance", qdrant_distance(cfg_.distance)}
        }}
    };
    auto r = put_json(base() + "/collections/" + url_encode(cfg_.collection), body);
    if (r.is_err()) return Result<void>::err(r.error().message);
    return Result<void>::ok();
}

Result<void> QdrantVectorStore::add(const std::string& id,
                                    const std::vector<float>& vec,
                                    const json& metadata) {
    auto ensure = ensure_collection();
    if (ensure.is_err()) return ensure;

    json payload = metadata.is_object() ? metadata : json::object();
    payload["_id"] = id;

    json body = {
        {"points", json::array({
            {
                {"id", id},
                {"vector", vec},
                {"payload", payload}
            }
        })}
    };
    auto r = put_json(base() + "/collections/" + url_encode(cfg_.collection) + "/points", body);
    if (r.is_err()) return Result<void>::err(r.error().message);
    return Result<void>::ok();
}

Result<std::vector<SearchHit>> QdrantVectorStore::search(const std::vector<float>& query,
                                                         int k) {
    json body = {
        {"vector", query},
        {"limit", k},
        {"with_payload", true}
    };
    auto r = post_json(base() + "/collections/" + url_encode(cfg_.collection) + "/points/search", body);
    if (r.is_err()) return Result<std::vector<SearchHit>>::err(r.error().message);

    std::vector<SearchHit> hits;
    auto& resp = r.value();
    if (!resp.contains("result") || !resp["result"].is_array()) {
        return Result<std::vector<SearchHit>>::ok({});
    }
    for (auto& p : resp["result"]) {
        SearchHit hit;
        auto idv = p.value("id", json(nullptr));
        if (idv.is_number()) hit.id = std::to_string(idv.get<long long>());
        else if (idv.is_string()) hit.id = idv.get<std::string>();

        hit.score = p.value("score", 0.0);
        // Qdrant: Euclid score is a distance (lower is better) — negate to
        // keep "higher is better" semantics.
        if (cfg_.distance == VectorDistance::L2) hit.score = -hit.score;

        auto payload = p.value("payload", json::object());
        if (payload.is_object()) {
            if (payload.contains("_id")) payload.erase("_id");
            hit.metadata = payload;
            if (hit.metadata.contains("text")) hit.text = hit.metadata["text"].get<std::string>();
        }
        hits.push_back(std::move(hit));
    }
    return Result<std::vector<SearchHit>>::ok(std::move(hits));
}

Result<void> QdrantVectorStore::remove(const std::string& id) {
    json body = {{"points", json::array({id})}};
    auto r = post_json(base() + "/collections/" + url_encode(cfg_.collection) + "/points/delete", body);
    if (r.is_err()) return Result<void>::err(r.error().message);
    return Result<void>::ok();
}

Result<void> QdrantVectorStore::clear() {
    // Recreate the collection to wipe all points.
    auto del = http_.del(base() + "/collections/" + url_encode(cfg_.collection));
    if (del.is_err()) return Result<void>::err(del.error().message);
    return ensure_collection();
}

Result<long> QdrantVectorStore::count() {
    json body = {{"exact", true}};
    auto r = post_json(base() + "/collections/" + url_encode(cfg_.collection) + "/points/count", body);
    if (r.is_err()) return Result<long>::err(r.error().message);
    auto& resp = r.value();
    return Result<long>::ok(resp.value("result", json::object()).value("count", 0L));
}

// ---- Pinecone --------------------------------------------------------------

PineconeVectorStore::PineconeVectorStore(const VectorStoreConfig& cfg) : cfg_(cfg) {}

std::string PineconeVectorStore::base() const {
    return cfg_.url;
}

std::unordered_map<std::string, std::string> PineconeVectorStore::headers() const {
    return {
        {"Content-Type", "application/json"},
        {"Api-Key", cfg_.api_key}
    };
}

Result<void> PineconeVectorStore::add(const std::string& id,
                                      const std::vector<float>& vec,
                                      const json& metadata) {
    json meta = metadata.is_object() ? metadata : json::object();
    json body = {
        {"vectors", json::array({
            {
                {"id", id},
                {"values", vec},
                {"metadata", meta}
            }
        })}
    };
    auto r = post_json(base() + "/vectors/upsert", body, headers());
    if (r.is_err()) return Result<void>::err(r.error().message);
    return Result<void>::ok();
}

Result<std::vector<SearchHit>> PineconeVectorStore::search(const std::vector<float>& query,
                                                           int k) {
    json body = {
        {"vector", query},
        {"topK", k},
        {"includeMetadata", true},
        {"includeValues", false}
    };
    auto r = post_json(base() + "/query", body, headers());
    if (r.is_err()) return Result<std::vector<SearchHit>>::err(r.error().message);

    std::vector<SearchHit> hits;
    auto& resp = r.value();
    if (!resp.contains("matches") || !resp["matches"].is_array()) {
        return Result<std::vector<SearchHit>>::ok({});
    }
    for (auto& m : resp["matches"]) {
        SearchHit hit;
        hit.id = m.value("id", "");
        hit.score = m.value("score", 0.0);
        hit.metadata = m.value("metadata", json::object());
        if (hit.metadata.contains("text")) hit.text = hit.metadata["text"].get<std::string>();
        hits.push_back(std::move(hit));
    }
    return Result<std::vector<SearchHit>>::ok(std::move(hits));
}

Result<void> PineconeVectorStore::remove(const std::string& id) {
    json body = {{"ids", json::array({id})}};
    auto r = post_json(base() + "/vectors/delete", body, headers());
    if (r.is_err()) return Result<void>::err(r.error().message);
    return Result<void>::ok();
}

Result<void> PineconeVectorStore::clear() {
    // Pinecone cannot delete all vectors directly; deleting the index is a
    // control-plane operation outside this client. Report as unsupported.
    return Result<void>::err("PineconeVectorStore::clear is not supported; recreate the index instead");
}

Result<long> PineconeVectorStore::count() {
    auto r = post_json(base() + "/describe_index_stats", json::object(), headers());
    if (r.is_err()) return Result<long>::err(r.error().message);
    auto& resp = r.value();
    return Result<long>::ok(resp.value("totalVectorCount", 0L));
}

} // namespace agentgraph
