#include "rpc_tool_client.hpp"

#ifdef _WIN32
  #ifndef WIN32_LEAN_AND_MEAN
  #define WIN32_LEAN_AND_MEAN
  #endif
  #ifndef NOMINMAX
  #define NOMINMAX
  #endif
  #include <winsock2.h>
  #include <ws2tcpip.h>
#else
  #include <arpa/inet.h>
  #include <netdb.h>
  #include <netinet/in.h>
  #include <sys/socket.h>
  #include <sys/types.h>
  #include <unistd.h>
#endif

#include <cstring>

namespace agentgraph {

#ifdef _WIN32
using socket_handle_t = SOCKET;
constexpr socket_handle_t kInvalidHandle = INVALID_SOCKET;
#else
using socket_handle_t = int;
constexpr socket_handle_t kInvalidHandle = -1;
#endif

RpcToolClient::RpcToolClient(const std::string& host, std::uint16_t port)
    : host_(host), port_(port), sock_(kInvalidSock) {
#ifdef _WIN32
    WSADATA data;
    wsa_ok_ = (WSAStartup(MAKEWORD(2, 2), &data) == 0);
#else
    wsa_ok_ = true;
#endif
}

RpcToolClient::~RpcToolClient() {
    close_socket();
#ifdef _WIN32
    if (wsa_ok_) WSACleanup();
#endif
}

void RpcToolClient::close_socket() {
    if (sock_ != kInvalidSock) {
        socket_handle_t s = static_cast<socket_handle_t>(sock_);
#ifdef _WIN32
        ::closesocket(s);
#else
        ::close(s);
#endif
        sock_ = kInvalidSock;
    }
}

bool RpcToolClient::ensure_connected() {
    if (sock_ != kInvalidSock) return true;
    if (!wsa_ok_) return false;

    struct addrinfo hints;
    std::memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_protocol = IPPROTO_TCP;

    struct addrinfo* result = nullptr;
    if (::getaddrinfo(host_.c_str(), std::to_string(port_).c_str(),
                      &hints, &result) != 0 || result == nullptr) {
        return false;
    }

    socket_handle_t s = ::socket(result->ai_family, result->ai_socktype,
                                 result->ai_protocol);
    if (s == kInvalidHandle) {
        freeaddrinfo(result);
        return false;
    }

    if (::connect(s, result->ai_addr, static_cast<int>(result->ai_addrlen)) != 0) {
#ifdef _WIN32
        ::closesocket(s);
#else
        ::close(s);
#endif
        freeaddrinfo(result);
        return false;
    }
    freeaddrinfo(result);

    int one = 1;
    ::setsockopt(s, IPPROTO_TCP, TCP_NODELAY,
                 reinterpret_cast<const char*>(&one), sizeof(one));

    sock_ = static_cast<std::uint64_t>(s);
    return true;
}

bool RpcToolClient::send_all(const std::string& data) {
    size_t sent = 0;
    while (sent < data.size()) {
        int n = ::send(static_cast<socket_handle_t>(sock_),
                       data.data() + sent,
                       static_cast<int>(data.size() - sent), 0);
        if (n <= 0) return false;
        sent += static_cast<size_t>(n);
    }
    return true;
}

Result<std::string> RpcToolClient::read_line() {
    std::string line;
    char buf[4096];
    while (true) {
        int n = ::recv(static_cast<socket_handle_t>(sock_), buf, sizeof(buf), 0);
        if (n == 0) {
            return Result<std::string>::err(
                "tool server: connection closed by server");
        }
        if (n < 0) {
            return Result<std::string>::err("tool server: receive failed");
        }
        line.append(buf, static_cast<size_t>(n));
        size_t nl = line.find('\n');
        if (nl != std::string::npos) {
            line.resize(nl);
            return Result<std::string>::ok(std::move(line));
        }
        if (line.size() > (64u * 1024u * 1024u)) {
            return Result<std::string>::err("tool server: response too large");
        }
    }
}

Result<json> RpcToolClient::call(const std::string& tool_name,
                                 const json& arguments) {
    std::lock_guard<std::mutex> lock(mutex_);

    if (!ensure_connected()) {
        return Result<json>::err("tool server: cannot connect to " + host_ +
                                 ":" + std::to_string(port_));
    }

    json req;
    req["name"] = tool_name;
    req["args_json"] = arguments.dump();
    std::string line = req.dump();
    line.push_back('\n');

    if (!send_all(line)) {
        close_socket();
        return Result<json>::err("tool server: send failed (connection lost)");
    }

    auto resp_line = read_line();
    if (resp_line.is_err()) {
        close_socket();
        return Result<json>::err(resp_line.error().message);
    }

    try {
        json resp = json::parse(resp_line.value());
        if (resp.value("ok", false)) {
            const std::string result_str = resp.value("result_str", std::string());
            try {
                return Result<json>::ok(json::parse(result_str));
            } catch (const std::exception& e) {
                return Result<json>::err(
                    std::string("tool handler returned invalid JSON: ") + e.what());
            }
        }
        return Result<json>::err(
            resp.value("error", std::string("tool server: unknown error")));
    } catch (const std::exception& e) {
        return Result<json>::err(
            std::string("tool server: malformed response: ") + e.what());
    }
}

} // namespace agentgraph
