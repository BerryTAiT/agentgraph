#include "http_client.hpp"

#ifdef _WIN32
#include <windows.h>
#include <winhttp.h>
#endif

#include <string>
#include <vector>
#include <thread>
#include <chrono>

namespace agentgraph {

static bool is_retryable_status(int status) {
    // 429 = rate limited, 5xx = transient server failure. These are the codes
    // worth retrying with backoff; 4xx client errors are not retried.
    return status == 429 || status == 500 || status == 502 || status == 503 || status == 504;
}

static long long backoff_delay_ms(int attempt, int base_ms, int cap_ms) {
    long long d = base_ms;
    for (int i = 1; i < attempt; ++i) {
        if (d >= cap_ms) break;
        d *= 2;
    }
    return d > cap_ms ? cap_ms : d;
}

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

namespace {
struct WinHttpSession {
    HINTERNET handle = nullptr;
};
WinHttpSession& winhttp_session() {
    static WinHttpSession s;
    static std::once_flag once;
    std::call_once(once, []() {
        HINTERNET h = WinHttpOpen(L"agentgraph/1.0",
            WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, WINHTTP_NO_PROXY_NAME,
            WINHTTP_NO_PROXY_BYPASS, 0);
        if (h) {
            // resolve=30s, connect=30s, send=60s, receive=300s
            WinHttpSetTimeouts(h, 30000, 30000, 60000, 300000);
        }
        s.handle = h;
    });
    return s;
}
} // namespace

static Result<HttpResponse> perform_request(
    const std::string& method,
    const std::string& url,
    const std::string& body,
    const std::unordered_map<std::string, std::string>& headers,
    bool has_body,
    const StreamCallback& on_chunk)
{
    ParsedUrl p = parse_url(url);

    // The WinHTTP session handle is process-wide and shared across requests;
    // this avoids re-opening the session (and re-setting timeouts) on every
    // call. Connection handles are still per-request because WinHTTP handles
    // are not safe to share across threads.
    HINTERNET session = winhttp_session().handle;
    if (!session) {
        return Result<HttpResponse>::err("WinHttpOpen failed");
    }

    HINTERNET conn = WinHttpConnect(session, to_wide(p.host).c_str(), p.port, 0);
    if (!conn) {
        return Result<HttpResponse>::err("WinHttpConnect failed");
    }

    DWORD flags = p.is_https ? WINHTTP_FLAG_SECURE : 0;
    std::wstring wmethod = to_wide(method);
    HINTERNET req = WinHttpOpenRequest(conn, wmethod.c_str(), to_wide(p.path).c_str(),
        nullptr, WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, flags);
    if (!req) {
        WinHttpCloseHandle(conn);
        return Result<HttpResponse>::err("WinHttpOpenRequest failed");
    }

    // Redirect policy: follow at most a few redirects, and never silently
    // downgrade HTTPS -> HTTP (which would expose the Authorization header and
    // request body in cleartext). WinHTTP otherwise allows both by default.
    DWORD redirects = 3;
    WinHttpSetOption(req, WINHTTP_OPTION_MAX_HTTP_AUTOMATIC_REDIRECTS,
                     &redirects, sizeof(redirects));
    DWORD redirect_policy = WINHTTP_OPTION_REDIRECT_POLICY_NEVER;
    WinHttpSetOption(req, WINHTTP_OPTION_REDIRECT_POLICY,
                     &redirect_policy, sizeof(redirect_policy));

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
        return Result<HttpResponse>::err("WinHttpSendRequest failed");
    }

    if (!WinHttpReceiveResponse(req, nullptr)) {
        WinHttpCloseHandle(req);
        WinHttpCloseHandle(conn);
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

    HttpResponse response;
    response.status_code = static_cast<int>(status);
    response.body = std::move(resp_body);
    return Result<HttpResponse>::ok(std::move(response));
}

#else // !_WIN32: libcurl backend (Linux, macOS, and other Unix)

#include <curl/curl.h>
#include <mutex>

namespace {

std::once_flag curl_global_once;

void ensure_curl_global_init() {
    // curl_global_init() is not thread-safe and the engine fires concurrent
    // requests from worker threads (chat_parallel), so run it exactly once.
    std::call_once(curl_global_once, []() {
        curl_global_init(CURL_GLOBAL_DEFAULT);
    });
}

struct WriteContext {
    std::string* body;
    const StreamCallback* on_chunk;
};

size_t curl_write_cb(char* ptr, size_t size, size_t nmemb, void* userdata) {
    auto* ctx = static_cast<WriteContext*>(userdata);
    size_t total = size * nmemb;
    ctx->body->append(ptr, total);
    if (ctx->on_chunk && *ctx->on_chunk) {
        (*ctx->on_chunk)(std::string(ptr, total));
    }
    return total;
}

// Simple connection pool: libcurl reuses TCP connections only when the same
// easy handle performs subsequent requests. We keep idle handles keyed by
// origin, checkout one per request, and check it back in afterwards.
struct CurlPool {
    std::mutex mu;
    std::unordered_map<std::string, std::vector<CURL*>> idle;
    ~CurlPool() {
        for (auto& kv : idle)
            for (CURL* c : kv.second) curl_easy_cleanup(c);
    }
};

CurlPool& curl_pool() { static CurlPool p; return p; }

std::string origin_of(const std::string& url) {
    size_t scheme_end = url.find("://");
    size_t start = (scheme_end == std::string::npos) ? 0 : scheme_end + 3;
    size_t path_start = url.find('/', start);
    return (path_start == std::string::npos) ? url.substr(start)
                                             : url.substr(start, path_start - start);
}

CURL* pool_acquire(const std::string& key) {
    CurlPool& p = curl_pool();
    std::lock_guard<std::mutex> lk(p.mu);
    auto it = p.idle.find(key);
    if (it != p.idle.end() && !it->second.empty()) {
        CURL* c = it->second.back();
        it->second.pop_back();
        return c;
    }
    return nullptr;
}

void pool_release(const std::string& key, CURL* c) {
    CurlPool& p = curl_pool();
    std::lock_guard<std::mutex> lk(p.mu);
    p.idle[key].push_back(c);
}

} // namespace

static Result<HttpResponse> perform_request(
    const std::string& method,
    const std::string& url,
    const std::string& body,
    const std::unordered_map<std::string, std::string>& headers,
    bool has_body,
    const StreamCallback& on_chunk)
{
    ensure_curl_global_init();

    std::string key = origin_of(url);
    CURL* curl = pool_acquire(key);
    if (!curl) curl = curl_easy_init();
    if (!curl) {
        return Result<HttpResponse>::err("curl_easy_init failed");
    }
    // Reset to defaults but keep the live connection + DNS caches so the next
    // request to the same origin reuses the connection.
    curl_easy_reset(curl);

    std::string resp_body;
    WriteContext ctx{&resp_body, on_chunk ? &on_chunk : nullptr};

    curl_slist* header_list = nullptr;
    for (auto& [name, value] : headers) {
        header_list = curl_slist_append(header_list, (name + ": " + value).c_str());
    }

    curl_easy_setopt(curl, CURLOPT_URL, url.c_str());
    curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);        // required for thread safety
    curl_easy_setopt(curl, CURLOPT_NOPROGRESS, 1L);
    // Follow redirects, but bound the chain and never downgrade HTTPS -> HTTP
    // (which would expose credentials + payloads in cleartext; SSRF redirect
    // chains are likewise cut short). CURLOPT_REDIR_PROTOCOLS (long bitmask,
    // libcurl >= 7.19.1) is used instead of the *_STR variant so builds on
    // older distros (libcurl 7.6x-7.7x) still compile.
    curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(curl, CURLOPT_MAXREDIRS, 3L);
    curl_easy_setopt(curl, CURLOPT_REDIR_PROTOCOLS, CURLPROTO_HTTPS);
    curl_easy_setopt(curl, CURLOPT_USERAGENT, "agentgraph/1.0");
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, curl_write_cb);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &ctx);
    curl_easy_setopt(curl, CURLOPT_TCP_KEEPALIVE, 1L);
    // Mirrors the WinHTTP timeouts: 30s to connect; abort only if the
    // transfer stalls (no data at all) for 300s — no total-duration cap,
    // so long streamed responses are not cut off.
    curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, 30L);
    curl_easy_setopt(curl, CURLOPT_LOW_SPEED_LIMIT, 1L);
    curl_easy_setopt(curl, CURLOPT_LOW_SPEED_TIME, 300L);
    if (header_list) {
        curl_easy_setopt(curl, CURLOPT_HTTPHEADER, header_list);
    }

    if (method == "GET") {
        curl_easy_setopt(curl, CURLOPT_HTTPGET, 1L);
    } else if (method == "POST" && has_body) {
        curl_easy_setopt(curl, CURLOPT_POST, 1L);
        curl_easy_setopt(curl, CURLOPT_POSTFIELDS, body.c_str());
        curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, static_cast<long>(body.size()));
    } else {
        curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, method.c_str());
        if (has_body) {
            curl_easy_setopt(curl, CURLOPT_POSTFIELDS, body.c_str());
            curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, static_cast<long>(body.size()));
        }
    }

    CURLcode rc = curl_easy_perform(curl);

    long status = 0;
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &status);

    if (header_list) curl_slist_free_all(header_list);
    pool_release(key, curl);

    if (rc != CURLE_OK) {
        return Result<HttpResponse>::err(std::string("HTTP request failed: ") +
                                         curl_easy_strerror(rc));
    }

    HttpResponse response;
    response.status_code = static_cast<int>(status);
    response.body = std::move(resp_body);
    return Result<HttpResponse>::ok(std::move(response));
}

#endif // _WIN32

Result<HttpResponse> HttpClient::perform_with_retry(
    const std::string& method,
    const std::string& url,
    const std::string& body,
    const std::unordered_map<std::string, std::string>& headers,
    bool has_body,
    const StreamCallback& on_chunk)
{
    Result<HttpResponse> last;
    for (int attempt = 0; attempt <= max_retries_; ++attempt) {
        if (attempt > 0) {
            std::this_thread::sleep_for(std::chrono::milliseconds(
                backoff_delay_ms(attempt, retry_base_delay_ms_, retry_max_delay_ms_)));
        }
        rate_limiter_.acquire();
        last = perform_request(method, url, body, headers, has_body, on_chunk);
        if (last.is_ok() && !is_retryable_status(last.value().status_code)) {
            return last;
        }
        // Retryable status (429/5xx) or transport error: loop and back off.
    }
    return last;
}

Result<HttpResponse> HttpClient::post(
    const std::string& url,
    const std::string& body,
    const std::unordered_map<std::string, std::string>& headers)
{
    return perform_with_retry("POST", url, body, headers, true, nullptr);
}

Result<HttpResponse> HttpClient::post_stream(
    const std::string& url,
    const std::string& body,
    const std::unordered_map<std::string, std::string>& headers,
    const StreamCallback& on_chunk)
{
    // Rate-limit but do not retry streams: retrying would re-emit chunks the
    // caller already consumed, corrupting the token stream.
    rate_limiter_.acquire();
    return perform_request("POST", url, body, headers, true, on_chunk);
}

Result<HttpResponse> HttpClient::get(
    const std::string& url,
    const std::unordered_map<std::string, std::string>& headers)
{
    return perform_with_retry("GET", url, "", headers, false, nullptr);
}

Result<HttpResponse> HttpClient::put(
    const std::string& url,
    const std::string& body,
    const std::unordered_map<std::string, std::string>& headers)
{
    return perform_with_retry("PUT", url, body, headers, true, nullptr);
}

Result<HttpResponse> HttpClient::del(
    const std::string& url,
    const std::string& body,
    const std::unordered_map<std::string, std::string>& headers)
{
    return perform_with_retry("DELETE", url, body, headers, !body.empty(), nullptr);
}

} // namespace agentgraph
