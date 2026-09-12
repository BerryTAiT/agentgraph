#include "builtin_tools.hpp"
#include <cmath>
#include <fstream>
#include <sstream>

namespace agentgraph {

static Result<json> calculator_handler(const json& args) {
    if (!args.contains("expression")) {
        return Result<json>::err("Missing 'expression' parameter");
    }
    std::string expr = args["expression"].get<std::string>();

    try {
        double result = std::nan("");
        size_t pos = 0;

        if (expr.find('+') != std::string::npos ||
            expr.find('-') != std::string::npos ||
            expr.find('*') != std::string::npos ||
            expr.find('/') != std::string::npos) {
            double a = std::stod(expr, &pos);
            char op = ' ';
            size_t start = pos;
            while (start < expr.size() && expr[start] == ' ') start++;
            if (start < expr.size()) op = expr[start];
            double b = std::stod(expr.substr(start + 1));

            switch (op) {
                case '+': result = a + b; break;
                case '-': result = a - b; break;
                case '*': result = a * b; break;
                case '/':
                    if (b == 0) return Result<json>::err("Division by zero");
                    result = a / b;
                    break;
                default:
                    return Result<json>::err("Unsupported operator: " + std::string(1, op));
            }
        } else {
            result = std::stod(expr);
        }

        return Result<json>::ok(json{{"result", result}, {"expression", expr}});
    } catch (...) {
        return Result<json>::err("Failed to evaluate expression: " + expr);
    }
}

static Result<json> read_file_handler(const json& args) {
    if (!args.contains("path")) {
        return Result<json>::err("Missing 'path' parameter");
    }
    std::string path = args["path"].get<std::string>();
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
