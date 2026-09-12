#pragma once

#include "../core/types.hpp"
#include "../core/errors.hpp"

#include <cstdint>
#include <mutex>
#include <string>

namespace agentgraph {

// JSON-RPC client for the agentgraph tool server (an isolated R process).
//
// The engine registers custom R tool handlers through this client instead of
// calling back into R from C++ worker threads (which is unsafe while the main
// R thread is blocked inside run_graph_cpp, and racy under parallel fan-out).
//
// Protocol: one persistent TCP connection to 127.0.0.1:<port>, newline-framed
// JSON, strictly one response line per request line. All calls are serialized
// by a mutex so concurrent worker threads share the connection safely.
class RpcToolClient {
public:
    RpcToolClient(const std::string& host, std::uint16_t port);
    ~RpcToolClient();

    RpcToolClient(const RpcToolClient&) = delete;
    RpcToolClient& operator=(const RpcToolClient&) = delete;

    // Execute a tool by name on the server. `arguments` is forwarded as a raw
    // JSON string (arguments.dump()), exactly what an in-process R handler
    // would receive; the returned value is the handler's parsed JSON output.
    Result<json> call(const std::string& tool_name, const json& arguments);

private:
    bool ensure_connected();
    void close_socket();
    bool send_all(const std::string& data);
    Result<std::string> read_line();

    std::string host_;
    std::uint16_t port_;
    std::uint64_t sock_;
    bool wsa_ok_ = false;
    std::mutex mutex_;

    static constexpr std::uint64_t kInvalidSock = ~static_cast<std::uint64_t>(0);
};

} // namespace agentgraph
