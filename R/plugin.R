# Plugin / extension system ---------------------------------------------------
#
# A generic registry that third-party packages populate from .onLoad() so their
# providers/tools become available without forking agentgraph. register_plugin()
# is the low-level hook; register_provider()/register_tool() + provider()/
# get_tool() are the concrete extension points.

.agentgraph_plugins <- new.env(parent = emptyenv())

.plugin_key <- function(kind, name) paste0(kind, "::", name)

.validate_plugin_id <- function(kind, name) {
  for (x in list(kind = kind, name = name)) {
    if (!is.character(x) || length(x) != 1L || is.na(x) || !nzchar(x) ||
        grepl("::", x, fixed = TRUE)) {
      stop("register_plugin(): `kind` and `name` must be single non-empty strings without '::'.")
    }
  }
  invisible(TRUE)
}

#' Register a plugin factory
#'
#' Registers a factory function under `kind` + `name` so it can be looked up
#' later with [call_plugin()] (or a concrete extension point like [provider()]).
#' Third-party packages call this from `.onLoad()`.
#'
#' @param kind Plugin kind (e.g. "provider", "tool")
#' @param name Plugin name
#' @param factory A function to invoke when the plugin is used
#' @param overwrite If TRUE, replace an existing plugin of the same kind+name
#' @return Invisibly the plugin key
#' @export
register_plugin <- function(kind, name, factory, overwrite = FALSE) {
  .validate_plugin_id(kind, name)
  if (!is.function(factory)) stop("register_plugin(): `factory` must be a function.")
  key <- .plugin_key(kind, name)
  if (exists(key, envir = .agentgraph_plugins, inherits = FALSE) && !isTRUE(overwrite)) {
    stop("register_plugin(): plugin '", key, "' is already registered.")
  }
  assign(key, factory, envir = .agentgraph_plugins)
  invisible(key)
}

#' Invoke a registered plugin factory
#'
#' @param kind Plugin kind
#' @param name Plugin name
#' @param ... Arguments passed to the factory
#' @return The factory's return value
#' @export
call_plugin <- function(kind, name, ...) {
  key <- .plugin_key(kind, name)
  f <- get0(key, envir = .agentgraph_plugins, inherits = FALSE)
  if (is.null(f)) stop("plugin not found: ", key)
  f(...)
}

#' Test whether a plugin is registered
#'
#' @param kind Plugin kind
#' @param name Plugin name
#' @return `TRUE`/`FALSE`
#' @export
has_plugin <- function(kind, name) {
  exists(.plugin_key(kind, name), envir = .agentgraph_plugins, inherits = FALSE)
}

#' List registered plugins
#'
#' @param kind Optional kind to filter by
#' @return A data.frame with columns `kind` and `name`
#' @export
list_plugins <- function(kind = NULL) {
  keys <- ls(.agentgraph_plugins, all.names = TRUE)
  if (length(keys) == 0L) {
    return(data.frame(kind = character(0), name = character(0)))
  }
  parts <- strsplit(keys, "::", fixed = TRUE)
  df <- data.frame(
    kind = vapply(parts, function(p) p[[1L]], character(1L)),
    name = vapply(parts, function(p) p[[2L]], character(1L)),
    stringsAsFactors = FALSE
  )
  if (!is.null(kind)) df <- df[df$kind == kind, , drop = FALSE]
  df[order(df$kind, df$name), , drop = FALSE]
}

#' Unregister a plugin
#'
#' @param kind Plugin kind
#' @param name Plugin name
#' @return `NULL`, invisibly
#' @export
unregister_plugin <- function(kind, name) {
  key <- .plugin_key(kind, name)
  if (exists(key, envir = .agentgraph_plugins, inherits = FALSE)) {
    rm(list = key, envir = .agentgraph_plugins)
  }
  invisible(NULL)
}

#' Register a provider constructor
#'
#' Convenience wrapper: registers a provider factory that [provider()] can
#' dispatch to. The factory must return a provider configuration list.
#'
#' @param name Provider name
#' @param factory A function(...) returning a provider configuration list
#' @return Invisibly the plugin key
#' @export
register_provider <- function(name, factory) {
  register_plugin("provider", name, factory)
}

#' Construct a registered provider
#'
#' Looks up a provider registered via [register_provider()] and calls its
#' factory with `...`.
#'
#' @param name Provider name
#' @param ... Arguments passed to the factory
#' @return A provider configuration list
#' @export
provider <- function(name, ...) {
  call_plugin("provider", name, ...)
}

#' Register a ready-made tool
#'
#' Convenience wrapper: registers a `tool()` object under a name, retrievable
#' with [get_tool()].
#'
#' @param name Tool name
#' @param tool A tool definition (from [tool()])
#' @return Invisibly the plugin key
#' @export
register_tool <- function(name, tool) {
  if (!is.list(tool) || is.null(tool$name) || is.null(tool$handler)) {
    stop("register_tool(): `tool` must be a tool definition from tool().")
  }
  register_plugin("tool", name, function() tool)
}

#' Get a registered tool
#'
#' @param name Tool name
#' @return The tool definition
#' @export
get_tool <- function(name) {
  call_plugin("tool", name)
}
