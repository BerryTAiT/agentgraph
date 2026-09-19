# SSE (Server-Sent Events) server --------------------------------------------
#
# start_sse_server() streams an agent's tokens to a browser as text/event-stream,
# so a web client can render the answer live. Runs in a separate R process
# (inst/tools/sse_server.R) — same subprocess/ready-file/randomPort pattern.

#' Serve an agent's tokens over Server-Sent Events
#'
#' Starts a background server that streams the agent's tokens as
#' `text/event-stream`. `POST /stream` (JSON body `{"input":"..."}`) and
#' `GET /stream?input=...` each emit one `data: <token>` event per token and a
#' final `data: [DONE]`. `GET /health` is open; when `auth_token` is set,
#' `/stream` requires an `Authorization: Bearer <token>` header. Stop it with
#' [sse_stop()].
#'
#' @param target An agent (from [chat_agent()], etc.) or a graph (from [state_graph()])
#' @param host Interface to bind (default "127.0.0.1"). Binding to a
#'   non-loopback interface requires `auth_token` (see `allow_unauthenticated`).
#' @param port Port to bind (0 = random free port)
#' @param auth_token Optional bearer token required for /stream
#' @param allow_unauthenticated Set to TRUE to serve on a non-loopback `host`
#'   without `auth_token`. Not recommended: anyone who can reach the port can
#'   run the agent (and spend your LLM budget).
#' @param name Optional name for the handle
#' @param timeout Seconds to wait for readiness
#' @return A server handle (class `agentgraph_sse_server`)
#' @export
start_sse_server <- function(target, host = "127.0.0.1", port = 0,
                             auth_token = NULL, allow_unauthenticated = FALSE,
                             name = "agent", timeout = 30) {
  if (!requireNamespace("httpuv", quietly = TRUE)) {
    stop("start_sse_server(): requires the 'httpuv' package.")
  }
  if (is_agent(target)) {
    if (!is.null(target$run_fn)) {
      stop("start_sse_server(): only graph-based agents or graphs can be served; router_agent() is not serializable.")
    }
    agent <- target
  } else if (is.list(target) && !is.null(target$entry_point) &&
             !is.null(target$nodes) && !is.null(target$edges)) {
    agent <- new_agent(graph = target, tools = list(), description = name)
  } else {
    stop("start_sse_server(): `target` must be an agent or a graph.")
  }
  auth_token <- if (is.null(auth_token)) "" else as.character(auth_token)[1L]
  .check_serve_auth(host, auth_token, allow_unauthenticated, "start_sse_server")

  agent_file <- tempfile(pattern = "agentgraph_sse_agent_", fileext = ".rds")
  ready_file <- tempfile(pattern = "agentgraph_sse_ready_", fileext = ".txt")
  out <- tempfile(pattern = "agentgraph_sse_out_")
  err <- tempfile(pattern = "agentgraph_sse_err_")
  saveRDS(agent, agent_file)

  script <- system.file("tools", "sse_server.R", package = "agentgraph")
  if (!nzchar(script)) {
    stop("agentgraph: sse_server.R missing from the installed package (reinstall agentgraph).")
  }
  rscript <- file.path(R.home("bin"),
                       if (.Platform$OS.type == "windows") "Rscript.exe" else "Rscript")
  proc <- processx::process$new(
    rscript, c(script, agent_file, auth_token, as.character(port), host, ready_file),
    stdout = out, stderr = err, cleanup = TRUE
  )
  deadline <- Sys.time() + timeout
  while (!file.exists(ready_file) && proc$is_alive() && Sys.time() < deadline) Sys.sleep(0.05)
  if (!file.exists(ready_file)) {
    err_text <- if (file.exists(err)) paste(readLines(err, warn = FALSE), collapse = "\n") else ""
    tryCatch(proc$kill(), error = function(e) NULL)
    stop("start_sse_server(): server failed to start\n", err_text)
  }
  actual_port <- suppressWarnings(as.integer(readLines(ready_file, warn = FALSE)[1L]))
  if (is.na(actual_port)) actual_port <- port
  structure(
    list(process = proc, host = host, port = actual_port,
         url = paste0("http://", host, ":", actual_port, "/"), name = name,
         files = c(agent_file, ready_file, out, err)),
    class = "agentgraph_sse_server"
  )
}

#' Stop an SSE server
#'
#' @param server A server handle from [start_sse_server()]
#' @return `NULL`, invisibly
#' @export
sse_stop <- function(server) {
  if (is.null(server)) return(invisible(NULL))
  tryCatch({
    if (server$process$is_alive()) server$process$kill()
  }, error = function(e) NULL)
  tryCatch(unlink(server$files), error = function(e) NULL)
  invisible(NULL)
}

#' Print an SSE server handle
#'
#' @param x A server handle from [start_sse_server()]
#' @param ... Unused
#' @return `x`, invisibly
#' @export
print.agentgraph_sse_server <- function(x, ...) {
  alive <- tryCatch(x$process$is_alive(), error = function(e) FALSE)
  cat(sprintf("agentgraph SSE server: %s (%s) [%s]\n",
              x$name, x$url, if (alive) "running" else "stopped"))
  invisible(x)
}
