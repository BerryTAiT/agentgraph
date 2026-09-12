#pragma once

#include <string>
#include <vector>
#include <optional>
#include <nlohmann/json.hpp>

namespace agentgraph {

using json = nlohmann::json;

enum class Role {
    System,
    User,
    Assistant,
    Tool
};

inline std::string role_to_string(Role r) {
    switch (r) {
        case Role::System:    return "system";
        case Role::User:      return "user";
        case Role::Assistant: return "assistant";
        case Role::Tool:      return "tool";
    }
    return "user";
}

inline Role string_to_role(const std::string& s) {
    if (s == "system") return Role::System;
    if (s == "user") return Role::User;
    if (s == "assistant") return Role::Assistant;
    if (s == "tool") return Role::Tool;
    return Role::User;
}

inline void role_to_json(json& j, Role r) {
    j = role_to_string(r);
}

inline void role_from_json(const json& j, Role& r) {
    r = string_to_role(j.get<std::string>());
}

struct ToolCall {
    std::string id;
    std::string name;
    json arguments;
};

inline void to_json(json& j, const ToolCall& tc) {
    j = json{
        {"id", tc.id},
        {"name", tc.name},
        {"arguments", tc.arguments}
    };
}

inline void from_json(const json& j, ToolCall& tc) {
    tc.id = j.at("id").get<std::string>();
    tc.name = j.at("name").get<std::string>();
    tc.arguments = j.at("arguments");
}

struct Message {
    Role role;
    std::string content;
    std::string id;
    std::string name;
    std::string tool_call_id;
    std::vector<ToolCall> tool_calls;

    static Message system(const std::string& content) {
        Message m;
        m.role = Role::System;
        m.content = content;
        return m;
    }

    static Message user(const std::string& content) {
        Message m;
        m.role = Role::User;
        m.content = content;
        return m;
    }

    static Message assistant(const std::string& content) {
        Message m;
        m.role = Role::Assistant;
        m.content = content;
        return m;
    }

    static Message tool_result(const std::string& tool_call_id,
                                const std::string& content) {
        Message m;
        m.role = Role::Tool;
        m.content = content;
        m.tool_call_id = tool_call_id;
        return m;
    }
};

inline void to_json(json& j, const Message& m) {
    j = json{{"role", role_to_string(m.role)}, {"content", m.content}};
    if (!m.id.empty()) j["id"] = m.id;
    if (!m.name.empty()) j["name"] = m.name;
    if (!m.tool_call_id.empty()) j["tool_call_id"] = m.tool_call_id;
    if (!m.tool_calls.empty()) j["tool_calls"] = m.tool_calls;
}

inline void from_json(const json& j, Message& m) {
    m.role = string_to_role(j.at("role").get<std::string>());
    if (j.contains("content") && !j["content"].is_null()) {
        m.content = j["content"].get<std::string>();
    }
    if (j.contains("id")) m.id = j["id"].get<std::string>();
    if (j.contains("name")) m.name = j["name"].get<std::string>();
    if (j.contains("tool_call_id")) m.tool_call_id = j["tool_call_id"].get<std::string>();
    if (j.contains("tool_calls")) m.tool_calls = j["tool_calls"].get<std::vector<ToolCall>>();
}

struct TokenUsage {
    int prompt_tokens = 0;
    int completion_tokens = 0;
    int total_tokens = 0;
};

inline void to_json(json& j, const TokenUsage& u) {
    j = json{
        {"prompt_tokens", u.prompt_tokens},
        {"completion_tokens", u.completion_tokens},
        {"total_tokens", u.total_tokens}
    };
}

inline void from_json(const json& j, TokenUsage& u) {
    if (j.contains("prompt_tokens")) u.prompt_tokens = j["prompt_tokens"].get<int>();
    if (j.contains("completion_tokens")) u.completion_tokens = j["completion_tokens"].get<int>();
    if (j.contains("total_tokens")) u.total_tokens = j["total_tokens"].get<int>();
}

enum class FinishReason {
    Stop,
    ToolCalls,
    Length,
    Error,
    Unknown
};

inline std::string finish_reason_to_string(FinishReason fr) {
    switch (fr) {
        case FinishReason::Stop:      return "stop";
        case FinishReason::ToolCalls: return "tool_calls";
        case FinishReason::Length:    return "length";
        case FinishReason::Error:     return "error";
        case FinishReason::Unknown:   return "unknown";
    }
    return "unknown";
}

inline FinishReason string_to_finish_reason(const std::string& s) {
    if (s == "stop") return FinishReason::Stop;
    if (s == "tool_calls") return FinishReason::ToolCalls;
    if (s == "length") return FinishReason::Length;
    if (s == "error") return FinishReason::Error;
    return FinishReason::Unknown;
}

struct LLMResponse {
    std::string content;
    std::vector<ToolCall> tool_calls;
    FinishReason finish_reason = FinishReason::Unknown;
    TokenUsage usage;
    std::string model;
    std::string error_message;
};

inline void to_json(json& j, const LLMResponse& r) {
    j = json{
        {"content", r.content},
        {"tool_calls", r.tool_calls},
        {"finish_reason", finish_reason_to_string(r.finish_reason)},
        {"usage", r.usage},
        {"model", r.model}
    };
    if (!r.error_message.empty()) j["error_message"] = r.error_message;
}

struct ToolSchema {
    std::string name;
    std::string description;
    json parameters;
};

inline void to_json(json& j, const ToolSchema& ts) {
    j = json{
        {"name", ts.name},
        {"description", ts.description},
        {"parameters", ts.parameters}
    };
}

inline void from_json(const json& j, ToolSchema& ts) {
    ts.name = j.at("name").get<std::string>();
    ts.description = j.value("description", "");
    ts.parameters = j.value("parameters", json::object());
}

} // namespace agentgraph
