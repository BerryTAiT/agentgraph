#pragma once

#include "vector_store.hpp"
#include <unordered_map>
#include <string>

namespace hnswlib {
template<typename dist_t> class SpaceInterface;
template<typename dist_t> class HierarchicalNSW;
}

namespace agentgraph {

struct HnswDoc {
    std::string id;
    std::string text;
    json metadata;
};

// In-process vector store backed by the vendored header-only hnswlib.
// Cosine similarity is implemented by L2-normalizing vectors and using
// hnswlib::InnerProductSpace (hnswlib has no dedicated cosine space).
class HnswVectorStore : public VectorStore {
public:
    explicit HnswVectorStore(const VectorStoreConfig& cfg);
    ~HnswVectorStore() override;

    Result<void> add(const std::string& id,
                     const std::vector<float>& vec,
                     const json& metadata) override;

    Result<std::vector<SearchHit>> search(const std::vector<float>& query,
                                          int k) override;

    Result<void> remove(const std::string& id) override;
    Result<void> clear() override;
    Result<long> count() override;

    // Persist / restore the index and its metadata sidecar.
    Result<void> save();
    Result<void> load();

private:
    VectorStoreConfig cfg_;

    // Owned: the space must outlive the index.
    hnswlib::SpaceInterface<float>* space_ = nullptr;
    hnswlib::HierarchicalNSW<float>* index_ = nullptr;

    size_t next_label_ = 0;
    std::unordered_map<size_t, HnswDoc> docs_;
    std::unordered_map<std::string, size_t> label_by_id_;

    std::vector<float> prepare(const std::vector<float>& vec) const;
    std::string meta_path() const;
};

} // namespace agentgraph
