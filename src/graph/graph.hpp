#pragma once

#include "../core/config.hpp"
#include "../core/errors.hpp"
#include <string>
#include <vector>
#include <unordered_map>
#include <unordered_set>

namespace agentgraph {

class Graph {
public:
    explicit Graph(const GraphConfig& config) : config_(config) {}

    Result<void> validate() const {
        if (config_.entry_point.empty()) {
            return Result<void>::err("Graph has no entry point");
        }
        if (config_.nodes.find(config_.entry_point) == config_.nodes.end()) {
            return Result<void>::err("Entry point '" + config_.entry_point + "' not found in nodes");
        }

        for (auto& [id, node] : config_.nodes) {
            if (id == END_NODE) {
                return Result<void>::err("Node cannot be named '" + std::string(END_NODE) + "'");
            }
            if (node.type == NodeType::Parallel) {
                if (node.sub_node_ids.empty()) {
                    return Result<void>::err("Parallel node '" + id + "' has no sub-nodes");
                }
                for (auto& sub : node.sub_node_ids) {
                    if (config_.nodes.find(sub) == config_.nodes.end()) {
                        return Result<void>::err(
                            "Parallel node '" + id + "' references missing sub-node '" + sub + "'");
                    }
                }
            }
            if (node.type == NodeType::Subgraph) {
                if (!node.sub_graph) {
                    return Result<void>::err("Subgraph node '" + id + "' has no nested graph");
                }
            }
        }

        for (auto& edge : config_.edges) {
            if (config_.nodes.find(edge.from) == config_.nodes.end()) {
                return Result<void>::err("Edge source '" + edge.from + "' not found in nodes");
            }
            if (!edge.is_conditional && edge.to != END_NODE &&
                config_.nodes.find(edge.to) == config_.nodes.end()) {
                return Result<void>::err("Edge target '" + edge.to + "' not found in nodes");
            }
            if (edge.is_conditional) {
                for (auto& [val, target] : edge.route_map) {
                    if (target != END_NODE && config_.nodes.find(target) == config_.nodes.end()) {
                        return Result<void>::err("Conditional route target '" + target + "' not found");
                    }
                }
            }
        }

        return Result<void>::ok();
    }

    std::vector<EdgeConfig> get_edges_from(const std::string& node_id) const {
        std::vector<EdgeConfig> result;
        for (auto& edge : config_.edges) {
            if (edge.from == node_id) {
                result.push_back(edge);
            }
        }
        return result;
    }

    const NodeConfig& get_node(const std::string& node_id) const {
        return config_.nodes.at(node_id);
    }

    const GraphConfig& config() const { return config_; }
    const std::string& entry_point() const { return config_.entry_point; }

private:
    GraphConfig config_;
};

} // namespace agentgraph
