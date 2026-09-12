#pragma once

#include "../core/types.hpp"
#include <string>
#include <functional>
#include <vector>

namespace agentgraph {

using SSECallback = std::function<void(const json& data)>;

class SSEParser {
public:
    void feed(const std::string& chunk, const SSECallback& callback);
    void flush(const SSECallback& callback);

private:
    std::string buffer_;
    std::string current_data_;
};

} // namespace agentgraph
