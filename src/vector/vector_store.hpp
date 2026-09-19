#pragma once

#include "../core/types.hpp"
#include "../core/errors.hpp"
#include <string>
#include <vector>
#include <memory>

namespace agentgraph {

// Which backend powers a VectorStore.
enum class VectorBackend {
    Hnswlib,   // in-process, header-only, no external server
    Chroma,    // REST
    Qdrant,    // REST
    Pinecone,  // REST
    Faiss,     // native C++ lib, compile-gated
    Pgvector   // PostgreSQL, compile-gated
};

inline std::string vector_backend_to_string(VectorBackend b) {
    switch (b) {
        case VectorBackend::Hnswlib: return "hnswlib";
        case VectorBackend::Chroma:   return "chroma";
        case VectorBackend::Qdrant:   return "qdrant";
        case VectorBackend::Pinecone: return "pinecone";
        case VectorBackend::Faiss:    return "faiss";
        case VectorBackend::Pgvector: return "pgvector";
    }
    return "hnswlib";
}

inline VectorBackend string_to_vector_backend(const std::string& s) {
    if (s == "hnswlib")  return VectorBackend::Hnswlib;
    if (s == "chroma")   return VectorBackend::Chroma;
    if (s == "qdrant")   return VectorBackend::Qdrant;
    if (s == "pinecone") return VectorBackend::Pinecone;
    if (s == "faiss")    return VectorBackend::Faiss;
    if (s == "pgvector") return VectorBackend::Pgvector;
    throw std::invalid_argument(
        "unknown vector store backend '" + s +
        "' (expected: hnswlib, chroma, qdrant, pinecone, faiss, pgvector)");
}

// Distance metric. hnswlib has no CosineSpace, so cosine is implemented by
// L2-normalizing vectors and using InnerProductSpace.
enum class VectorDistance {
    Cosine,
    InnerProduct,
    L2
};

inline std::string vector_distance_to_string(VectorDistance d) {
    switch (d) {
        case VectorDistance::Cosine:       return "cosine";
        case VectorDistance::InnerProduct: return "ip";
        case VectorDistance::L2:           return "l2";
    }
    return "cosine";
}

inline VectorDistance string_to_vector_distance(const std::string& s) {
    if (s == "ip" || s == "inner_product" || s == "dot") return VectorDistance::InnerProduct;
    if (s == "l2" || s == "euclidean")                  return VectorDistance::L2;
    return VectorDistance::Cosine;
}

struct VectorStoreConfig {
    VectorBackend backend = VectorBackend::Hnswlib;
    VectorDistance distance = VectorDistance::Cosine;

    // hnswlib / faiss (in-process or file-backed)
    std::string path;         // persist index to this file (optional)
    int dim = 0;              // vector dimension (required)
    int M = 16;               // hnswlib max out-degree per layer
    int ef_construction = 200;
    int ef_search = 50;
    size_t max_elements = 10000;

    // REST stores (chroma / qdrant / pinecone)
    std::string url;          // base URL, e.g. http://localhost:8000
    std::string api_key;
    std::string collection;   // collection / index / namespace name

    // pgvector
    std::string connection_string;  // postgresql://user:pass@host:port/db
    std::string table;              // table name holding vectors
    std::string id_column = "id";
    std::string vector_column = "embedding";

    static VectorStoreConfig hnswlib(int dim,
                                     const std::string& distance = "cosine",
                                     const std::string& path = "") {
        VectorStoreConfig c;
        c.backend = VectorBackend::Hnswlib;
        c.distance = string_to_vector_distance(distance);
        c.dim = dim;
        c.path = path;
        return c;
    }

    static VectorStoreConfig chroma(const std::string& url,
                                    const std::string& collection,
                                    int dim,
                                    const std::string& api_key = "") {
        VectorStoreConfig c;
        c.backend = VectorBackend::Chroma;
        c.url = url;
        c.collection = collection;
        c.dim = dim;
        c.api_key = api_key;
        return c;
    }

    static VectorStoreConfig qdrant(const std::string& url,
                                    const std::string& collection,
                                    int dim,
                                    const std::string& api_key = "") {
        VectorStoreConfig c;
        c.backend = VectorBackend::Qdrant;
        c.url = url;
        c.collection = collection;
        c.dim = dim;
        c.api_key = api_key;
        return c;
    }

    static VectorStoreConfig pinecone(const std::string& api_key,
                                      const std::string& url,
                                      const std::string& collection,
                                      int dim) {
        VectorStoreConfig c;
        c.backend = VectorBackend::Pinecone;
        c.api_key = api_key;
        c.url = url;
        c.collection = collection;
        c.dim = dim;
        return c;
    }
};

// One retrieved neighbor.
struct SearchHit {
    std::string id;
    double score = 0.0;   // cosine similarity (or -distance for ip/l2)
    std::string text;     // document chunk, if provided as metadata["text"]
    json metadata;
};

// Abstract interface all vector stores implement.
class VectorStore {
public:
    virtual ~VectorStore() = default;

    virtual Result<void> add(const std::string& id,
                             const std::vector<float>& vec,
                             const json& metadata) = 0;

    virtual Result<std::vector<SearchHit>> search(const std::vector<float>& query,
                                                  int k) = 0;

    virtual Result<void> remove(const std::string& id) = 0;

    virtual Result<void> clear() = 0;

    virtual Result<long> count() = 0;
};

// Build a store for the requested backend.
std::unique_ptr<VectorStore> create_vector_store(const VectorStoreConfig& cfg);

} // namespace agentgraph
