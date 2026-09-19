#' Create a new state graph
#'
#' @param entry The entry point node ID
#' @param max_iterations Maximum number of iterations before stopping
#' @return A graph object
#' @export
state_graph <- function(entry, max_iterations = 25L) {
  if (!is.character(entry) || length(entry) != 1L || is.na(entry) || !nzchar(entry)) {
    stop("state_graph(): `entry` must be a single non-empty character string (a node ID).")
  }
  if (!is.numeric(max_iterations) || length(max_iterations) != 1L || is.na(max_iterations) ||
      max_iterations < 1) {
    stop("state_graph(): `max_iterations` must be a number >= 1.")
  }
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
  if (!is.character(id) || length(id) != 1L || is.na(id) || !nzchar(id)) {
    stop("add_node(): `id` must be a single non-empty character string.")
  }
  if (!is.list(node) || is.null(node$type)) {
    stop("add_node(): `node` must be a node configuration from llm_node(), tool_node(), router_node(), subgraph_node(), interrupt_node(), or parallel_node().")
  }
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
  if (!is.character(field) || length(field) != 1L || is.na(field) || !nzchar(field)) {
    stop("route_on(): `field` must be a single non-empty character string (a state field).")
  }
  list(field = field, rules = rules, default = default)
}
