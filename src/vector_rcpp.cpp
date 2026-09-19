#include <Rcpp.h>
#include "vector/vector_store.hpp"
#include "vector/hnsw_store.hpp"
#include "vector/embedding_client.hpp"
#include "core/config.hpp"
#include "core/errors.hpp"
#include "type_converters.h"

#include <memory>
#include <string>
#include <vector>

using namespace agentgraph;

// ---- R list -> VectorStoreConfig -----------------------------------------

static VectorStoreConfig vector_store_from_list(const Rcpp::List& l) {
    std::string backend = "hnswlib";
    if (l.containsElementNamed("backend")) {
        backend = Rcpp::as<std::string>(l["backend"]);
    }

    VectorStoreConfig cfg;
    cfg.backend = string_to_vector_backend(backend);

    if (l.containsElementNamed("distance")) {
        cfg.distance = string_to_vector_distance(Rcpp::as<std::string>(l["distance"]));
    }
    if (l.containsElementNamed("dim")) cfg.dim = Rcpp::as<int>(l["dim"]);
    if (l.containsElementNamed("path")) cfg.path = Rcpp::as<std::string>(l["path"]);
    if (l.containsElementNamed("M")) cfg.M = Rcpp::as<int>(l["M"]);
    if (l.containsElementNamed("ef_construction")) cfg.ef_construction = Rcpp::as<int>(l["ef_construction"]);
    if (l.containsElementNamed("ef_search")) cfg.ef_search = Rcpp::as<int>(l["ef_search"]);
    if (l.containsElementNamed("max_elements")) cfg.max_elements = Rcpp::as<size_t>(l["max_elements"]);
    if (l.containsElementNamed("url")) cfg.url = Rcpp::as<std::string>(l["url"]);
    if (l.containsElementNamed("api_key")) cfg.api_key = Rcpp::as<std::string>(l["api_key"]);
    if (l.containsElementNamed("collection")) cfg.collection = Rcpp::as<std::string>(l["collection"]);
    if (l.containsElementNamed("connection_string")) cfg.connection_string = Rcpp::as<std::string>(l["connection_string"]);
    if (l.containsElementNamed("table")) cfg.table = Rcpp::as<std::string>(l["table"]);
    if (l.containsElementNamed("id_column")) cfg.id_column = Rcpp::as<std::string>(l["id_column"]);
    if (l.containsElementNamed("vector_column")) cfg.vector_column = Rcpp::as<std::string>(l["vector_column"]);

    return cfg;
}

static std::vector<float> vector_from_numeric(const Rcpp::NumericVector& v) {
    std::vector<float> out;
    out.reserve(static_cast<size_t>(v.size()));
    for (int i = 0; i < v.size(); i++) out.push_back(static_cast<float>(v[i]));
    return out;
}

static Rcpp::List hit_to_list(const SearchHit& h) {
    Rcpp::List l;
    l["id"] = h.id;
    l["score"] = h.score;
    l["text"] = h.text;
    l["metadata"] = h.metadata.dump();
    return l;
}

// ---- Exported native entry points -----------------------------------------

// [[Rcpp::export]]
Rcpp::NumericVector embed_cpp(Rcpp::List provider, std::string text) {
    ProviderConfig config = provider_from_list(provider);
    EmbeddingClient client(config);
    auto r = client.embed(text);
    if (r.is_err()) Rcpp::stop(r.error().message);

    auto& v = r.value();
    Rcpp::NumericVector out(static_cast<int>(v.size()));
    for (size_t i = 0; i < v.size(); i++) out[static_cast<int>(i)] = v[i];
    return out;
}

// [[Rcpp::export]]
Rcpp::List embed_batch_cpp(Rcpp::List provider, Rcpp::CharacterVector texts) {
    ProviderConfig config = provider_from_list(provider);
    EmbeddingClient client(config);

    std::vector<std::string> inputs;
    for (int i = 0; i < texts.size(); i++) inputs.push_back(Rcpp::as<std::string>(texts[i]));

    auto r = client.embed_batch(inputs);
    if (r.is_err()) Rcpp::stop(r.error().message);

    Rcpp::List out;
    for (auto& v : r.value()) {
        Rcpp::NumericVector nv(static_cast<int>(v.size()));
        for (size_t i = 0; i < v.size(); i++) nv[static_cast<int>(i)] = v[i];
        out.push_back(nv);
    }
    return out;
}

// [[Rcpp::export]]
SEXP create_vector_store_cpp(Rcpp::List config) {
    VectorStoreConfig cfg = vector_store_from_list(config);
    try {
        auto store = create_vector_store(cfg);
        // The finalizer deletes the concrete store through the virtual dtor.
        Rcpp::XPtr<VectorStore> ptr(store.release(), true);
        return ptr;
    } catch (const std::exception& e) {
        Rcpp::stop(e.what());
    }
}

// [[Rcpp::export]]
void vector_store_add_cpp(SEXP store, std::string id,
                          Rcpp::NumericVector vec, std::string metadata_json = "{}") {
    Rcpp::XPtr<VectorStore> p(store);
    json metadata = json::object();
    try {
        if (!metadata_json.empty()) metadata = json::parse(metadata_json);
    } catch (...) {
        metadata = json::object();
    }
    auto r = p->add(id, vector_from_numeric(vec), metadata);
    if (r.is_err()) Rcpp::stop(r.error().message);
}

// [[Rcpp::export]]
Rcpp::List vector_store_search_cpp(SEXP store, Rcpp::NumericVector query, int k = 5) {
    Rcpp::XPtr<VectorStore> p(store);
    auto r = p->search(vector_from_numeric(query), k);
    if (r.is_err()) Rcpp::stop(r.error().message);

    Rcpp::List out;
    for (auto& h : r.value()) out.push_back(hit_to_list(h));
    return out;
}

// [[Rcpp::export]]
void vector_store_remove_cpp(SEXP store, std::string id) {
    Rcpp::XPtr<VectorStore> p(store);
    auto r = p->remove(id);
    if (r.is_err()) Rcpp::stop(r.error().message);
}

// [[Rcpp::export]]
void vector_store_clear_cpp(SEXP store) {
    Rcpp::XPtr<VectorStore> p(store);
    auto r = p->clear();
    if (r.is_err()) Rcpp::stop(r.error().message);
}

// [[Rcpp::export]]
int vector_store_count_cpp(SEXP store) {
    Rcpp::XPtr<VectorStore> p(store);
    auto r = p->count();
    if (r.is_err()) Rcpp::stop(r.error().message);
    return static_cast<int>(r.value());
}

// [[Rcpp::export]]
void vector_store_save_cpp(SEXP store) {
    Rcpp::XPtr<VectorStore> p(store);
    auto* h = dynamic_cast<HnswVectorStore*>(p.get());
    if (!h) Rcpp::stop("save is only supported for the hnswlib backend");
    auto r = h->save();
    if (r.is_err()) Rcpp::stop(r.error().message);
}

// [[Rcpp::export]]
void vector_store_load_cpp(SEXP store) {
    Rcpp::XPtr<VectorStore> p(store);
    auto* h = dynamic_cast<HnswVectorStore*>(p.get());
    if (!h) Rcpp::stop("load is only supported for the hnswlib backend");
    auto r = h->load();
    if (r.is_err()) Rcpp::stop(r.error().message);
}
