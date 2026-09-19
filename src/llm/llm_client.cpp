#include "llm_client.hpp"
#include "sigv4.hpp"
#include "pii.hpp"
#include "usage_registry.hpp"

namespace agentgraph {

FallbackClient::FallbackClient(std::vector<std::unique_ptr<LLMClient>> chain)
    : chain_(std::move(chain)) {}

Result<LLMResponse> FallbackClient::complete(
    const std::vector<Message>& messages,
    const std::vector<ToolSchema>& tools,
    const std::string& system_prompt)
{
    std::string last_error = "fallback chain is empty";
    for (auto& client : chain_) {
        try {
            auto r = client->complete(messages, tools, system_prompt);
            if (r.is_ok()) return r;
            last_error = r.error().message;
        } catch (const std::exception& e) {
            last_error = e.what();
        } catch (...) {
            last_error = "unknown exception";
        }
    }
    return Result<LLMResponse>::err("all fallback providers failed: " + last_error);
}

Result<LLMResponse> FallbackClient::complete_stream(
    const std::vector<Message>& messages,
    const TokenCallback& on_token,
    const std::vector<ToolSchema>& tools,
    const std::string& system_prompt)
{
    std::string last_error = "fallback chain is empty";
    for (auto& client : chain_) {
        try {
            auto r = client->complete_stream(messages, on_token, tools, system_prompt);
            if (r.is_ok()) return r;
            last_error = r.error().message;
        } catch (const std::exception& e) {
            last_error = e.what();
        } catch (...) {
            last_error = "unknown exception";
        }
    }
    return Result<LLMResponse>::err("all fallback providers failed: " + last_error);
}

CachedLLMClient::CachedLLMClient(std::unique_ptr<LLMClient> inner,
                                 const ProviderConfig& config)
    : inner_(std::move(inner)), config_(config)
{
    // Namespace isolates caches (and their TTL/max-entries) per distinct
    // provider endpoint + model so two providers sharing a process never
    // cross-serve each other's entries.
    ns_ = config.name + "|" + config.base_url + "|" + config.model + "|" +
          config.api_version;
    cache_ = LLMCacheRegistry::instance().get(ns_, config.cache_ttl_seconds,
                                              config.cache_max_entries);
}

std::string CachedLLMClient::make_key(
    const std::vector<Message>& messages,
    const std::vector<ToolSchema>& tools,
    const std::string& system_prompt) const
{
    // The key captures everything that can change the response: the full
    // message list (including multimodal parts and tool calls), tool schemas,
    // the system prompt, and the provider/model/sampling identity. Sampling
    // parameters are included so changing max_tokens/temperature yields a
    // distinct cache slot. `stream` is deliberately omitted so streamed and
    // non-streamed calls share one entry.
    json key = {
        {"provider", config_.name},
        {"base_url", config_.base_url},
        {"model", config_.model},
        {"api_version", config_.api_version},
        {"max_tokens", config_.max_tokens},
        {"temperature", config_.temperature},
        {"system_prompt", system_prompt},
        {"messages", messages},
        {"tools", tools}
    };
    return key.dump();
}

Result<LLMResponse> CachedLLMClient::complete(
    const std::vector<Message>& messages,
    const std::vector<ToolSchema>& tools,
    const std::string& system_prompt)
{
    std::string key = make_key(messages, tools, system_prompt);
    if (auto hit = cache_->get(key)) {
        LLMCacheRegistry::instance().record_hit();
        return Result<LLMResponse>::ok(std::move(*hit));
    }
    LLMCacheRegistry::instance().record_miss();
    auto r = inner_->complete(messages, tools, system_prompt);
    if (r.is_ok()) {
        cache_->put(key, r.value());
    }
    return r;
}

Result<LLMResponse> CachedLLMClient::complete_stream(
    const std::vector<Message>& messages,
    const TokenCallback& on_token,
    const std::vector<ToolSchema>& tools,
    const std::string& system_prompt)
{
    std::string key = make_key(messages, tools, system_prompt);
    if (auto hit = cache_->get(key)) {
        LLMCacheRegistry::instance().record_hit();
        // Replay the cached content as a single token. Exact per-chunk stream
        // fidelity is not preserved (the tokens were never re-emitted by the
        // model), but the full response content is delivered to the callback
        // and returned identically.
        if (on_token && !hit->content.empty()) {
            on_token(hit->content);
        }
        return Result<LLMResponse>::ok(std::move(*hit));
    }
    LLMCacheRegistry::instance().record_miss();
    auto r = inner_->complete_stream(messages, on_token, tools, system_prompt);
    if (r.is_ok()) {
        cache_->put(key, r.value());
    }
    return r;
}

OpenAIClient::OpenAIClient(const ProviderConfig& config) : config_(config) {
    // Wire the provider's retry/backoff + rate-limit policy into the shared
    // HTTP transport so every LLM call is automatically retried on 429/5xx
    // and throttled to the configured requests-per-minute cap.
    http_.set_retry_policy(config.max_retries, config.retry_base_delay_ms,
                           config.retry_max_delay_ms);
    http_.set_rate_limit(config.requests_per_minute);
}

std::string OpenAIClient::url_for() const {
    if (config_.name == "azure" && !config_.api_version.empty()) {
        return config_.base_url + "/chat/completions?api-version=" + config_.api_version;
    }
    return config_.base_url + "/chat/completions";
}

std::unordered_map<std::string, std::string> OpenAIClient::build_headers(const std::string& body) const {
    std::unordered_map<std::string, std::string> headers;
    headers["Content-Type"] = "application/json";

    if (config_.name == "azure") {
        headers["api-key"] = config_.api_key;
    } else if (config_.name == "bedrock") {
        sigv4_sign("POST", url_for(), body,
                   config_.aws_access_key_id, config_.aws_secret_access_key,
                   config_.aws_session_token,
                   config_.aws_region.empty() ? "us-east-1" : config_.aws_region,
                   "bedrock", headers);
    } else {
        headers["Authorization"] = "Bearer " + config_.api_key;
    }
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
        std::string sp = system_prompt;
        if (config_.pii_filter) sp = scrub_pii(sp, config_.pii_redact);
        msgs.push_back({{"role", "system"}, {"content", sp}});
    }
    for (auto& msg : messages) {
        json m;
        m["role"] = role_to_string(msg.role);

        auto scrubbed = [&](const std::string& s) {
            return config_.pii_filter ? scrub_pii(s, config_.pii_redact) : s;
        };

        if (msg.role == Role::Tool) {
            m["content"] = scrubbed(msg.content);
            m["tool_call_id"] = msg.tool_call_id;
        } else if (!msg.tool_calls.empty()) {
            m["content"] = msg.content.empty() ? json(nullptr) : json(scrubbed(msg.content));
            json tcs = json::array();
            for (auto& tc : msg.tool_calls) {
                tcs.push_back({
                    {"id", tc.id},
                    {"type", "function"},
                    {"function", {
                        {"name", tc.name},
                        {"arguments", scrubbed(tc.arguments.dump())}
                    }}
                });
            }
            m["tool_calls"] = tcs;
        } else if (!msg.parts.empty()) {
            if (config_.pii_filter) {
                json parts = json::array();
                for (auto& p : msg.parts) {
                    json pj = p;  // uses ContentPart::to_json
                    if (p.type == "text") {
                        pj["text"] = scrub_pii(p.text, config_.pii_redact);
                    }
                    parts.push_back(pj);
                }
                m["content"] = parts;
            } else {
                m["content"] = msg.parts;
            }
        } else {
            m["content"] = scrubbed(msg.content);
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
        result.content = content_to_string(message["content"]);
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
    auto headers = build_headers(req.dump());
    std::string url = url_for();

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
        auto response = parse_response(parsed);
        double cost = (response.usage.prompt_tokens * config_.input_price_per_1m +
                       response.usage.completion_tokens * config_.output_price_per_1m) / 1e6;
        UsageRegistry::instance().add(response.usage, cost);
        return Result<LLMResponse>::ok(std::move(response));
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
    auto headers = build_headers(req.dump());
    std::string url = url_for();

    LLMResponse final_response;
    final_response.model = config_.model;
    std::string accumulated_content;
    // Tool-call arguments arrive as JSON-string fragments spread across
    // deltas; each fragment is partial JSON, so they are accumulated raw
    // here and parsed once after the stream completes.
    std::vector<std::string> args_acc;

    SSEParser sse;
    auto sse_callback = [&final_response, &accumulated_content, &args_acc, &on_token](const json& chunk) {
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
                        args_acc.emplace_back();
                    }
                    auto& tc = final_response.tool_calls[idx];
                    if (tc_delta.contains("id")) tc.id = tc_delta["id"].get<std::string>();
                    if (tc_delta.contains("function")) {
                        if (tc_delta["function"].contains("name"))
                            tc.name += tc_delta["function"]["name"].get<std::string>();
                        if (tc_delta["function"].contains("arguments"))
                            args_acc[idx] += tc_delta["function"]["arguments"].get<std::string>();
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

    // Parse each accumulated tool-call argument string exactly once. A
    // fragment that never formed valid JSON degrades to an empty object,
    // matching the non-streaming path's behaviour.
    for (size_t i = 0; i < final_response.tool_calls.size(); i++) {
        const std::string& raw = (i < args_acc.size()) ? args_acc[i] : std::string();
        try {
            final_response.tool_calls[i].arguments =
                raw.empty() ? json::object() : json::parse(raw);
        } catch (...) {
            final_response.tool_calls[i].arguments = json::object();
        }
    }

    if (final_response.finish_reason == FinishReason::Unknown) {
        final_response.finish_reason = FinishReason::Stop;
    }

    {
        double cost = (final_response.usage.prompt_tokens * config_.input_price_per_1m +
                       final_response.usage.completion_tokens * config_.output_price_per_1m) / 1e6;
        UsageRegistry::instance().add(final_response.usage, cost);
    }

    return Result<LLMResponse>::ok(std::move(final_response));
}

} // namespace agentgraph
