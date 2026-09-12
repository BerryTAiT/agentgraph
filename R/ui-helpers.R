#' Visualize a graph structure
#'
#' @param graph A graph object
#' @return A visualization (prints mermaid diagram)
#' @export
visualize <- function(graph) {
  lines <- character()
  lines <- c(lines, "graph TD")

  for (id in names(graph$nodes)) {
    node <- graph$nodes[[id]]
    label <- switch(node$type,
      llm = paste0(id, "[", id, "\\nLLM]"),
      tool = paste0(id, "[", id, "\\nTool]"),
      router = paste0(id, "{", id, "\\nRouter}"),
      paste0(id, "[", id, "]")
    )
    lines <- c(lines, paste0("    ", label))
  }

  lines <- c(lines, paste0("    __end__((END))"))

  for (edge in graph$edges) {
    if (edge$is_conditional) {
      rn <- names(edge$route_map)
      if (is.null(rn)) rn <- rep("", length(edge$route_map))
      for (i in seq_along(edge$route_map)) {
        to <- edge$route_map[[i]]
        lines <- c(lines, paste0("    ", edge$from, " -->|", rn[[i]], "| ", to))
      }
    } else {
      to <- if (edge$to == "__end__") "__end__" else edge$to
      lines <- c(lines, paste0("    ", edge$from, " --> ", to))
    }
  }

  cat(paste(lines, collapse = "\n"), "\n")
  invisible(lines)
}
