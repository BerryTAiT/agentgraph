#include "builtin_tools.hpp"
#include <cmath>
#include <charconv>
#include <cctype>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <sstream>
#include <string>
#include <vector>

namespace agentgraph {

// Recursive-descent evaluator for arithmetic expressions:
//   expression := term (('+' | '-') term)*
//   term       := unary (('*' | '/') unary)*
//   unary      := ('+' | '-') unary | primary
//   primary    := number | '(' expression ')'
// This replaces the previous single-binary-op evaluator, which silently
// returned wrong results for chained or mixed expressions ("10-2-3", "3+4*2").
namespace {

class ExpressionParser {
public:
    explicit ExpressionParser(const std::string& text) : src_(text) {}

    double parse() {
        pos_ = 0;
        double v = parse_expression();
        skip_ws();
        if (pos_ != src_.size()) {
            throw std::runtime_error("unexpected character at position " +
                                     std::to_string(pos_));
        }
        return v;
    }

private:
    const std::string& src_;
    size_t pos_ = 0;

    void skip_ws() {
        while (pos_ < src_.size() && std::isspace(static_cast<unsigned char>(src_[pos_]))) {
            pos_++;
        }
    }

    bool consume(char c) {
        skip_ws();
        if (pos_ < src_.size() && src_[pos_] == c) {
            pos_++;
            return true;
        }
        return false;
    }

    double parse_expression() {
        double v = parse_term();
        while (true) {
            if (consume('+')) {
                v += parse_term();
            } else if (consume('-')) {
                v -= parse_term();
            } else {
                return v;
            }
        }
    }

    double parse_term() {
        double v = parse_unary();
        while (true) {
            if (consume('*')) {
                v *= parse_unary();
            } else if (consume('/')) {
                double d = parse_unary();
                if (d == 0.0) throw std::runtime_error("Division by zero");
                v /= d;
            } else {
                return v;
            }
        }
    }

    double parse_unary() {
        if (consume('-')) return -parse_unary();
        if (consume('+')) return parse_unary();
        return parse_primary();
    }

    double parse_primary() {
        skip_ws();
        if (consume('(')) {
            double v = parse_expression();
            if (!consume(')')) {
                throw std::runtime_error("missing closing parenthesis");
            }
            return v;
        }

        skip_ws();
        double value = 0.0;
        auto [ptr, ec] = std::from_chars(src_.data() + pos_,
                                         src_.data() + src_.size(), value);
        if (ec != std::errc() || ptr == src_.data() + pos_) {
            throw std::runtime_error("expected a number");
        }
        pos_ = static_cast<size_t>(ptr - src_.data());
        return value;
    }
};

} // namespace

// ---------------------------------------------------------------------------
// Filesystem policy for the built-in file tools.
//
// The native `read_file` / `write_file` tools execute in-process, so the R-side
// tool_policy()/restrict_tool() wrapper cannot see their arguments. Instead,
// the policy is enforced here: the environment variables AGENTGRAPH_FS_ALLOW
// and AGENTGRAPH_FS_DENY hold ';'-separated directory prefixes. When AGENTGRAPH_FS_ALLOW
// is set, file paths must resolve under one of the allowed directories; any path
// under a denied directory is always rejected. Paths are canonicalized with
// std::filesystem (resolving "." / ".." and, when the target exists, symlinks)
// before the prefix check, so traversal tricks like "allowed/../../etc/passwd"
// cannot escape. Both variables empty = unrestricted (backwards compatible).
// Use the R helper file_tools_policy() to set this up for the session.
// ---------------------------------------------------------------------------
namespace fs_policy {

struct Policy {
    bool configured = false;   // true once allow or deny prefixes are set
    std::vector<std::string> allow;
    std::vector<std::string> deny;
};

static std::string to_lower(std::string s) {
    for (auto& c : s) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return s;
}

// Canonical, absolute, normalized path in generic ("/") form. On Windows the
// comparison is case-insensitive, matching the filesystem.
static std::string canonicalize(const std::string& path) {
    std::error_code ec;
    std::filesystem::path p(path);
    std::filesystem::path abs = p.is_absolute()
        ? p : std::filesystem::absolute(p, ec);
    if (ec) abs = p;
    std::filesystem::path canon = std::filesystem::weakly_canonical(abs, ec);
    if (ec) canon = abs.lexically_normal();
    std::string s = canon.generic_string();
    while (s.size() > 1 && s.back() == '/') s.pop_back();
#ifdef _WIN32
    s = to_lower(s);
#endif
    return s;
}

static bool path_within(const std::string& path, const std::string& prefix) {
    if (path == prefix) return true;
    return path.size() > prefix.size() &&
           path.compare(0, prefix.size(), prefix) == 0 &&
           path[prefix.size()] == '/';
}

static const Policy& policy() {
    static Policy p;
    static std::once_flag once;
    std::call_once(once, []() {
        auto split_env = [](const char* name, std::vector<std::string>& out) {
            const char* v = std::getenv(name);
            if (!v || !*v) return;
            std::string s(v);
            size_t start = 0;
            while (start <= s.size()) {
                size_t sep = s.find(';', start);
                std::string item = s.substr(start, sep == std::string::npos
                                                 ? std::string::npos : sep - start);
                if (!item.empty()) out.push_back(canonicalize(item));
                if (sep == std::string::npos) break;
                start = sep + 1;
            }
        };
        split_env("AGENTGRAPH_FS_ALLOW", p.allow);
        split_env("AGENTGRAPH_FS_DENY", p.deny);
        p.configured = !p.allow.empty() || !p.deny.empty();
    });
    return p;
}

// Returns an empty string when `path` is allowed, otherwise the reason it was
// rejected (used as the tool error message).
static std::string check(const std::string& path) {
    const Policy& p = policy();
    if (!p.configured) return "";
    std::string canon = canonicalize(path);
    for (const auto& d : p.deny) {
        if (path_within(canon, d)) {
            return "tool policy: path '" + path + "' is denied";
        }
    }
    if (!p.allow.empty()) {
        for (const auto& a : p.allow) {
            if (path_within(canon, a)) return "";
        }
        return "tool policy: path '" + path + "' is not within an allowed directory";
    }
    return "";
}

} // namespace fs_policy

static Result<json> calculator_handler(const json& args) {
    if (!args.contains("expression")) {
        return Result<json>::err("Missing 'expression' parameter");
    }
    std::string expr = args["expression"].get<std::string>();

    try {
        double result = ExpressionParser(expr).parse();
        if (std::isnan(result) || std::isinf(result)) {
            return Result<json>::err("Failed to evaluate expression: " + expr);
        }
        return Result<json>::ok(json{{"result", result}, {"expression", expr}});
    } catch (const std::exception& e) {
        return Result<json>::err("Failed to evaluate expression: " + expr +
                                 " (" + e.what() + ")");
    }
}

static Result<json> read_file_handler(const json& args) {
    if (!args.contains("path")) {
        return Result<json>::err("Missing 'path' parameter");
    }
    std::string path = args["path"].get<std::string>();
    std::string policy_err = fs_policy::check(path);
    if (!policy_err.empty()) {
        return Result<json>::err(policy_err);
    }
    std::ifstream file(path);
    if (!file.is_open()) {
        return Result<json>::err("Cannot open file: " + path);
    }
    std::stringstream ss;
    ss << file.rdbuf();
    return Result<json>::ok(json{{"content", ss.str()}, {"path", path}});
}

static Result<json> write_file_handler(const json& args) {
    if (!args.contains("path") || !args.contains("content")) {
        return Result<json>::err("Missing 'path' or 'content' parameter");
    }
    std::string path = args["path"].get<std::string>();
    std::string content = args["content"].get<std::string>();
    std::string policy_err = fs_policy::check(path);
    if (!policy_err.empty()) {
        return Result<json>::err(policy_err);
    }
    std::ofstream file(path);
    if (!file.is_open()) {
        return Result<json>::err("Cannot write to file: " + path);
    }
    file << content;
    return Result<json>::ok(json{{"success", true}, {"path", path}});
}

void register_builtin_tools(ToolRegistry& registry) {
    registry.register_tool("calculator", "Evaluate a math expression",
        json{
            {"type", "object"},
            {"properties", {
                {"expression", {{"type", "string"}, {"description", "Math expression to evaluate"}}}
            }},
            {"required", json::array({"expression"})}
        },
        calculator_handler);

    registry.register_tool("read_file", "Read contents of a file",
        json{
            {"type", "object"},
            {"properties", {
                {"path", {{"type", "string"}, {"description", "File path to read"}}}
            }},
            {"required", json::array({"path"})}
        },
        read_file_handler);

    registry.register_tool("write_file", "Write content to a file",
        json{
            {"type", "object"},
            {"properties", {
                {"path", {{"type", "string"}, {"description", "File path to write"}}},
                {"content", {{"type", "string"}, {"description", "Content to write"}}}
            }},
            {"required", json::array({"path", "content"})}
        },
        write_file_handler);
}

} // namespace agentgraph
