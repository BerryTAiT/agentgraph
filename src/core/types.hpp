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

// An image reference inside a multimodal content part. `url` is either an
// http(s) URL or a base64 data URL; `detail` is the optional OpenAI vision
// resolution hint ("auto" | "low" | "high").
struct ImageUrl {
    std::string url;
    std::string detail;
};

inline void to_json(json& j, const ImageUrl& iu) {
    j = json{{"url", iu.url}};
    if (!iu.detail.empty()) j["detail"] = iu.detail;
}

inline void from_json(const json& j, ImageUrl& iu) {
    iu.url = j.value("url", "");
    iu.detail = j.value("detail", "");
}

// A video reference inside a multimodal content part. `url` is an http(s)
// URL or a base64 data URL (OpenAI-compatible "video_url" part).
struct VideoUrl {
    std::string url;
};

inline void to_json(json& j, const VideoUrl& vu) {
    j = json{{"url", vu.url}};
}

inline void from_json(const json& j, VideoUrl& vu) {
    vu.url = j.value("url", "");
}

// An audio reference. Two wire forms are supported:
//   - Chat Completions / Responses inline audio:
//     {"type":"input_audio","input_audio":{"data":"<base64>","format":"wav"}}
//   - Responses-style file reference:
//     {"type":"input_audio","file_id":"file-..."}  (flat)
struct InputAudio {
    std::string data;      // base64-encoded audio (inline form)
    std::string format;    // encoding, e.g. "wav" / "mp3" (inline form)
    std::string file_id;   // Responses-style file reference (flat form)
};

inline void to_json(json& j, const InputAudio& ia) {
    j = json{{"data", ia.data}};
    if (!ia.format.empty()) j["format"] = ia.format;
}

inline void from_json(const json& j, InputAudio& ia) {
    ia.data = j.value("data", "");
    ia.format = j.value("format", "");
}

// A video reference by uploaded-file id (OpenAI Responses API style):
// {"type":"input_video","file_id":"file-..."}  (flat)
struct InputVideo {
    std::string file_id;
};

inline void to_json(json& j, const InputVideo& iv) {
    j = json{{"file_id", iv.file_id}};
}

inline void from_json(const json& j, InputVideo& iv) {
    iv.file_id = j.value("file_id", "");
}

// An image reference by uploaded-file id (OpenAI Responses API style):
// {"type":"input_image","file_id":"file-..."}  (flat)
struct InputImage {
    std::string file_id;
};

inline void to_json(json& j, const InputImage& im) {
    j = json{{"file_id", im.file_id}};
}

inline void from_json(const json& j, InputImage& im) {
    im.file_id = j.value("file_id", "");
}

// A single content part. The OpenAI-compatible multimodal wire format models
// a message `content` as an array of parts:
//   {"type":"text","text":...}
//   {"type":"image_url","image_url":{"url":...}}
//   {"type":"video_url","video_url":{"url":...}}
//   {"type":"input_audio","input_audio":{"data":...,"format":...}}   (inline)
//   {"type":"input_audio","file_id":"file-..."}                       (Responses)
//   {"type":"input_video","file_id":"file-..."}                       (Responses)
//   {"type":"input_image","file_id":"file-..."}                       (Responses)
struct ContentPart {
    std::string type;      // "text", "image_url", "video_url", "input_audio", "input_video", or "input_image"
    std::string text;      // set for text parts
    ImageUrl image_url;    // set for image_url parts
    VideoUrl video_url;    // set for video_url parts
    InputAudio input_audio; // set for input_audio parts
    InputVideo input_video; // set for input_video parts
    InputImage input_image; // set for input_image parts
};

inline void to_json(json& j, const ContentPart& p) {
    j = json{{"type", p.type}};
    if (p.type == "text") {
        j["text"] = p.text;
    } else if (p.type == "image_url") {
        j["image_url"] = p.image_url;
    } else if (p.type == "video_url") {
        j["video_url"] = p.video_url;
    } else if (p.type == "input_audio") {
        if (!p.input_audio.file_id.empty()) {
            j["file_id"] = p.input_audio.file_id;      // flat file reference
        } else {
            j["input_audio"] = p.input_audio;          // nested {data, format}
        }
    } else if (p.type == "input_video") {
        j["file_id"] = p.input_video.file_id;          // flat file reference
    } else if (p.type == "input_image") {
        j["file_id"] = p.input_image.file_id;          // flat file reference
    }
}

inline void from_json(const json& j, ContentPart& p) {
    p.type = j.value("type", "");
    if (j.contains("text")) p.text = j["text"].get<std::string>();
    if (j.contains("image_url")) p.image_url = j["image_url"].get<ImageUrl>();
    if (j.contains("video_url")) p.video_url = j["video_url"].get<VideoUrl>();
    if (j.contains("input_audio")) p.input_audio = j["input_audio"].get<InputAudio>();
    if (j.contains("input_video")) p.input_video = j["input_video"].get<InputVideo>();
    if (j.contains("input_image")) p.input_image = j["input_image"].get<InputImage>();
    // Flat file-id forms sit directly on the part, not nested.
    if (j.contains("file_id")) {
        if (p.type == "input_video") {
            p.input_video.file_id = j["file_id"].get<std::string>();
        } else if (p.type == "input_audio") {
            p.input_audio.file_id = j["file_id"].get<std::string>();
        } else if (p.type == "input_image") {
            p.input_image.file_id = j["file_id"].get<std::string>();
        }
    }
}

// Collapse a response `content` value (plain string or array of parts) into a
// single string, joining text parts in order. Used by response parsing so
// vision replies that come back as content arrays still yield text.
inline std::string content_to_string(const json& content) {
    if (content.is_string()) return content.get<std::string>();
    if (content.is_array()) {
        std::string out;
        for (const auto& part : content) {
            if (part.is_object() && part.value("type", "") == "text") {
                out += part.value("text", "");
            }
        }
        return out;
    }
    return "";
}

struct Message {
    Role role;
    std::string content;
    std::vector<ContentPart> parts;
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
    j = json{{"role", role_to_string(m.role)}};
    if (!m.parts.empty()) {
        j["content"] = m.parts;
    } else {
        j["content"] = m.content;
    }
    if (!m.id.empty()) j["id"] = m.id;
    if (!m.name.empty()) j["name"] = m.name;
    if (!m.tool_call_id.empty()) j["tool_call_id"] = m.tool_call_id;
    if (!m.tool_calls.empty()) j["tool_calls"] = m.tool_calls;
}

inline void from_json(const json& j, Message& m) {
    m.role = string_to_role(j.at("role").get<std::string>());
    if (j.contains("content") && !j["content"].is_null()) {
        if (j["content"].is_array()) {
            m.parts = j["content"].get<std::vector<ContentPart>>();
        } else if (j["content"].is_string()) {
            m.content = j["content"].get<std::string>();
        }
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
