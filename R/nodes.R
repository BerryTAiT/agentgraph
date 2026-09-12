#' Create an LLM node
#'
#' @param provider A provider configuration (from provider_openai(), etc.)
#' @param system_prompt System prompt for the LLM
#' @param tools Character vector of tool names this node can use
#' @return A node configuration list
#' @export
llm_node <- function(provider,
                     system_prompt = "",
                     tools = character(0)) {
  list(
    type = "llm",
    provider = provider,
    system_prompt = system_prompt,
    tool_names = tools
  )
}

#' Create a tool execution node
#'
#' @return A node configuration list
#' @export
tool_node <- function() {
  list(type = "tool")
}

#' Create a router node
#'
#' @param route_field State field to check for routing
#' @param rules Named list mapping field values to node IDs
#' @param default_route Default node if no rule matches
#' @return A node configuration list
#' @export
router_node <- function(route_field = "next_action",
                        rules = list(),
                        default_route = "__end__") {
  list(
    type = "router",
    route_field = route_field,
    rules = rules,
    default_route = default_route
  )
}

#' Create a subgraph node
#'
#' Embeds an entire graph as a single node. When the executor reaches this
#' node it runs the nested graph to completion (sharing the parent state),
#' then continues along this node's outgoing edge. Subgraphs let you compose
#' reusable multi-step agents into a larger workflow.
#'
#' @param graph A graph object (from state_graph(), populated with nodes/edges)
#' @return A node configuration list
#' @export
subgraph_node <- function(graph) {
  if (is.null(graph$entry_point) || is.null(graph$nodes)) {
    stop("subgraph_node(): `graph` must be a graph object created with state_graph().")
  }
  list(
    type = "subgraph",
    sub_graph = list(
      entry_point = graph$entry_point,
      nodes = graph$nodes,
      edges = graph$edges,
      max_iterations = graph$max_iterations
    )
  )
}

#' Create an interrupt (human-in-the-loop) node
#'
#' When the executor reaches this node it pauses the graph and returns the
#' current state to R, recording where to continue. Inspect or modify the
#' returned state, then call \code{resume()} to continue execution from the
#' interrupt node's outgoing edge. This is the primitive for human approval,
#' manual review, or external side-effects mid-graph.
#'
#' @return A node configuration list
#' @export
interrupt_node <- function() {
  list(type = "interrupt")
}

#' Create a parallel fan-out node
#'
#' Runs the given child nodes concurrently on the C++ thread pool, waits for
#' all of them to finish, then continues to its own outgoing edge. Each child
#' node must already be registered on the graph (via add_node) but is not
#' reached through edges; the parallel node executes them directly.
#'
#' @param node_ids Character vector of child node IDs to run in parallel
#' @return A node configuration list
#' @export
parallel_node <- function(node_ids) {
  list(
    type = "parallel",
    sub_node_ids = node_ids
  )
}
