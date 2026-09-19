#pragma once

#include "../core/types.hpp"
#include <atomic>
#include <chrono>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

namespace agentgraph {

// A thread-safe in-memory exact cache for LLM completions. Keys are opaque
// canonical strings (built by CachedLLMClient from the full request); values
// are complete LLMResponse objects. Entries expire after `ttl_seconds`
// (0 = never expire) and the map is bounded by `max_entries` (0 = unlimited).
class LLMCache {
public:
    LLMCache(int ttl_seconds, int max_entries)
        : ttl_seconds_(ttl_seconds), max_entries_(max_entries) {}

    // Returns the cached response, or std::nullopt on miss / expiry.
    std::optional<LLMResponse> get(const std::string& key);

    // Stores (or refreshes) an entry.
    void put(const std::string& key, const LLMResponse& response);

    size_t size();
    void clear();

private:
    struct Entry {
        LLMResponse response;
        std::chrono::steady_clock::time_point created_at;
    };

    int ttl_seconds_;
    int max_entries_;
    std::mutex mu_;
    std::unordered_map<std::string, Entry> entries_;

    bool expired(const Entry& e, std::chrono::steady_clock::time_point now) const;
    void evict_locked();  // caller holds mu_
};

// Process-global registry of per-provider caches. Each provider (identified
// by a namespace string derived from its name/base_url/model/api_version) gets
// its own cache so its TTL and max-entries are honored independently, and so
// entries persist across every chat() and graph call in the process. The first
// creation for a namespace fixes its TTL/max-entries for the process lifetime.
class LLMCacheRegistry {
public:
    static LLMCacheRegistry& instance();

    // Returns the shared cache for `ns`, creating it on first use.
    std::shared_ptr<LLMCache> get(const std::string& ns,
                                  int ttl_seconds, int max_entries);

    void clear_all();
    void clear(const std::string& ns);

    // Process-global cache hit/miss counters (for metrics).
    void record_hit()  { hits_.fetch_add(1); }
    void record_miss() { misses_.fetch_add(1); }
    long long hits() const   { return hits_.load(); }
    long long misses() const { return misses_.load(); }

    // (namespace, entry count) snapshot for diagnostics.
    std::vector<std::pair<std::string, size_t>> snapshot() const;

private:
    LLMCacheRegistry() = default;
    mutable std::mutex mu_;
    std::unordered_map<std::string, std::shared_ptr<LLMCache>> caches_;
    std::atomic<long long> hits_{0};
    std::atomic<long long> misses_{0};
};

} // namespace agentgraph
