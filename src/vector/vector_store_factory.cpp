#include "vector_store.hpp"
#include "hnsw_store.hpp"
#include "rest_stores.hpp"

namespace agentgraph {

std::unique_ptr<VectorStore> create_vector_store(const VectorStoreConfig& cfg) {
    switch (cfg.backend) {
        case VectorBackend::Hnswlib:
            return std::make_unique<HnswVectorStore>(cfg);
        case VectorBackend::Chroma:
            return std::make_unique<ChromaVectorStore>(cfg);
        case VectorBackend::Qdrant:
            return std::make_unique<QdrantVectorStore>(cfg);
        case VectorBackend::Pinecone:
            return std::make_unique<PineconeVectorStore>(cfg);
        case VectorBackend::Faiss:
            // Compile-gated native backend. See AGENTGRAPH_ENABLE_FAISS.
            throw std::runtime_error(
                "FAISS backend is not compiled into this build. "
                "Build with AGENTGRAPH_ENABLE_FAISS and link -lfaiss to enable it.");
        case VectorBackend::Pgvector:
            // Compile-gated native backend. See AGENTGRAPH_ENABLE_PGVECTOR.
            throw std::runtime_error(
                "pgvector backend is not compiled into this build. "
                "Build with AGENTGRAPH_ENABLE_PGVECTOR and link libpq to enable it.");
    }
    throw std::runtime_error("unknown vector store backend");
}

} // namespace agentgraph
