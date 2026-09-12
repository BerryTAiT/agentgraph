#pragma once

#include "../core/types.hpp"
#include "../core/errors.hpp"
#include <string>
#include <functional>
#include <unordered_map>

namespace agentgraph {

using ToolHandler = std::function<Result<json>(const json& arguments)>;

struct Tool {
    ToolSchema schema;
    ToolHandler handler;
};

class ToolRegistry {
public:
    void register_tool(const std::string& name,
                       const std::string& description,
                       const json& parameters,
                       ToolHandler handler) {
        Tool t;
        t.schema.name = name;
        t.schema.description = description;
        t.schema.parameters = parameters;
        t.handler = std::move(handler);
        tools_[name] = std::move(t);
    }

    bool has(const std::string& name) const {
        return tools_.find(name) != tools_.end();
    }

    Result<json> execute(const std::string& name, const json& arguments) const {
        auto it = tools_.find(name);
        if (it == tools_.end()) {
            return Result<json>::err("Tool not found: " + name);
        }
        return it->second.handler(arguments);
    }

    std::vector<ToolSchema> get_schemas(const std::vector<std::string>& names) const {
        std::vector<ToolSchema> schemas;
        for (auto& name : names) {
            auto it = tools_.find(name);
            if (it != tools_.end()) {
                schemas.push_back(it->second.schema);
            }
        }
        return schemas;
    }

    std::vector<ToolSchema> all_schemas() const {
        std::vector<ToolSchema> schemas;
        for (auto& [name, tool] : tools_) {
            schemas.push_back(tool.schema);
        }
        return schemas;
    }

private:
    std::unordered_map<std::string, Tool> tools_;
};

} // namespace agentgraph
