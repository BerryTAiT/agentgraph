#include "sigv4.hpp"

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <ctime>
#include <mutex>
#include <utility>
#include <vector>

namespace agentgraph {

namespace {

constexpr uint32_t K[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
    0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
    0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
    0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
    0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
    0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
};

inline uint32_t rotr(uint32_t x, uint32_t n) {
    return (x >> n) | (x << (32 - n));
}

class Sha256 {
public:
    Sha256() {
        h_[0] = 0x6a09e667; h_[1] = 0xbb67ae85; h_[2] = 0x3c6ef372;
        h_[3] = 0xa54ff53a; h_[4] = 0x510e527f; h_[5] = 0x9b05688c;
        h_[6] = 0x1f83d9ab; h_[7] = 0x5be0cd19;
    }

    void update(const uint8_t* data, size_t n) {
        for (size_t i = 0; i < n; i++) {
            buf_[buf_len_++] = data[i];
            if (buf_len_ == 64) {
                transform(buf_);
                buf_len_ = 0;
            }
        }
        len_ += n;
    }

    void final(uint8_t out[32]) {
        uint64_t bitlen = len_ * 8;
        uint8_t pad = 0x80;
        update(&pad, 1);
        uint8_t zero = 0;
        while (buf_len_ != 56) update(&zero, 1);
        for (int i = 0; i < 8; i++) {
            uint8_t b = static_cast<uint8_t>(bitlen >> (56 - 8 * i));
            update(&b, 1);
        }
        for (int i = 0; i < 8; i++) {
            out[4 * i]     = static_cast<uint8_t>(h_[i] >> 24);
            out[4 * i + 1] = static_cast<uint8_t>(h_[i] >> 16);
            out[4 * i + 2] = static_cast<uint8_t>(h_[i] >> 8);
            out[4 * i + 3] = static_cast<uint8_t>(h_[i]);
        }
    }

private:
    void transform(const uint8_t* p) {
        uint32_t w[64];
        for (int i = 0; i < 16; i++) {
            w[i] = (static_cast<uint32_t>(p[4 * i]) << 24) |
                   (static_cast<uint32_t>(p[4 * i + 1]) << 16) |
                   (static_cast<uint32_t>(p[4 * i + 2]) << 8) |
                    static_cast<uint32_t>(p[4 * i + 3]);
        }
        for (int i = 16; i < 64; i++) {
            uint32_t s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
            uint32_t s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16] + s0 + w[i - 7] + s1;
        }
        uint32_t a = h_[0], b = h_[1], c = h_[2], d = h_[3];
        uint32_t e = h_[4], f = h_[5], g = h_[6], h = h_[7];
        for (int i = 0; i < 64; i++) {
            uint32_t S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
            uint32_t ch = (e & f) ^ (~e & g);
            uint32_t t1 = h + S1 + ch + K[i] + w[i];
            uint32_t S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
            uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
            uint32_t t2 = S0 + maj;
            h = g; g = f; f = e; e = d + t1;
            d = c; c = b; b = a; a = t1 + t2;
        }
        h_[0] += a; h_[1] += b; h_[2] += c; h_[3] += d;
        h_[4] += e; h_[5] += f; h_[6] += g; h_[7] += h;
    }

    uint32_t h_[8];
    uint64_t len_ = 0;
    uint8_t buf_[64];
    size_t buf_len_ = 0;
};

std::string to_hex(const uint8_t* p, size_t n) {
    static const char* hex = "0123456789abcdef";
    std::string out;
    out.reserve(n * 2);
    for (size_t i = 0; i < n; i++) {
        out += hex[p[i] >> 4];
        out += hex[p[i] & 0x0f];
    }
    return out;
}

std::string sha256_raw(const std::string& data) {
    Sha256 h;
    h.update(reinterpret_cast<const uint8_t*>(data.data()), data.size());
    uint8_t d[32];
    h.final(d);
    return std::string(reinterpret_cast<const char*>(d), 32);
}

std::string hmac_sha256_raw(const std::string& key, const std::string& data) {
    uint8_t k[64];
    std::memset(k, 0, sizeof(k));
    if (key.size() > 64) {
        std::string kh = sha256_raw(key);
        std::memcpy(k, kh.data(), kh.size());
    } else {
        std::memcpy(k, key.data(), key.size());
    }
    uint8_t ipad[64], opad[64];
    for (int i = 0; i < 64; i++) {
        ipad[i] = static_cast<uint8_t>(k[i] ^ 0x36);
        opad[i] = static_cast<uint8_t>(k[i] ^ 0x5c);
    }
    Sha256 inner;
    inner.update(ipad, 64);
    inner.update(reinterpret_cast<const uint8_t*>(data.data()), data.size());
    uint8_t id[32];
    inner.final(id);
    Sha256 outer;
    outer.update(opad, 64);
    outer.update(id, 32);
    uint8_t od[32];
    outer.final(od);
    return std::string(reinterpret_cast<const char*>(od), 32);
}

// RFC 3986 percent-encoding with unreserved chars kept as-is.
std::string uri_encode(const std::string& s, bool encode_slash) {
    static const char* hex = "0123456789ABCDEF";
    std::string out;
    out.reserve(s.size());
    for (unsigned char c : s) {
        bool unreserved = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                          (c >= '0' && c <= '9') || c == '-' || c == '.' ||
                          c == '_' || c == '~';
        if (unreserved) {
            out += static_cast<char>(c);
        } else if (c == '/' && !encode_slash) {
            out += '/';
        } else {
            out += '%';
            out += hex[c >> 4];
            out += hex[c & 0x0f];
        }
    }
    return out;
}

void split_url(const std::string& url, std::string& host, std::string& path, std::string& query) {
    size_t scheme_end = url.find("://");
    size_t host_start = (scheme_end == std::string::npos) ? 0 : scheme_end + 3;
    size_t path_start = url.find('/', host_start);
    std::string hostport = (path_start == std::string::npos)
        ? url.substr(host_start)
        : url.substr(host_start, path_start - host_start);
    std::string path_query = (path_start == std::string::npos) ? "/" : url.substr(path_start);

    // Keep "host:port" as-is so the canonical host matches what the HTTP
    // client actually sends.
    host = hostport;

    size_t q = path_query.find('?');
    if (q == std::string::npos) {
        path = path_query;
        query = "";
    } else {
        path = path_query.substr(0, q);
        query = path_query.substr(q + 1);
    }
}

std::string canonical_query_string(const std::string& query) {
    if (query.empty()) return "";
    std::vector<std::pair<std::string, std::string>> pairs;
    size_t start = 0;
    while (start <= query.size()) {
        size_t amp = query.find('&', start);
        std::string kv = (amp == std::string::npos) ? query.substr(start) : query.substr(start, amp - start);
        if (!kv.empty()) {
            size_t eq = kv.find('=');
            if (eq == std::string::npos) {
                pairs.emplace_back(uri_encode(kv, true), "");
            } else {
                pairs.emplace_back(uri_encode(kv.substr(0, eq), true),
                                   uri_encode(kv.substr(eq + 1), true));
            }
        }
        if (amp == std::string::npos) break;
        start = amp + 1;
    }
    std::sort(pairs.begin(), pairs.end());
    std::string out;
    for (size_t i = 0; i < pairs.size(); i++) {
        if (i > 0) out += "&";
        out += pairs[i].first + "=" + pairs[i].second;
    }
    return out;
}

std::tm utc_now() {
    std::time_t now = std::time(nullptr);
    static std::mutex mtx;
    std::lock_guard<std::mutex> lock(mtx);
    std::tm tmv = *std::gmtime(&now);
    return tmv;
}

std::string format_amz_date(const std::tm& tmv) {
    char buf[17];
    std::strftime(buf, sizeof(buf), "%Y%m%dT%H%M%SZ", &tmv);
    return buf;
}

} // namespace

std::string sha256_hex(const std::string& data) {
    return to_hex(reinterpret_cast<const uint8_t*>(sha256_raw(data).data()), 32);
}

std::string hmac_sha256_hex(const std::string& key, const std::string& data) {
    std::string mac = hmac_sha256_raw(key, data);
    return to_hex(reinterpret_cast<const uint8_t*>(mac.data()), 32);
}

void sigv4_sign(const std::string& method,
                const std::string& url,
                const std::string& body,
                const std::string& access_key,
                const std::string& secret_key,
                const std::string& session_token,
                const std::string& region,
                const std::string& service,
                std::unordered_map<std::string, std::string>& headers)
{
    std::string host, path, query;
    split_url(url, host, path, query);

    std::string payload_hash = sha256_hex(body);
    std::string amz_date = format_amz_date(utc_now());
    std::string date_scope = amz_date.substr(0, 8);

    // Canonical headers must be lowercase and sorted by name.
    std::string canonical_headers =
        "host:" + host + "\n" +
        "x-amz-content-sha256:" + payload_hash + "\n" +
        "x-amz-date:" + amz_date + "\n";
    std::string signed_headers = "host;x-amz-content-sha256;x-amz-date";
    if (!session_token.empty()) {
        canonical_headers += "x-amz-security-token:" + session_token + "\n";
        signed_headers += ";x-amz-security-token";
    }

    std::string canonical_request =
        method + "\n" +
        uri_encode(path, false) + "\n" +
        canonical_query_string(query) + "\n" +
        canonical_headers + "\n" +
        signed_headers + "\n" +
        payload_hash;

    std::string scope = date_scope + "/" + region + "/" + service + "/aws4_request";
    std::string string_to_sign =
        "AWS4-HMAC-SHA256\n" + amz_date + "\n" + scope + "\n" +
        sha256_hex(canonical_request);

    std::string k_date = hmac_sha256_raw("AWS4" + secret_key, date_scope);
    std::string k_region = hmac_sha256_raw(k_date, region);
    std::string k_service = hmac_sha256_raw(k_region, service);
    std::string k_signing = hmac_sha256_raw(k_service, "aws4_request");
    std::string signature = to_hex(
        reinterpret_cast<const uint8_t*>(hmac_sha256_raw(k_signing, string_to_sign).data()), 32);

    headers["x-amz-date"] = amz_date;
    headers["x-amz-content-sha256"] = payload_hash;
    if (!session_token.empty()) {
        headers["x-amz-security-token"] = session_token;
    }
    headers["Authorization"] =
        "AWS4-HMAC-SHA256 Credential=" + access_key + "/" + scope +
        ", SignedHeaders=" + signed_headers + ", Signature=" + signature;
}

} // namespace agentgraph
