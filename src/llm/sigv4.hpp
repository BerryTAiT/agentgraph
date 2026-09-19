#pragma once

#include <string>
#include <unordered_map>

namespace agentgraph {

// Computes AWS Signature Version 4 authentication headers for an HTTP
// request and merges them into `headers` (Authorization, x-amz-date,
// x-amz-content-sha256, and x-amz-security-token when a session token
// is provided).
void sigv4_sign(const std::string& method,
                const std::string& url,
                const std::string& body,
                const std::string& access_key,
                const std::string& secret_key,
                const std::string& session_token,
                const std::string& region,
                const std::string& service,
                std::unordered_map<std::string, std::string>& headers);

// Exposed for testing.
std::string sha256_hex(const std::string& data);
std::string hmac_sha256_hex(const std::string& key, const std::string& data);

} // namespace agentgraph
