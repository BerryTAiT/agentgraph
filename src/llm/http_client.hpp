#pragma once

#include "../core/errors.hpp"
#include <string>
#include <vector>
#include <functional>
#include <unordered_map>

namespace agentgraph {

struct HttpResponse {
    int status_code = 0;
    std::string body;
    std::string error_message;
    std::unordered_map<std::string, std::string> headers;
};

using StreamCallback = std::function<void(const std::string& chunk)>;

class HttpClient {
public:
    Result<HttpResponse> post(
        const std::string& url,
        const std::string& body,
        const std::unordered_map<std::string, std::string>& headers = {});

    Result<HttpResponse> post_stream(
        const std::string& url,
        const std::string& body,
        const std::unordered_map<std::string, std::string>& headers,
        const StreamCallback& on_chunk);

    Result<HttpResponse> get(
        const std::string& url,
        const std::unordered_map<std::string, std::string>& headers = {});
};

} // namespace agentgraph
