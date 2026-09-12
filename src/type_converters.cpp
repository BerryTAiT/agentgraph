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
    if (list_has(l, "content")) m.content = Rcpp::as<std::string>(l["content"]);
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
    l["content"] = msg.content;
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
