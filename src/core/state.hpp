#pragma once

#include "types.hpp"
#include <string>
#include <vector>
#include <unordered_map>
#include <shared_mutex>
#include <mutex>
#include <memory>

namespace agentgraph {

class GraphState {
public:
    GraphState() : mtx_(std::make_unique<std::shared_mutex>()) {}

    GraphState(GraphState&& other) noexcept {
        std::unique_lock lock(*other.mtx_);
        data_ = std::move(other.data_);
        messages_ = std::move(other.messages_);
        mtx_ = std::make_unique<std::shared_mutex>();
    }

    GraphState& operator=(GraphState&& other) noexcept {
        if (this != &other) {
            std::unique_lock lock1(*mtx_, std::defer_lock);
            std::unique_lock lock2(*other.mtx_, std::defer_lock);
            std::lock(lock1, lock2);
            data_ = std::move(other.data_);
            messages_ = std::move(other.messages_);
        }
        return *this;
    }

    GraphState(const GraphState&) = delete;
    GraphState& operator=(const GraphState&) = delete;

    void set(const std::string& key, const json& value) {
        std::unique_lock lock(*mtx_);
        data_[key] = value;
    }

    json get(const std::string& key) const {
        std::shared_lock lock(*mtx_);
        auto it = data_.find(key);
        if (it != data_.end()) return it->second;
        return nullptr;
    }

    bool has(const std::string& key) const {
        std::shared_lock lock(*mtx_);
        return data_.find(key) != data_.end();
    }

    void erase(const std::string& key) {
        std::unique_lock lock(*mtx_);
        data_.erase(key);
    }

    void add_message(const Message& msg) {
        std::unique_lock lock(*mtx_);
        messages_.push_back(msg);
    }

    void add_messages(const std::vector<Message>& msgs) {
        std::unique_lock lock(*mtx_);
        messages_.insert(messages_.end(), msgs.begin(), msgs.end());
    }

    std::vector<Message> get_messages() const {
        std::shared_lock lock(*mtx_);
        return messages_;
    }

    void set_messages(const std::vector<Message>& msgs) {
        std::unique_lock lock(*mtx_);
        messages_ = msgs;
    }

    json to_json() const {
        std::shared_lock lock(*mtx_);
        json j;
        j["data"] = data_;
        j["messages"] = messages_;
        return j;
    }

    static GraphState from_json(const json& j) {
        GraphState state;
        if (j.contains("data")) {
            state.data_ = j["data"].get<std::unordered_map<std::string, json>>();
        }
        if (j.contains("messages")) {
            state.messages_ = j["messages"].get<std::vector<Message>>();
        }
        return state;
    }

    std::unordered_map<std::string, json> get_all_data() const {
        std::shared_lock lock(*mtx_);
        return data_;
    }

private:
    std::unordered_map<std::string, json> data_;
    std::vector<Message> messages_;
    mutable std::unique_ptr<std::shared_mutex> mtx_;
};

} // namespace agentgraph
