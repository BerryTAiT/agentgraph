#include "http_client.hpp"

#ifdef _WIN32
#include <windows.h>
#include <winhttp.h>
#endif

#include <string>
#include <vector>

namespace agentgraph {

#ifdef _WIN32

static std::wstring to_wide(const std::string& s) {
    if (s.empty()) return L"";
    int len = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), nullptr, 0);
    std::wstring w(len, 0);
    MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), &w[0], len);
    return w;
}

struct ParsedUrl {
    bool is_https = false;
    std::string host;
    int port = 80;
    std::string path = "/";
};

static ParsedUrl parse_url(const std::string& url) {
    ParsedUrl p;
    size_t scheme_end = url.find("://");
    if (scheme_end == std::string::npos) {
        p.host = url;
        return p;
    }
    std::string scheme = url.substr(0, scheme_end);
    p.is_https = (scheme == "https");

    std::string rest = url.substr(scheme_end + 3);
    size_t path_start = rest.find('/');
    std::string hostport = (path_start == std::string::npos) ? rest : rest.substr(0, path_start);
    p.path = (path_start == std::string::npos) ? "/" : rest.substr(path_start);

    size_t colon = hostport.rfind(':');
    if (colon != std::string::npos) {
        p.host = hostport.substr(0, colon);
        p.port = std::stoi(hostport.substr(colon + 1));
    } else {
        p.host = hostport;
        p.port = p.is_https ? 443 : 80;
    }
    return p;
}

static std::wstring build_headers(
    const std::unordered_map<std::string, std::string>& headers) {
    std::wstring h;
    for (auto& [k, v] : headers) {
        h += to_wide(k) + L": " + to_wide(v) + L"\r\n";
    }
    return h;
}

static Result<HttpResponse> perform_request(
    const std::string& method,
    const std::string& url,
    const std::string& body,
    const std::unordered_map<std::string, std::string>& headers,
    bool has_body,
    const StreamCallback& on_chunk)
{
    ParsedUrl p = parse_url(url);

    HINTERNET session = WinHttpOpen(L"agentgraph/1.0",
        WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, WINHTTP_NO_PROXY_NAME,
        WINHTTP_NO_PROXY_BYPASS, 0);
    if (!session) {
        return Result<HttpResponse>::err("WinHttpOpen failed");
    }

    // resolve=30s, connect=30s, send=60s, receive=300s
    WinHttpSetTimeouts(session, 30000, 30000, 60000, 300000);

    HINTERNET conn = WinHttpConnect(session, to_wide(p.host).c_str(), p.port, 0);
    if (!conn) {
        WinHttpCloseHandle(session);
        return Result<HttpResponse>::err("WinHttpConnect failed");
    }

    DWORD flags = p.is_https ? WINHTTP_FLAG_SECURE : 0;
    std::wstring wmethod = to_wide(method);
    HINTERNET req = WinHttpOpenRequest(conn, wmethod.c_str(), to_wide(p.path).c_str(),
        nullptr, WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, flags);
    if (!req) {
        WinHttpCloseHandle(conn);
        WinHttpCloseHandle(session);
        return Result<HttpResponse>::err("WinHttpOpenRequest failed");
    }

    std::wstring headers_w = build_headers(headers);

    BOOL sent;
    if (has_body) {
        sent = WinHttpSendRequest(req, headers_w.empty() ? WINHTTP_NO_ADDITIONAL_HEADERS : headers_w.c_str(),
            headers_w.empty() ? 0 : (DWORD)-1,
            (LPVOID)body.c_str(), (DWORD)body.size(), (DWORD)body.size(), 0);
    } else {
        sent = WinHttpSendRequest(req, headers_w.empty() ? WINHTTP_NO_ADDITIONAL_HEADERS : headers_w.c_str(),
            headers_w.empty() ? 0 : (DWORD)-1,
            WINHTTP_NO_REQUEST_DATA, 0, 0, 0);
    }

    if (!sent) {
        WinHttpCloseHandle(req);
        WinHttpCloseHandle(conn);
        WinHttpCloseHandle(session);
        return Result<HttpResponse>::err("WinHttpSendRequest failed");
    }

    if (!WinHttpReceiveResponse(req, nullptr)) {
        WinHttpCloseHandle(req);
        WinHttpCloseHandle(conn);
        WinHttpCloseHandle(session);
        return Result<HttpResponse>::err("WinHttpReceiveResponse failed");
    }

    DWORD status = 0;
    DWORD status_size = sizeof(status);
    WinHttpQueryHeaders(req, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
        WINHTTP_HEADER_NAME_BY_INDEX, &status, &status_size, WINHTTP_NO_HEADER_INDEX);

    std::string resp_body;
    char buf[8192];
    DWORD bytes_read = 0;
    while (WinHttpReadData(req, buf, sizeof(buf), &bytes_read) && bytes_read > 0) {
        resp_body.append(buf, bytes_read);
        if (on_chunk) {
            on_chunk(std::string(buf, bytes_read));
        }
    }

    WinHttpCloseHandle(req);
    WinHttpCloseHandle(conn);
    WinHttpCloseHandle(session);

    HttpResponse response;
    response.status_code = static_cast<int>(status);
    response.body = std::move(resp_body);
    return Result<HttpResponse>::ok(std::move(response));
}

#else // non-Windows fallback: not implemented yet (httplib will be used here)

static Result<HttpResponse> perform_request(
    const std::string&, const std::string&, const std::string&,
    const std::unordered_map<std::string, std::string>&, bool,
    const StreamCallback&)
{
    return Result<HttpResponse>::err("Native HTTP client is Windows-only in this build");
}

#endif // _WIN32

Result<HttpResponse> HttpClient::post(
    const std::string& url,
    const std::string& body,
    const std::unordered_map<std::string, std::string>& headers)
{
    return perform_request("POST", url, body, headers, true, nullptr);
}

Result<HttpResponse> HttpClient::post_stream(
    const std::string& url,
    const std::string& body,
    const std::unordered_map<std::string, std::string>& headers,
    const StreamCallback& on_chunk)
{
    return perform_request("POST", url, body, headers, true, on_chunk);
}

Result<HttpResponse> HttpClient::get(
    const std::string& url,
    const std::unordered_map<std::string, std::string>& headers)
{
    return perform_request("GET", url, "", headers, false, nullptr);
}

} // namespace agentgraph
