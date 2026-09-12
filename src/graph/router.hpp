#pragma once

#include "../core/config.hpp"
#include "../core/state.hpp"
#include <string>

namespace agentgraph {

class Router {
public:
    static std::string resolve_next(
        const std::vector<EdgeConfig>& edges,
        const GraphState& state)
    {
        for (auto& edge : edges) {
            if (!edge.is_conditional) {
                return edge.to;
            }

            if (!edge.route_field.empty()) {
                auto val = state.get(edge.route_field);
                if (!val.is_null()) {
                    std::string key = val.is_string() ? val.get<std::string>() : val.dump();
                    auto it = edge.route_map.find(key);
                    if (it != edge.route_map.end()) {
                        return it->second;
                    }
                }
                if (!edge.default_route.empty()) {
                    return edge.default_route;
                }
            }
        }
        return END_NODE;
    }
};

} // namespace agentgraph
