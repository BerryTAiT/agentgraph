# Tool-call validation (path / domain policy) --------------------------------
#
# A tool policy restricts what a tool may touch (filesystem paths, URL hosts)
# before the handler executes. `tool_policy()` builds the rules; `restrict_tool()`
# wraps a tool so its handler validates the incoming arguments first; and
# `validate_tool_args()` exposes the same check standalone. The wrapper is
# fully self-contained (base R only) so it serializes into agentgraph's
# tool-server process unchanged (the same pattern as guarded_tool()).

#' Create a tool-call policy
#'
#' A policy constrains the values a tool may receive for filesystem paths and
#' URLs. When `path_allow` is non-empty, a path argument must resolve under one
#' of the allowed prefixes; when `path_deny` is non-empty, it must not resolve
#' under any denied prefix. Likewise `domain_allow` / `domain_deny` restrict the
#' host of URL arguments (subdomains of an allowed domain are allowed).
#'
#' @param path_allow Character vector of allowed path prefixes
#' @param path_deny Character vector of denied path prefixes
#' @param domain_allow Character vector of allowed domains (host names)
#' @param domain_deny Character vector of denied domains
#' @param path_args Argument names treated as filesystem paths
#' @param url_args Argument names treated as URLs
#' @return A policy object (class `agentgraph_tool_policy`)
#' @export
tool_policy <- function(path_allow = character(), path_deny = character(),
                        domain_allow = character(), domain_deny = character(),
                        path_args = c("path", "file", "db", "db_path",
                                      "input_file", "output_file", "dir",
                                      "directory"),
                        url_args = c("url", "endpoint", "base_url", "api_url")) {
  structure(
    list(
      path_allow = as.character(path_allow),
      path_deny = as.character(path_deny),
      domain_allow = tolower(as.character(domain_allow)),
      domain_deny = tolower(as.character(domain_deny)),
      path_args = as.character(path_args),
      url_args = as.character(url_args)
    ),
    class = "agentgraph_tool_policy"
  )
}

# --- helpers (used by the standalone validate_tool_args) --------------------

.norm_path <- function(p) {
  p <- normalizePath(p, winslash = "/", mustWork = FALSE)
  if (.Platform$OS.type == "windows") tolower(p) else p
}

.path_within <- function(path, prefix) {
  prefix <- sub("/+$", "", prefix)
  identical(path, prefix) || startsWith(path, paste0(prefix, "/"))
}

.url_host <- function(url) {
  u <- sub("^[a-zA-Z][a-zA-Z0-9+.-]*://", "", url)
  u <- strsplit(u, "/", fixed = TRUE)[[1L]][1L]
  if (grepl("@", u, fixed = TRUE)) u <- sub("^.*@", "", u)
  u <- sub(":.*$", "", u)  # strip port
  tolower(u)
}

.domain_match <- function(host, domain) {
  identical(host, domain) || endsWith(host, paste0(".", domain))
}

#' Validate tool arguments against a policy
#'
#' Checks the string values of a tool's arguments against a [tool_policy()]:
#' arguments whose name is in `path_args` are checked against the path
#' allow/deny rules and arguments whose name is in `url_args` against the
#' domain rules. Stops with an error on the first violation; returns
#' `invisibly(TRUE)` when all checks pass.
#'
#' @param args A named list of arguments, or a JSON string
#' @param policy A [tool_policy()]
#' @return Invisibly `TRUE`
#' @export
validate_tool_args <- function(args, policy) {
  if (!inherits(policy, "agentgraph_tool_policy")) {
    stop("validate_tool_args(): `policy` must be a tool_policy().")
  }
  if (is.character(args) && length(args) == 1L) {
    args <- tryCatch(jsonlite::fromJSON(args, simplifyVector = FALSE),
                     error = function(e) args)
  }
  if (!is.list(args)) {
    stop("validate_tool_args(): `args` must be a named list or a JSON string.")
  }

  for (nm in names(args)) {
    v <- args[[nm]]
    if (!is.character(v) || length(v) != 1L || is.na(v)) next

    if (nm %in% policy$path_args &&
        (length(policy$path_allow) || length(policy$path_deny))) {
      np <- .norm_path(v)
      if (length(policy$path_allow) &&
          !any(vapply(policy$path_allow,
                      function(pr) .path_within(np, .norm_path(pr)), logical(1L)))) {
        stop("tool policy: path '", v, "' is not within an allowed path", call. = FALSE)
      }
      if (length(policy$path_deny) &&
          any(vapply(policy$path_deny,
                     function(pr) .path_within(np, .norm_path(pr)), logical(1L)))) {
        stop("tool policy: path '", v, "' is denied", call. = FALSE)
      }
    }

    if (nm %in% policy$url_args &&
        (length(policy$domain_allow) || length(policy$domain_deny))) {
      host <- .url_host(v)
      if (length(policy$domain_allow) &&
          !any(vapply(policy$domain_allow,
                      function(d) .domain_match(host, d), logical(1L)))) {
        stop("tool policy: domain '", host, "' is not allowed", call. = FALSE)
      }
      if (length(policy$domain_deny) &&
          any(vapply(policy$domain_deny,
                     function(d) .domain_match(host, d), logical(1L)))) {
        stop("tool policy: domain '", host, "' is denied", call. = FALSE)
      }
    }
  }
  invisible(TRUE)
}

#' Wrap a tool so its calls are validated against a policy
#'
#' Returns a copy of `tool` whose handler first validates the incoming
#' arguments with [validate_tool_args()] and only then invokes the original
#' handler. A violating call raises an error, which the engine surfaces to the
#' LLM as a failed tool result. The wrapper is self-contained (base R only), so
#' it serializes into the tool-server process unchanged. Composable with
#' [guarded_tool()] (apply validation and output sanitization together).
#'
#' @param tool A tool definition from [tool()]
#' @param policy A [tool_policy()]
#' @return A new tool definition with a validating handler
#' @export
restrict_tool <- function(tool, policy) {
  if (!is.list(tool) || is.null(tool$name) || is.null(tool$handler)) {
    stop("restrict_tool(): `tool` must be a tool definition from tool().")
  }
  if (!inherits(policy, "agentgraph_tool_policy")) {
    stop("restrict_tool(): `policy` must be a tool_policy().")
  }
  orig <- tool$handler
  p <- unclass(policy)

  make_handler <- function(orig, p) {
    force(orig); force(p)
    function(args_json) {
      args <- tryCatch(jsonlite::fromJSON(args_json, simplifyVector = FALSE),
                       error = function(e) list())
      for (nm in names(args)) {
        v <- args[[nm]]
        if (!is.character(v) || length(v) != 1L || is.na(v)) next

        if (nm %in% p$path_args && (length(p$path_allow) || length(p$path_deny))) {
          np <- normalizePath(v, winslash = "/", mustWork = FALSE)
          if (.Platform$OS.type == "windows") np <- tolower(np)
          if (length(p$path_allow)) {
            ok <- FALSE
            for (pr in p$path_allow) {
              prn <- normalizePath(pr, winslash = "/", mustWork = FALSE)
              if (.Platform$OS.type == "windows") prn <- tolower(prn)
              prn <- sub("/+$", "", prn)
              if (identical(np, prn) || startsWith(np, paste0(prn, "/"))) {
                ok <- TRUE; break
              }
            }
            if (!ok) stop("tool policy: path '", v, "' is not within an allowed path", call. = FALSE)
          }
          if (length(p$path_deny)) {
            for (pr in p$path_deny) {
              prn <- normalizePath(pr, winslash = "/", mustWork = FALSE)
              if (.Platform$OS.type == "windows") prn <- tolower(prn)
              prn <- sub("/+$", "", prn)
              if (identical(np, prn) || startsWith(np, paste0(prn, "/"))) {
                stop("tool policy: path '", v, "' is denied", call. = FALSE)
              }
            }
          }
        }

        if (nm %in% p$url_args && (length(p$domain_allow) || length(p$domain_deny))) {
          host <- sub("^[a-zA-Z][a-zA-Z0-9+.-]*://", "", v)
          host <- strsplit(host, "/", fixed = TRUE)[[1L]][1L]
          if (grepl("@", host, fixed = TRUE)) host <- sub("^.*@", "", host)
          host <- sub(":.*$", "", host)
          host <- tolower(host)
          if (length(p$domain_allow)) {
            ok <- FALSE
            for (d in p$domain_allow) {
              if (identical(host, d) || endsWith(host, paste0(".", d))) { ok <- TRUE; break }
            }
            if (!ok) stop("tool policy: domain '", host, "' is not allowed", call. = FALSE)
          }
          if (length(p$domain_deny)) {
            for (d in p$domain_deny) {
              if (identical(host, d) || endsWith(host, paste0(".", d))) {
                stop("tool policy: domain '", host, "' is denied", call. = FALSE)
              }
            }
          }
        }
      }
      orig(args_json)
    }
  }

  tool$handler <- make_handler(orig, p)
  tool
}

#' Sandbox the native built-in file tools
#'
#' Sets the process-level filesystem policy enforced by the C++ engine for the
#' native `read_file` and `write_file` tools. Because those tools execute
#' in-process, the R-side [restrict_tool()] wrapper cannot intercept them; this
#' helper is the equivalent for the native tools. When `allow` is non-empty,
#' every path the LLM passes to a file tool must resolve under one of those
#' directories; paths under `deny` are always rejected. Paths are canonicalized
#' in C++ (resolving `..` and symlinks) before the check, so directory-traversal
#' escapes are blocked.
#'
#' The policy is process-wide and applies from the first time the native tools
#' are used after the environment is set (call it at session start, before any
#' [run()]). Pass empty vectors to both arguments to clear the policy (only
#' effective if called before the first file-tool use in the process).
#'
#' @param allow Character vector of directories file tools may access
#'   (recursively). Empty means no allow-list.
#' @param deny Character vector of directories file tools must never access.
#' @return Invisibly `TRUE`
#' @export
#' @examples
#' \dontrun{
#' # Allow file tools only under the project data directory
#' file_tools_policy(allow = file.path(getwd(), "data"))
#' }
file_tools_policy <- function(allow = character(), deny = character()) {
  # ';' is the separator, so it cannot appear inside a rule path.
  for (p in c(allow, deny)) {
    if (grepl(";", p, fixed = TRUE)) {
      stop("file_tools_policy(): paths may not contain ';'.")
    }
  }
  set_var <- function(name, paths) {
    if (length(paths)) {
      norm <- vapply(paths, function(p) {
        normalizePath(p, winslash = "/", mustWork = FALSE)
      }, character(1L))
      Sys.setenv(structure(paste(norm, collapse = ";"), names = name))
    } else {
      Sys.unsetenv(name)
    }
  }
  set_var("AGENTGRAPH_FS_ALLOW", allow)
  set_var("AGENTGRAPH_FS_DENY", deny)
  invisible(TRUE)
}

#' Print a tool policy
#'
#' @param x A policy from [tool_policy()]
#' @param ... Unused
#' @return `x`, invisibly
#' @export
print.agentgraph_tool_policy <- function(x, ...) {
  cat("agentgraph tool policy\n")
  if (length(x$path_allow)) cat("  path_allow:", paste(x$path_allow, collapse = ", "), "\n")
  if (length(x$path_deny)) cat("  path_deny:", paste(x$path_deny, collapse = ", "), "\n")
  if (length(x$domain_allow)) cat("  domain_allow:", paste(x$domain_allow, collapse = ", "), "\n")
  if (length(x$domain_deny)) cat("  domain_deny:", paste(x$domain_deny, collapse = ", "), "\n")
  invisible(x)
}
