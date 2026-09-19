# REST API wrapper -----------------------------------------------------------
#
# `serve_agent()` exposes an agent (or graph) over a minimal JSON REST API so it
# can be called from any HTTP client in production:
#
#   GET  /health   -> {"status":"ok"}                          (open)
#   POST /run      -> {"input":"..."} -> {"answer","state"}    (auth)
#   POST /stream   -> {"input":"..."} -> {"answer","tokens"}   (auth)
#
# The server runs in a separate R process (inst/tools/serve_agent.R via
# processx) so a blocking client in the same R session never deadlocks httpuv.
# Same subprocess/ready-file/randomPort pattern as a2a_server().
# Internal: TRUE when `host` is a loopback-only interface.
.is_loopback_host <- function(host) {
  tolower(as.character(host)[1L]) %in% c("127.0.0.1", "localhost", "::1")
}

# Internal: enforce that serving an agent on a non-loopback interface always
# requires a bearer token, unless the caller explicitly opts out. Serving an
# agent without auth on a routable address turns it into an open proxy for
# LLM spend and tool execution.
.check_serve_auth <- function(host, auth_token, allow_unauthenticated, fn) {
  if (.is_loopback_host(host)) return(invisible(TRUE))
  if (!is.null(auth_token) && nzchar(auth_token)) return(invisible(TRUE))
  if (isTRUE(allow_unauthenticated)) {
    warning(fn, "(): serving WITHOUT authentication on non-loopback host '",
            host, "' — anyone who can reach this port can run the agent.",
            call. = FALSE, immediate. = TRUE)
    return(invisible(TRUE))
  }
  stop(fn, "(): refusing to bind to '", host, "' without an `auth_token`. ",
       "Set `auth_token` (recommended, and put the server behind TLS), or pass ",
       "`allow_unauthenticated = TRUE` if you really mean it.", call. = FALSE)
}


#' Serve an agent or graph over a REST API
#'
#' Starts a background server (a separate R process) exposing `target` via a
#' minimal JSON REST API: `GET /health`, `POST /run` (returns `answer` +
#' `state`), and `POST /stream` (returns `answer` + the token sequence captured
#' via `on_token`). Requests send a JSON body `{"input": "..."}`. When
#' `auth_token` is set, `/run` and `/stream` require an
#' `Authorization: Bearer <token>` header (health stays open). Stop the server
#' with [serve_stop()].
#'
#' Only graph-based agents and graphs can be served (they serialize to the
#' server process); a `router_agent()` carries an R closure and is rejected.
#'
#' @param target An agent (from [chat_agent()], [react_agent()], ...) or a graph
#'   (from [state_graph()])
#' @param host Interface to bind (default "127.0.0.1"). Binding to a
#'   non-loopback interface requires `auth_token` (see `allow_unauthenticated`).
#' @param auth_token Optional bearer token required for /run and /stream
#' @param allow_unauthenticated Set to TRUE to serve on a non-loopback `host`
#'   without `auth_token`. Not recommended: anyone who can reach the port can
#'   run the agent (and spend your LLM budget). Put the server behind TLS and
#'   a reverse proxy in production.
#' @param name Optional name reported in the handle
#' @param timeout Seconds to wait for the server to report readiness
#' @return A server handle (class `agentgraph_serve`)
#' @export
serve_agent <- function(target, host = "127.0.0.1", auth_token = NULL,
                        allow_unauthenticated = FALSE, name = "agent",
                        timeout = 30) {
  if (!requireNamespace("httpuv", quietly = TRUE)) {
    stop("serve_agent(): requires the 'httpuv' package.")
  }
  if (is_agent(target)) {
    if (!is.null(target$run_fn)) {
      stop("serve_agent(): only graph-based agents or graphs can be served; router_agent() is not serializable.")
    }
    agent <- target
  } else if (is.list(target) && !is.null(target$entry_point) &&
             !is.null(target$nodes) && !is.null(target$edges)) {
    agent <- new_agent(graph = target, tools = list(), description = name)
  } else {
    stop("serve_agent(): `target` must be an agent or a graph (from state_graph()).")
  }
  if (!is.null(auth_token) &&
      (!is.character(auth_token) || length(auth_token) != 1L || is.na(auth_token))) {
    stop("serve_agent(): `auth_token` must be a single string or NULL.")
  }
  auth_token <- if (is.null(auth_token)) "" else auth_token
  .check_serve_auth(host, auth_token, allow_unauthenticated, "serve_agent")

  agent_file <- tempfile(pattern = "agentgraph_serve_agent_", fileext = ".rds")
  ready_file <- tempfile(pattern = "agentgraph_serve_ready_", fileext = ".txt")
  stdout_file <- tempfile(pattern = "agentgraph_serve_out_")
  stderr_file <- tempfile(pattern = "agentgraph_serve_err_")
  saveRDS(agent, agent_file)

  script <- system.file("tools", "serve_agent.R", package = "agentgraph")
  if (!nzchar(script)) {
    stop("agentgraph: serve_agent.R missing from the installed package (reinstall agentgraph).")
  }
  rscript <- file.path(
    R.home("bin"),
    if (.Platform$OS.type == "windows") "Rscript.exe" else "Rscript"
  )

  proc <- processx::process$new(
    rscript,
    c(script, agent_file, auth_token, host, ready_file),
    stdout = stdout_file, stderr = stderr_file, cleanup = TRUE
  )

  deadline <- Sys.time() + timeout
  while (!file.exists(ready_file) && proc$is_alive() && Sys.time() < deadline) {
    Sys.sleep(0.05)
  }
  if (!file.exists(ready_file)) {
    err_text <- if (file.exists(stderr_file)) {
      paste(readLines(stderr_file, warn = FALSE), collapse = "\n")
    } else ""
    tryCatch(proc$kill(), error = function(e) NULL)
    stop("serve_agent(): server failed to start\n", err_text)
  }

  port <- suppressWarnings(as.integer(readLines(ready_file, warn = FALSE)[1L]))
  if (is.na(port)) {
    tryCatch(proc$kill(), error = function(e) NULL)
    stop("serve_agent(): server reported an invalid port.")
  }

  url <- paste0("http://", host, ":", port, "/")
  structure(
    list(process = proc, host = host, port = port, url = url, name = name,
         files = c(agent_file, ready_file, stdout_file, stderr_file)),
    class = "agentgraph_serve"
  )
}

#' Stop a REST server
#'
#' @param server A server handle from [serve_agent()]
#' @return `NULL`, invisibly
#' @export
serve_stop <- function(server) {
  if (is.null(server)) return(invisible(NULL))
  tryCatch({
    if (server$process$is_alive()) server$process$kill()
  }, error = function(e) NULL)
  tryCatch(unlink(server$files), error = function(e) NULL)
  invisible(NULL)
}

#' Print a REST server handle
#'
#' @param x A server handle from [serve_agent()]
#' @param ... Unused
#' @return `x`, invisibly
#' @export
print.agentgraph_serve <- function(x, ...) {
  alive <- tryCatch(x$process$is_alive(), error = function(e) FALSE)
  cat(sprintf("agentgraph REST server: %s (%s) [%s]\n",
              x$name, x$url, if (alive) "running" else "stopped"))
  invisible(x)
}
