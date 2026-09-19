#pragma once

#include <string>
#include <regex>

namespace agentgraph {

// Redact common PII from a string before it leaves the process. This is a
// heuristic, non-cryptographic scrubber: it trades recall for safety, so a
// long run of digits that merely resembles a credit-card number will also be
// redacted. Patterns are applied in a canonical order (email -> API key ->
// private key -> JWT -> AWS secret -> US SSN -> credit-card-like digits ->
// US phone -> IPv4) so a broader pattern never partially redacts something a
// more specific pattern would have caught first (e.g. a phone-shaped prefix
// inside a 16-digit card number).
inline std::string scrub_pii(const std::string& input,
                             const std::string& redact = "[REDACTED]") {
    std::string s = input;
    const auto replace = [&](const char* pattern) {
        try {
            s = std::regex_replace(s, std::regex(pattern), redact);
        } catch (...) {
            // A malformed pattern must never take down an LLM call.
        }
    };

    // email
    replace(R"([A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,})");
    // API keys / secrets (OpenAI sk-, Anthropic sk-ant-, GitHub PATs, AWS AKIA, Google AIza)
    replace(R"(\b(?:sk|pk|rk|ghp|gho|ghu|ghs|ghr|AKIA|AIza)[A-Za-z0-9_\-]{16,}\b)");
    // PEM private-key headers (RSA / EC / OPENSSH / PGP / generic)
    replace(R"(-----BEGIN (?:RSA |EC |OPENSSH |PGP )?PRIVATE KEY(?: BLOCK)?-----)");
    // JSON Web Tokens (header.payload.signature, base64url; header starts "eyJ")
    replace(R"(\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b)");
    // AWS secret-access-key-shaped strings (40 base64 chars)
    replace(R"(\b[A-Za-z0-9/+=]{40}\b)");
    // US Social Security Number
    replace(R"(\b\d{3}-\d{2}-\d{4}\b)");
    // credit-card-like digit runs (13-19 digits, optional space/hyphen separators;
    // the trailing `\d\b` keeps the match from swallowing the following space)
    replace(R"(\b(?:\d[ -]?){12,18}\d\b)");
    // US/Canada phone numbers (optional +1 and separators; the optional country
    // code carries its own separator so a bare number never eats a leading space)
    replace(R"((?:\+?1[-.\s]?)?\(?\d{3}\)?[-.\s]?\d{3}[-.\s]?\d{4})");
    // IPv4 addresses
    replace(R"(\b(?:\d{1,3}\.){3}\d{1,3}\b)");

    return s;
}

} // namespace agentgraph
