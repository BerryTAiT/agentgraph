#pragma once

#include "../core/errors.hpp"
#include "rate_limiter.hpp"
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

// Thin HTTP facade shared by every LLM/vector/tool call. It adds the two
// production-grade behaviours on top of the raw transport:
//   - retry + exponential backoff for transient failures (429 / 5xx / network)
//   - a token-bucket rate limiter so callers don't blow past provider TPM caps
// Connection reuse lives in the transport layer (libcurl handle pool on Unix,
// shared WinHTTP session on Windows).
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

    Result<HttpResponse> put(
        const std::string& url,
        const std::string& body,
        const std::unordered_map<std::string, std::string>& headers = {});

    Result<HttpResponse> del(
        const std::string& url,
        const std::string& body = "",
        const std::unordered_map<std::string, std::string>& headers = {});

    // Retry policy. max_retries == 0 disables retrying. Delays grow
    // exponentially from base_delay_ms up to max_delay_ms.
    void set_retry_policy(int max_retries, int base_delay_ms, int max_delay_ms) {
        max_retries_ = max_retries < 0 ? 0 : max_retries;
        retry_base_delay_ms_ = base_delay_ms < 1 ? 1 : base_delay_ms;
        retry_max_delay_ms_ = max_delay_ms < retry_base_delay_ms_ ? retry_base_delay_ms_ : max_delay_ms;
    }

    // Requests-per-minute cap; 0 means unlimited.
    void set_rate_limit(int requests_per_minute) {
        rate_limiter_.set_rate(requests_per_minute);
    }

private:
    Result<HttpResponse> perform_with_retry(
        const std::string& method,
        const std::string& url,
        const std::string& body,
        const std::unordered_map<std::string, std::string>& headers,
        bool has_body,
        const StreamCallback& on_chunk);

    int max_retries_ = 3;
    int retry_base_delay_ms_ = 500;
    int retry_max_delay_ms_ = 8000;
    RateLimiter rate_limiter_;
};

} // namespace agentgraph
