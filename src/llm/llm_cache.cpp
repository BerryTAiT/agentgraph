#include "llm_cache.hpp"

namespace agentgraph {

std::optional<LLMResponse> LLMCache::get(const std::string& key) {
    auto now = std::chrono::steady_clock::now();
    std::lock_guard<std::mutex> lk(mu_);
    auto it = entries_.find(key);
    if (it == entries_.end()) return std::nullopt;
    if (expired(it->second, now)) {
        entries_.erase(it);
        return std::nullopt;
    }
    return it->second.response;
}

void LLMCache::put(const std::string& key, const LLMResponse& response) {
    std::lock_guard<std::mutex> lk(mu_);
    entries_[key] = Entry{response, std::chrono::steady_clock::now()};
    evict_locked();
}

size_t LLMCache::size() {
    std::lock_guard<std::mutex> lk(mu_);
    return entries_.size();
}

void LLMCache::clear() {
    std::lock_guard<std::mutex> lk(mu_);
    entries_.clear();
}

bool LLMCache::expired(const Entry& e,
                       std::chrono::steady_clock::time_point now) const {
    if (ttl_seconds_ <= 0) return false;  // 0 = never expire
    return now - e.created_at >= std::chrono::seconds(ttl_seconds_);
}

void LLMCache::evict_locked() {
    // Purge expired entries opportunistically (frees memory even when the
    // max-entries cap is disabled).
    auto now = std::chrono::steady_clock::now();
    for (auto it = entries_.begin(); it != entries_.end();) {
        if (expired(it->second, now)) {
            it = entries_.erase(it);
        } else {
            ++it;
        }
    }

    // Enforce the cap. Eviction order is unspecified (unordered_map) but
    // correctness only requires bounded memory; TTL already dominates reuse.
    if (max_entries_ <= 0) return;
    while (static_cast<int>(entries_.size()) > max_entries_) {
        entries_.erase(entries_.begin());
    }
}

LLMCacheRegistry& LLMCacheRegistry::instance() {
    static LLMCacheRegistry inst;
    return inst;
}

std::shared_ptr<LLMCache> LLMCacheRegistry::get(const std::string& ns,
                                                int ttl_seconds, int max_entries) {
    std::lock_guard<std::mutex> lk(mu_);
    auto it = caches_.find(ns);
    if (it != caches_.end()) return it->second;
    auto cache = std::make_shared<LLMCache>(ttl_seconds, max_entries);
    caches_[ns] = cache;
    return cache;
}

void LLMCacheRegistry::clear_all() {
    std::lock_guard<std::mutex> lk(mu_);
    caches_.clear();
}

void LLMCacheRegistry::clear(const std::string& ns) {
    std::lock_guard<std::mutex> lk(mu_);
    caches_.erase(ns);
}

std::vector<std::pair<std::string, size_t>> LLMCacheRegistry::snapshot() const {
    std::lock_guard<std::mutex> lk(mu_);
    std::vector<std::pair<std::string, size_t>> out;
    out.reserve(caches_.size());
    for (const auto& [ns, cache] : caches_) {
        out.emplace_back(ns, cache ? cache->size() : 0);
    }
    return out;
}

} // namespace agentgraph
