#' Create a new state graph
#'
#' @param entry The entry point node ID
#' @param max_iterations Maximum number of iterations before stopping
#' @return A graph object
#' @export
state_graph <- function(entry, max_iterations = 25L) {
  obj <- list(
    entry_point = entry,
    nodes = list(),
    edges = list(),
    max_iterations = as.integer(max_iterations)
  )
  class(obj) <- "agentgraph"
  obj
}

#' Add a node to the graph
#'
#' @param graph A graph object
#' @param id Node ID
#' @param node A node configuration (from llm_node(), tool_node(), etc.)
#' @return The modified graph object
#' @export
add_node <- function(graph, id, node) {
  graph$nodes[[id]] <- node
  graph
}

#' Add an edge to the graph
#'
#' @param graph A graph object
#' @param from Source node ID
#' @param to Target node ID (or "__end__")
#' @return The modified graph object
#' @export
add_edge <- function(graph, from, to) {
  graph$edges <- c(graph$edges, list(list(
    from = from,
    to = to,
    is_conditional = FALSE
  )))
  graph
}

#' Add a conditional edge to the graph
#'
#' @param graph A graph object
#' @param from Source node ID
#' @param route A routing configuration (from route_on())
#' @return The modified graph object
#' @export
add_conditional_edge <- function(graph, from, route) {
  graph$edges <- c(graph$edges, list(list(
    from = from,
    to = "",
    is_conditional = TRUE,
    route_field = route$field,
    route_map = route$rules,
    default_route = route$default
  )))
  graph
}

#' Create a routing configuration
#'
#' @param field State field to check
#' @param rules Named list mapping values to node IDs
#' @param default Default node if no rule matches
#' @return A routing configuration
#' @export
route_on <- function(field, rules = list(), default = "__end__") {
  list(field = field, rules = rules, default = default)
}
