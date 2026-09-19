# Graph visualization ---------------------------------------------------------
#
# graph_mermaid() renders a graph as Mermaid source; visualize() prints it (or
# writes a self-contained interactive HTML file); plot() prints it as a static
# diagram. No extra dependencies (Mermaid loads from a CDN in the HTML file).

#' Render a graph as Mermaid source
#'
#' Returns the Mermaid `graph TD` source for a graph, one line per element
#' (nodes, the END marker, and edges). Node shape encodes its type (LLM/tool in
#' brackets, router in braces); conditional edges are labeled with their route
#' values.
#'
#' @param graph A graph object (from [state_graph()])
#' @return A character vector of Mermaid source lines
#' @export
graph_mermaid <- function(graph) {
  if (!is.list(graph) || is.null(graph$nodes)) {
    stop("graph_mermaid(): `graph` must be a graph object from state_graph().")
  }
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
  lines <- c(lines, "    __end__((END))")

  for (edge in graph$edges) {
    if (isTRUE(edge$is_conditional)) {
      rn <- names(edge$route_map)
      if (is.null(rn)) rn <- rep("", length(edge$route_map))
      for (i in seq_along(edge$route_map)) {
        to <- edge$route_map[[i]]
        lines <- c(lines, paste0("    ", edge$from, " -->|", rn[[i]], "| ", to))
      }
    } else {
      to <- if (identical(edge$to, "__end__")) "__end__" else edge$to
      lines <- c(lines, paste0("    ", edge$from, " --> ", to))
    }
  }
  lines
}

#' Visualize a graph (print Mermaid or write an interactive HTML file)
#'
#' With no `file` argument, prints the Mermaid source of the graph (the static
#' form). With `file`, writes a self-contained HTML page that renders the graph
#' interactively in a browser (Mermaid.js loaded from a CDN); set `open = TRUE`
#' to open it immediately.
#'
#' @param graph A graph object
#' @param file Optional path to write an interactive HTML file
#' @param open If TRUE and `file` is set, open the file in a browser
#' @return Invisibly the Mermaid lines (no file) or `file`
#' @export
visualize <- function(graph, file = NULL, open = FALSE) {
  lines <- graph_mermaid(graph)
  if (is.null(file)) {
    cat(paste(lines, collapse = "\n"), "\n")
    return(invisible(lines))
  }
  if (!is.character(file) || length(file) != 1L || is.na(file) || !nzchar(file)) {
    stop("visualize(): `file` must be a single non-empty path or NULL.")
  }
  html <- paste0(
    "<!DOCTYPE html>\n<html>\n<head>\n",
    "<meta charset=\"utf-8\">\n<title>agentgraph</title>\n",
    "<script src=\"https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.min.js\"></script>\n",
    "<script>mermaid.initialize({startOnLoad:true});</script>\n",
    "<style>body{font-family:sans-serif;margin:2rem;} .mermaid{max-width:100%;}</style>\n",
    "</head>\n<body>\n<h2>agentgraph</h2>\n<div class=\"mermaid\">\n",
    paste(lines, collapse = "\n"),
    "\n</div>\n</body>\n</html>\n"
  )
  writeLines(html, file)
  if (isTRUE(open)) utils::browseURL(file)
  invisible(file)
}

#' Plot a graph as a static Mermaid diagram
#'
#' Prints the graph's Mermaid source (see [graph_mermaid()]); use
#' [visualize()] with a `file` for the interactive HTML form.
#'
#' @param x A graph object
#' @param ... Unused
#' @return `x`, invisibly
#' @export
plot.agentgraph <- function(x, ...) {
  cat(paste(graph_mermaid(x), collapse = "\n"), "\n")
  invisible(x)
}
