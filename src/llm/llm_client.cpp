#include "llm_client.hpp"

namespace agentgraph {

OpenAIClient::OpenAIClient(const ProviderConfig& config) : config_(config) {}

std::unordered_map<std::string, std::string> OpenAIClient::build_headers() const {
    std::unordered_map<std::string, std::string> headers;
    headers["Content-Type"] = "application/json";
    headers["Authorization"] = "Bearer " + config_.api_key;
    return headers;
}

json OpenAIClient::build_tool_schema(const ToolSchema& tool) const {
    return json{
        {"type", "function"},
        {"function", {
            {"name", tool.name},
            {"description", tool.description},
            {"parameters", tool.parameters}
        }}
    };
}

json OpenAIClient::build_request(
    const std::vector<Message>& messages,
    const std::vector<ToolSchema>& tools,
    const std::string& system_prompt,
    bool stream) const
{
    json req;
    req["model"] = config_.model;
    req["max_tokens"] = config_.max_tokens;
    req["temperature"] = config_.temperature;
    req["stream"] = stream;

    json msgs = json::array();
    if (!system_prompt.empty()) {
        msgs.push_back({{"role", "system"}, {"content", system_prompt}});
    }
    for (auto& msg : messages) {
        json m;
        m["role"] = role_to_string(msg.role);

        if (msg.role == Role::Tool) {
            m["content"] = msg.content;
            m["tool_call_id"] = msg.tool_call_id;
        } else if (!msg.tool_calls.empty()) {
            m["content"] = msg.content.empty() ? json(nullptr) : json(msg.content);
            json tcs = json::array();
            for (auto& tc : msg.tool_calls) {
                tcs.push_back({
                    {"id", tc.id},
                    {"type", "function"},
                    {"function", {
                        {"name", tc.name},
                        {"arguments", tc.arguments.dump()}
                    }}
                });
            }
            m["tool_calls"] = tcs;
        } else {
            m["content"] = msg.content;
        }
        msgs.push_back(m);
    }
    req["messages"] = msgs;

    if (!tools.empty()) {
        json tool_arr = json::array();
        for (auto& t : tools) {
            tool_arr.push_back(build_tool_schema(t));
        }
        req["tools"] = tool_arr;
    }

    return req;
}

LLMResponse OpenAIClient::parse_response(const json& resp) const {
    LLMResponse result;

    if (resp.contains("error")) {
        result.error_message = resp["error"].value("message", "Unknown error");
        result.finish_reason = FinishReason::Error;
        return result;
    }

    auto& choice = resp["choices"][0];
    auto& message = choice["message"];

    if (message.contains("content") && !message["content"].is_null()) {
        result.content = message["content"].get<std::string>();
    } else {
        result.content = "";
    }

    if (message.contains("tool_calls") && !message["tool_calls"].is_null()) {
        for (auto& tc : message["tool_calls"]) {
            ToolCall call;
            call.id = tc["id"].get<std::string>();
            call.name = tc["function"]["name"].get<std::string>();
            try {
                call.arguments = json::parse(tc["function"]["arguments"].get<std::string>());
            } catch (...) {
                call.arguments = json::object();
            }
            result.tool_calls.push_back(call);
        }
    }

    if (choice.contains("finish_reason") && !choice["finish_reason"].is_null()) {
        result.finish_reason = string_to_finish_reason(choice["finish_reason"].get<std::string>());
    }

    if (resp.contains("usage")) {
        auto& u = resp["usage"];
        result.usage.prompt_tokens = u.value("prompt_tokens", 0);
        result.usage.completion_tokens = u.value("completion_tokens", 0);
        result.usage.total_tokens = u.value("total_tokens", 0);
    }

    result.model = resp.value("model", config_.model);
    return result;
}

Result<LLMResponse> OpenAIClient::complete(
    const std::vector<Message>& messages,
    const std::vector<ToolSchema>& tools,
    const std::string& system_prompt)
{
    auto req = build_request(messages, tools, system_prompt, false);
    auto headers = build_headers();
    std::string url = config_.base_url + "/chat/completions";

    auto http_result = http_.post(url, req.dump(), headers);
    if (http_result.is_err()) {
        return Result<LLMResponse>::err(http_result.error().message);
    }

    auto& resp = http_result.value();
    if (resp.status_code != 200) {
        try {
            auto err_json = json::parse(resp.body);
            std::string msg = err_json.value("error", json::object()).value("message", resp.body);
            return Result<LLMResponse>::err("API error (" + std::to_string(resp.status_code) + "): " + msg);
        } catch (...) {
            return Result<LLMResponse>::err("API error (" + std::to_string(resp.status_code) + "): " + resp.body);
        }
    }

    try {
        auto parsed = json::parse(resp.body);
        return Result<LLMResponse>::ok(parse_response(parsed));
    } catch (const std::exception& e) {
        return Result<LLMResponse>::err(std::string("Failed to parse response: ") + e.what());
    }
}

Result<LLMResponse> OpenAIClient::complete_stream(
    const std::vector<Message>& messages,
    const TokenCallback& on_token,
    const std::vector<ToolSchema>& tools,
    const std::string& system_prompt)
{
    auto req = build_request(messages, tools, system_prompt, true);
    auto headers = build_headers();
    std::string url = config_.base_url + "/chat/completions";

    LLMResponse final_response;
    final_response.model = config_.model;
    std::string accumulated_content;

    SSEParser sse;
    auto sse_callback = [&final_response, &accumulated_content, &on_token](const json& chunk) {
        if (chunk.contains("choices") && !chunk["choices"].empty()) {
            auto& delta = chunk["choices"][0]["delta"];

            if (delta.contains("content") && !delta["content"].is_null()) {
                std::string token = delta["content"].get<std::string>();
                accumulated_content += token;
                on_token(token);
            }

            if (delta.contains("tool_calls") && !delta["tool_calls"].is_null()) {
                for (auto& tc_delta : delta["tool_calls"]) {
                    int idx = tc_delta.value("index", 0);
                    while (static_cast<int>(final_response.tool_calls.size()) <= idx) {
                        final_response.tool_calls.push_back(ToolCall{});
                    }
                    auto& tc = final_response.tool_calls[idx];
                    if (tc_delta.contains("id")) tc.id = tc_delta["id"].get<std::string>();
                    if (tc_delta.contains("function")) {
                        if (tc_delta["function"].contains("name"))
                            tc.name += tc_delta["function"]["name"].get<std::string>();
                        if (tc_delta["function"].contains("arguments"))
                            tc.arguments = json::parse(tc_delta["function"]["arguments"].get<std::string>());
                    }
                }
            }

            if (chunk["choices"][0].contains("finish_reason") &&
                !chunk["choices"][0]["finish_reason"].is_null()) {
                final_response.finish_reason = string_to_finish_reason(
                    chunk["choices"][0]["finish_reason"].get<std::string>());
            }
        }
    };

    auto http_result = http_.post_stream(url, req.dump(), headers,
        [&sse, &sse_callback](const std::string& chunk) {
            sse.feed(chunk, sse_callback);
        });

    if (http_result.is_err()) {
        return Result<LLMResponse>::err(http_result.error().message);
    }

    auto& resp = http_result.value();
    if (resp.status_code != 200) {
        return Result<LLMResponse>::err("API error (" + std::to_string(resp.status_code) + "): " + resp.body);
    }

    final_response.content = accumulated_content;
    if (final_response.finish_reason == FinishReason::Unknown) {
        final_response.finish_reason = FinishReason::Stop;
    }

    return Result<LLMResponse>::ok(std::move(final_response));
}

} // namespace agentgraph
