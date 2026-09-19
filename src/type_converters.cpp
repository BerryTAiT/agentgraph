#include "type_converters.h"


namespace agentgraph {

static bool list_has(const Rcpp::List& l, const std::string& name) {
    Rcpp::CharacterVector names = l.names();
    if (names.isNULL()) return false;
    for (int i = 0; i < names.size(); i++) {
        if (Rcpp::as<std::string>(names[i]) == name) return true;
    }
    return false;
}

ProviderConfig provider_from_list(const Rcpp::List& l) {
    ProviderConfig c;
    if (list_has(l, "name")) c.name = Rcpp::as<std::string>(l["name"]);
    if (list_has(l, "api_key")) c.api_key = Rcpp::as<std::string>(l["api_key"]);
    if (list_has(l, "base_url")) c.base_url = Rcpp::as<std::string>(l["base_url"]);
    if (list_has(l, "model")) c.model = Rcpp::as<std::string>(l["model"]);
    if (list_has(l, "max_tokens")) c.max_tokens = Rcpp::as<int>(l["max_tokens"]);
    if (list_has(l, "temperature")) c.temperature = Rcpp::as<double>(l["temperature"]);
    if (list_has(l, "max_retries")) c.max_retries = Rcpp::as<int>(l["max_retries"]);
    if (list_has(l, "retry_base_delay_ms")) c.retry_base_delay_ms = Rcpp::as<int>(l["retry_base_delay_ms"]);
    if (list_has(l, "retry_max_delay_ms")) c.retry_max_delay_ms = Rcpp::as<int>(l["retry_max_delay_ms"]);
    if (list_has(l, "requests_per_minute")) c.requests_per_minute = Rcpp::as<int>(l["requests_per_minute"]);
    if (list_has(l, "cache_ttl_seconds")) c.cache_ttl_seconds = Rcpp::as<int>(l["cache_ttl_seconds"]);
    if (list_has(l, "cache_max_entries")) c.cache_max_entries = Rcpp::as<int>(l["cache_max_entries"]);
    if (list_has(l, "pii_filter")) c.pii_filter = Rcpp::as<bool>(l["pii_filter"]);
    if (list_has(l, "pii_redact")) c.pii_redact = Rcpp::as<std::string>(l["pii_redact"]);
    if (list_has(l, "input_price_per_1m")) c.input_price_per_1m = Rcpp::as<double>(l["input_price_per_1m"]);
    if (list_has(l, "output_price_per_1m")) c.output_price_per_1m = Rcpp::as<double>(l["output_price_per_1m"]);
    if (list_has(l, "api_version")) c.api_version = Rcpp::as<std::string>(l["api_version"]);
    if (list_has(l, "aws_access_key_id")) c.aws_access_key_id = Rcpp::as<std::string>(l["aws_access_key_id"]);
    if (list_has(l, "aws_secret_access_key")) c.aws_secret_access_key = Rcpp::as<std::string>(l["aws_secret_access_key"]);
    if (list_has(l, "aws_session_token")) c.aws_session_token = Rcpp::as<std::string>(l["aws_session_token"]);
    if (list_has(l, "aws_region")) c.aws_region = Rcpp::as<std::string>(l["aws_region"]);

    if (list_has(l, "fallbacks")) {
        Rcpp::List fl = l["fallbacks"];
        for (int i = 0; i < fl.size(); i++) {
            Rcpp::List pl = fl[i];
            c.fallbacks.push_back(provider_from_list(pl));
        }
    }

    return c;
}

NodeConfig node_from_list(const Rcpp::List& l) {
    NodeConfig n;
    if (list_has(l, "id")) n.id = Rcpp::as<std::string>(l["id"]);

    std::string type_str = "llm";
    if (list_has(l, "type")) type_str = Rcpp::as<std::string>(l["type"]);
    if (type_str == "llm") n.type = NodeType::LLM;
    else if (type_str == "tool") n.type = NodeType::Tool;
    else if (type_str == "router") n.type = NodeType::Router;
    else if (type_str == "subgraph") n.type = NodeType::Subgraph;
    else if (type_str == "function") n.type = NodeType::Function;
    else if (type_str == "parallel") n.type = NodeType::Parallel;
    else if (type_str == "interrupt") n.type = NodeType::Interrupt;

    if (list_has(l, "provider")) n.provider = provider_from_list(l["provider"]);
    if (list_has(l, "system_prompt")) n.system_prompt = Rcpp::as<std::string>(l["system_prompt"]);
    if (list_has(l, "description")) n.description = Rcpp::as<std::string>(l["description"]);

    if (list_has(l, "memory")) {
        Rcpp::List mem = l["memory"];
        if (list_has(mem, "window_size")) n.memory.window_size = Rcpp::as<int>(mem["window_size"]);
        if (list_has(mem, "summarize")) n.memory.summarize = Rcpp::as<bool>(mem["summarize"]);
        if (list_has(mem, "entity_memory")) n.memory.entity_memory = Rcpp::as<bool>(mem["entity_memory"]);
        if (list_has(mem, "summary_system_prompt")) n.memory.summary_system_prompt = Rcpp::as<std::string>(mem["summary_system_prompt"]);
    }

    if (list_has(l, "tool_names")) {
        Rcpp::CharacterVector tn = l["tool_names"];
        for (int i = 0; i < tn.size(); i++) {
            n.tool_names.push_back(Rcpp::as<std::string>(tn[i]));
        }
    }

    if (list_has(l, "sub_node_ids")) {
        Rcpp::CharacterVector sn = l["sub_node_ids"];
        for (int i = 0; i < sn.size(); i++) {
            n.sub_node_ids.push_back(Rcpp::as<std::string>(sn[i]));
        }
    }

    if (list_has(l, "sub_graph")) {
        n.sub_graph = std::make_shared<GraphConfig>(graph_from_list(l["sub_graph"]));
    }

    return n;
}

EdgeConfig edge_from_list(const Rcpp::List& l) {
    EdgeConfig e;
    if (list_has(l, "from")) e.from = Rcpp::as<std::string>(l["from"]);
    if (list_has(l, "to")) e.to = Rcpp::as<std::string>(l["to"]);
    if (list_has(l, "is_conditional")) e.is_conditional = Rcpp::as<bool>(l["is_conditional"]);
    if (list_has(l, "route_field")) e.route_field = Rcpp::as<std::string>(l["route_field"]);
    if (list_has(l, "default_route")) e.default_route = Rcpp::as<std::string>(l["default_route"]);

    if (list_has(l, "route_map")) {
        Rcpp::List rm = l["route_map"];
        Rcpp::CharacterVector keys = rm.names();
        for (int i = 0; i < keys.size(); i++) {
            std::string key = Rcpp::as<std::string>(keys[i]);
            std::string val = Rcpp::as<std::string>(rm[i]);
            e.route_map[key] = val;
        }
    }

    return e;
}

GraphConfig graph_from_list(const Rcpp::List& l) {
    GraphConfig g;
    if (list_has(l, "entry_point")) g.entry_point = Rcpp::as<std::string>(l["entry_point"]);
    if (list_has(l, "max_iterations")) g.max_iterations = Rcpp::as<int>(l["max_iterations"]);

    if (list_has(l, "nodes")) {
        Rcpp::List nodes = l["nodes"];
        Rcpp::CharacterVector keys = nodes.names();
        for (int i = 0; i < keys.size(); i++) {
            std::string key = Rcpp::as<std::string>(keys[i]);
            Rcpp::List node_list = nodes[i];
            node_list["id"] = key;
            g.nodes[key] = node_from_list(node_list);
        }
    }

    if (list_has(l, "edges")) {
        Rcpp::List edges = l["edges"];
        for (int i = 0; i < edges.size(); i++) {
            g.edges.push_back(edge_from_list(edges[i]));
        }
    }

    return g;
}

Message message_from_list(const Rcpp::List& l) {
    Message m;
    if (list_has(l, "role")) {
        std::string role = Rcpp::as<std::string>(l["role"]);
        m.role = string_to_role(role);
    }
    if (list_has(l, "content")) {
        SEXP se = l["content"];
        if (TYPEOF(se) == STRSXP) {
            m.content = Rcpp::as<std::string>(se);
        } else if (TYPEOF(se) == VECSXP) {
            Rcpp::List parts = se;
            for (int i = 0; i < parts.size(); i++) {
                Rcpp::List pl = parts[i];
                ContentPart p;
                if (list_has(pl, "type")) p.type = Rcpp::as<std::string>(pl["type"]);
                if (list_has(pl, "text")) p.text = Rcpp::as<std::string>(pl["text"]);
                if (list_has(pl, "image_url")) {
                    Rcpp::List iu = pl["image_url"];
                    if (list_has(iu, "url")) p.image_url.url = Rcpp::as<std::string>(iu["url"]);
                    if (list_has(iu, "detail")) p.image_url.detail = Rcpp::as<std::string>(iu["detail"]);
                }
                if (list_has(pl, "video_url")) {
                    Rcpp::List vu = pl["video_url"];
                    if (list_has(vu, "url")) p.video_url.url = Rcpp::as<std::string>(vu["url"]);
                }
                if (list_has(pl, "input_audio")) {
                    Rcpp::List ia = pl["input_audio"];
                    if (list_has(ia, "data")) p.input_audio.data = Rcpp::as<std::string>(ia["data"]);
                    if (list_has(ia, "format")) p.input_audio.format = Rcpp::as<std::string>(ia["format"]);
                    if (list_has(ia, "file_id")) p.input_audio.file_id = Rcpp::as<std::string>(ia["file_id"]);
                }
                if (list_has(pl, "input_video")) {
                    Rcpp::List iv = pl["input_video"];
                    if (list_has(iv, "file_id")) p.input_video.file_id = Rcpp::as<std::string>(iv["file_id"]);
                }
                if (list_has(pl, "input_image")) {
                    Rcpp::List im = pl["input_image"];
                    if (list_has(im, "file_id")) p.input_image.file_id = Rcpp::as<std::string>(im["file_id"]);
                }
                // Flat file-id forms (Responses API) sit directly on the part.
                if (list_has(pl, "file_id")) {
                    std::string fid = Rcpp::as<std::string>(pl["file_id"]);
                    if (p.type == "input_video") {
                        p.input_video.file_id = fid;
                    } else if (p.type == "input_audio") {
                        p.input_audio.file_id = fid;
                    } else if (p.type == "input_image") {
                        p.input_image.file_id = fid;
                    }
                }
                m.parts.push_back(p);
            }
        }
    }
    if (list_has(l, "id")) m.id = Rcpp::as<std::string>(l["id"]);
    if (list_has(l, "name")) m.name = Rcpp::as<std::string>(l["name"]);
    if (list_has(l, "tool_call_id")) m.tool_call_id = Rcpp::as<std::string>(l["tool_call_id"]);

    if (list_has(l, "tool_calls")) {
        Rcpp::List tcs = l["tool_calls"];
        for (int i = 0; i < tcs.size(); i++) {
            Rcpp::List tc = tcs[i];
            ToolCall call;
            if (list_has(tc, "id")) call.id = Rcpp::as<std::string>(tc["id"]);
            if (list_has(tc, "name")) call.name = Rcpp::as<std::string>(tc["name"]);
            if (list_has(tc, "arguments")) {
                try {
                    Rcpp::CharacterVector av = tc["arguments"];
                    std::string a = Rcpp::as<std::string>(av[0]);
                    try {
                        call.arguments = json::parse(a);
                    } catch (...) {
                        call.arguments = json::object();
                    }
                } catch (...) {
                    call.arguments = json::object();
                }
            }
            m.tool_calls.push_back(call);
        }
    }
    return m;
}

std::vector<Message> messages_from_list(const Rcpp::List& l) {
    std::vector<Message> msgs;
    for (int i = 0; i < l.size(); i++) {
        msgs.push_back(message_from_list(l[i]));
    }
    return msgs;
}

Rcpp::List message_to_list(const Message& msg) {
    Rcpp::List l;
    l["role"] = role_to_string(msg.role);
    if (!msg.parts.empty()) {
        Rcpp::List parts;
        for (const auto& p : msg.parts) {
            Rcpp::List pl;
            pl["type"] = p.type;
            if (p.type == "text") {
                pl["text"] = p.text;
            } else if (p.type == "image_url") {
                Rcpp::List iu;
                iu["url"] = p.image_url.url;
                if (!p.image_url.detail.empty()) iu["detail"] = p.image_url.detail;
                pl["image_url"] = iu;
            } else if (p.type == "video_url") {
                Rcpp::List vu;
                vu["url"] = p.video_url.url;
                pl["video_url"] = vu;
            } else if (p.type == "input_audio") {
                if (!p.input_audio.file_id.empty()) {
                    pl["file_id"] = p.input_audio.file_id;   // flat file reference
                } else {
                    Rcpp::List ia;
                    ia["data"] = p.input_audio.data;
                    if (!p.input_audio.format.empty()) ia["format"] = p.input_audio.format;
                    pl["input_audio"] = ia;
                }
            } else if (p.type == "input_video") {
                pl["file_id"] = p.input_video.file_id;       // flat file reference
            } else if (p.type == "input_image") {
                pl["file_id"] = p.input_image.file_id;       // flat file reference
            }
            parts.push_back(pl);
        }
        l["content"] = parts;
    } else {
        l["content"] = msg.content;
    }
    if (!msg.id.empty()) l["id"] = msg.id;
    if (!msg.name.empty()) l["name"] = msg.name;
    if (!msg.tool_call_id.empty()) l["tool_call_id"] = msg.tool_call_id;
    if (!msg.tool_calls.empty()) {
        Rcpp::List tcs;
        for (const auto& tc : msg.tool_calls) {
            Rcpp::List tc_list;
            tc_list["id"] = tc.id;
            tc_list["name"] = tc.name;
            tc_list["arguments"] = tc.arguments.dump();
            tcs.push_back(tc_list);
        }
        l["tool_calls"] = tcs;
    }
    return l;
}

Rcpp::List state_to_list(const GraphState& state) {
    Rcpp::List result;

    auto data = state.get_all_data();
    Rcpp::List data_list;
    for (auto& [key, val] : data) {
        std::string json_str = val.dump();
        data_list[key] = Rcpp::wrap(Rcpp::CharacterVector(json_str));
    }
    result["data"] = data_list;

    auto messages = state.get_messages();
    Rcpp::List msg_list;
    for (size_t i = 0; i < messages.size(); i++) {
        msg_list.push_back(message_to_list(messages[i]));
    }
    result["messages"] = msg_list;

    return result;
}

Rcpp::List response_to_list(const LLMResponse& response) {
    Rcpp::List l;
    l["content"] = response.content;
    l["finish_reason"] = finish_reason_to_string(response.finish_reason);
    l["model"] = response.model;
    l["prompt_tokens"] = response.usage.prompt_tokens;
    l["completion_tokens"] = response.usage.completion_tokens;
    l["total_tokens"] = response.usage.total_tokens;

    if (!response.error_message.empty()) {
        l["error"] = response.error_message;
    }

    if (!response.tool_calls.empty()) {
        Rcpp::List tcs;
        for (auto& tc : response.tool_calls) {
            Rcpp::List tc_list;
            tc_list["id"] = tc.id;
            tc_list["name"] = tc.name;
            tc_list["arguments"] = tc.arguments.dump();
            tcs.push_back(tc_list);
        }
        l["tool_calls"] = tcs;
    }

    return l;
}

} // namespace agentgraph
