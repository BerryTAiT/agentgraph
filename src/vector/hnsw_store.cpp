#include "hnsw_store.hpp"

#include <cmath>
#include <cstdlib>
#include <fstream>
#include <sstream>

#include <hnswlib/hnswlib.h>

namespace agentgraph {

namespace {

float dot(const std::vector<float>& a, const std::vector<float>& b) {
    float s = 0.0f;
    for (size_t i = 0; i < a.size(); i++) s += a[i] * b[i];
    return s;
}

float norm(const std::vector<float>& v) {
    return std::sqrt(dot(v, v));
}

std::vector<float> l2_normalize(const std::vector<float>& v) {
    std::vector<float> out = v;
    float n = norm(v);
    if (n > 1e-12f) {
        for (auto& x : out) x /= n;
    }
    return out;
}

} // namespace

HnswVectorStore::HnswVectorStore(const VectorStoreConfig& cfg) : cfg_(cfg) {
    if (cfg.dim <= 0) {
        throw std::runtime_error("HnswVectorStore requires dim > 0");
    }

    // Cosine uses normalized vectors + inner product (dot product == cosine).
    if (cfg.distance == VectorDistance::L2) {
        space_ = new hnswlib::L2Space(static_cast<size_t>(cfg.dim));
    } else {
        space_ = new hnswlib::InnerProductSpace(static_cast<size_t>(cfg.dim));
    }

    index_ = new hnswlib::HierarchicalNSW<float>(
        space_,
        cfg.max_elements > 0 ? cfg.max_elements : 10000,
        cfg.M > 0 ? static_cast<size_t>(cfg.M) : 16,
        cfg.ef_construction > 0 ? static_cast<size_t>(cfg.ef_construction) : 200,
        100,
        /*allow_replace_deleted=*/true);

    if (cfg.ef_search > 0) {
        index_->setEf(static_cast<size_t>(cfg.ef_search));
    }

    // Restore a persisted index if one exists. On failure load() leaves the
    // freshly built empty index intact, so a corrupt file degrades to an
    // empty store instead of a dangling pointer.
    if (!cfg.path.empty()) {
        std::ifstream probe(cfg.path, std::ios::binary);
        if (probe.good()) {
            probe.close();
            auto r = load();
            (void)r;
        }
    }
}

HnswVectorStore::~HnswVectorStore() {
    if (!cfg_.path.empty()) {
        // Best-effort persist on destruction.
        auto r = save();
        (void)r;
    }
    delete index_;
    delete space_;
}

std::vector<float> HnswVectorStore::prepare(const std::vector<float>& vec) const {
    if (cfg_.distance == VectorDistance::Cosine) {
        return l2_normalize(vec);
    }
    return vec;
}

std::string HnswVectorStore::meta_path() const {
    return cfg_.path + ".meta.json";
}

Result<void> HnswVectorStore::add(const std::string& id,
                                  const std::vector<float>& vec,
                                  const json& metadata) {
    if (vec.empty()) return Result<void>::err("add: empty vector");
    if (static_cast<int>(vec.size()) != cfg_.dim) {
        return Result<void>::err("add: vector dim mismatch (got " +
            std::to_string(vec.size()) + ", expected " + std::to_string(cfg_.dim) + ")");
    }

    auto prepared = prepare(vec);

    HnswDoc doc;
    doc.id = id;
    if (metadata.is_object() && metadata.contains("text") && metadata["text"].is_string()) {
        doc.text = metadata["text"].get<std::string>();
    }
    doc.metadata = metadata.is_object() ? metadata : json::object();

    try {
        auto it = label_by_id_.find(id);
        if (it != label_by_id_.end()) {
            // Replace existing entry (keeps the same label).
            size_t label = it->second;
            index_->addPoint(prepared.data(), label, /*replace_deleted=*/true);
            docs_[label] = std::move(doc);
            return Result<void>::ok();
        }

        if (index_->getCurrentElementCount() >= index_->getMaxElements()) {
            index_->resizeIndex(index_->getMaxElements() * 2 + 1);
        }

        size_t label = next_label_++;
        index_->addPoint(prepared.data(), label);
        docs_[label] = std::move(doc);
        label_by_id_[id] = label;
        return Result<void>::ok();
    } catch (const std::exception& e) {
        return Result<void>::err(std::string("hnswlib add failed: ") + e.what());
    }
}

Result<std::vector<SearchHit>> HnswVectorStore::search(const std::vector<float>& query,
                                                       int k) {
    if (query.empty()) return Result<std::vector<SearchHit>>::err("search: empty query");
    if (static_cast<int>(query.size()) != cfg_.dim) {
        return Result<std::vector<SearchHit>>::err("search: vector dim mismatch");
    }
    if (k <= 0) return Result<std::vector<SearchHit>>::err("search: k must be > 0");
    if (docs_.empty()) {
        return Result<std::vector<SearchHit>>::ok({});
    }

    auto prepared = prepare(query);

    try {
        auto knn = index_->searchKnnCloserFirst(prepared.data(), static_cast<size_t>(k));

        std::vector<SearchHit> hits;
        for (auto& [dist, label] : knn) {
            auto dit = docs_.find(label);
            if (dit == docs_.end()) continue;

            SearchHit hit;
            hit.id = dit->second.id;
            hit.text = dit->second.text;
            hit.metadata = dit->second.metadata;
            if (cfg_.distance == VectorDistance::L2) {
                hit.score = -static_cast<double>(dist);
            } else {
                hit.score = 1.0 - static_cast<double>(dist);  // cosine / dot
            }
            hits.push_back(std::move(hit));
        }
        return Result<std::vector<SearchHit>>::ok(std::move(hits));
    } catch (const std::exception& e) {
        return Result<std::vector<SearchHit>>::err(std::string("hnswlib search failed: ") + e.what());
    }
}

Result<void> HnswVectorStore::remove(const std::string& id) {
    auto it = label_by_id_.find(id);
    if (it == label_by_id_.end()) {
        return Result<void>::err("remove: id not found: " + id);
    }
    size_t label = it->second;
    try {
        index_->markDelete(label);
    } catch (const std::exception& e) {
        return Result<void>::err(std::string("hnswlib remove failed: ") + e.what());
    }
    docs_.erase(label);
    label_by_id_.erase(it);
    return Result<void>::ok();
}

Result<void> HnswVectorStore::clear() {
    delete index_;
    delete space_;

    if (cfg_.distance == VectorDistance::L2) {
        space_ = new hnswlib::L2Space(static_cast<size_t>(cfg_.dim));
    } else {
        space_ = new hnswlib::InnerProductSpace(static_cast<size_t>(cfg_.dim));
    }
    index_ = new hnswlib::HierarchicalNSW<float>(
        space_, cfg_.max_elements > 0 ? cfg_.max_elements : 10000,
        cfg_.M > 0 ? static_cast<size_t>(cfg_.M) : 16,
        cfg_.ef_construction > 0 ? static_cast<size_t>(cfg_.ef_construction) : 200,
        100, true);
    if (cfg_.ef_search > 0) index_->setEf(static_cast<size_t>(cfg_.ef_search));

    next_label_ = 0;
    docs_.clear();
    label_by_id_.clear();
    return Result<void>::ok();
}

Result<long> HnswVectorStore::count() {
    return Result<long>::ok(static_cast<long>(docs_.size()));
}

Result<void> HnswVectorStore::save() {
    if (cfg_.path.empty()) return Result<void>::ok();
    try {
        index_->saveIndex(cfg_.path);

        json meta;
        meta["next_label"] = next_label_;
        json docmap = json::object();
        for (auto& [label, doc] : docs_) {
            json d;
            d["id"] = doc.id;
            d["text"] = doc.text;
            d["metadata"] = doc.metadata;
            docmap[std::to_string(label)] = std::move(d);
        }
        meta["docs"] = std::move(docmap);

        std::ofstream out(meta_path());
        if (!out) return Result<void>::err("save: cannot open metadata file " + meta_path());
        out << meta.dump();
        return Result<void>::ok();
    } catch (const std::exception& e) {
        return Result<void>::err(std::string("save failed: ") + e.what());
    }
}

Result<void> HnswVectorStore::load() {
    if (cfg_.path.empty()) return Result<void>::err("load: no path configured");

    // Build the replacement index before deleting the current one: if the
    // file is corrupt or truncated hnswlib throws mid-construction, and the
    // store must keep its previous (valid) state.
    hnswlib::HierarchicalNSW<float>* fresh = nullptr;
    try {
        fresh = new hnswlib::HierarchicalNSW<float>(
            space_, cfg_.path, false,
            cfg_.max_elements > 0 ? cfg_.max_elements : 0,
            /*allow_replace_deleted=*/true);
        if (cfg_.ef_search > 0) fresh->setEf(static_cast<size_t>(cfg_.ef_search));

        std::unordered_map<size_t, HnswDoc> new_docs;
        std::unordered_map<std::string, size_t> new_labels;
        size_t new_next = 0;

        std::ifstream in(meta_path());
        if (in) {
            std::stringstream ss;
            ss << in.rdbuf();
            auto meta = json::parse(ss.str());

            if (meta.contains("next_label")) {
                new_next = meta["next_label"].get<size_t>();
            }
            if (meta.contains("docs") && meta["docs"].is_object()) {
                for (auto& [key, val] : meta["docs"].items()) {
                    size_t label = std::stoull(key);
                    HnswDoc doc;
                    doc.id = val.value("id", "");
                    doc.text = val.value("text", "");
                    doc.metadata = val.value("metadata", json::object());
                    new_docs[label] = std::move(doc);
                    if (!doc.id.empty()) new_labels[doc.id] = label;
                }
            }
        }
        // No metadata sidecar: index-only restore (labels preserved, docs empty).

        delete index_;
        index_ = fresh;
        docs_ = std::move(new_docs);
        label_by_id_ = std::move(new_labels);
        next_label_ = new_next;
        return Result<void>::ok();
    } catch (const std::exception& e) {
        delete fresh;  // safe when null; on any failure the old index survives
        return Result<void>::err(std::string("load failed: ") + e.what());
    }
}

} // namespace agentgraph
