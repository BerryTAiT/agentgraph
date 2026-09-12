#pragma once

#include <Rcpp.h>
#include "core/types.hpp"
#include "core/config.hpp"
#include "core/state.hpp"
#include "tools/tool.hpp"

namespace agentgraph {

ProviderConfig provider_from_list(const Rcpp::List& l);
NodeConfig node_from_list(const Rcpp::List& l);
EdgeConfig edge_from_list(const Rcpp::List& l);
GraphConfig graph_from_list(const Rcpp::List& l);
std::vector<Message> messages_from_list(const Rcpp::List& l);
Message message_from_list(const Rcpp::List& l);
ToolSchema tool_schema_from_list(const Rcpp::List& l);

Rcpp::List state_to_list(const GraphState& state);
Rcpp::List response_to_list(const LLMResponse& response);
Rcpp::List message_to_list(const Message& msg);

} // namespace agentgraph
