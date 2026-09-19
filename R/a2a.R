# A2A (agent-to-agent) protocol ------------------------------------------------
#
# Expose an agentgraph agent over HTTP so other agents (or any JSON-RPC 2.0
# client) can call it, and call remote agents the same way. A minimal
# Agent-to-Agent (A2A) implementation:
#
#   GET  /.well-known/agent.json   -> the agent card
#   POST /                         -> JSON-RPC 2.0 "tasks/send" | "message/send"
#
# The server runs in a separate R process (inst/tools/a2a_server.R, via
# processx) so a blocking client in the same R session never deadlocks with
# httpuv. The client uses curl. Only graph-based agents (chat / react /
# plan-execute / reflection) can be served; router_agent() carries an R
# closure that does not survive serialization to the subprocess.

# Internal: normalize a user-supplied URL into the server's base URL.
.base_url <- function(url) {
  if (!is.character(url) || length(url) != 1L || is.na(url) || !nzchar(url)) {
    stop("A2A URL must be a single non-empty string.")
  }
  url <- sub("/+$", "", url)
  url <- sub("/\\.well-known/agent\\.json$", "", url)
  url <- sub("/agent-card\\.json$", "", url)
  if (!nzchar(url)) stop("A2A URL is empty.")
  url
}

.card_endpoint <- function(url) paste0(.base_url(url), "/.well-known/agent.json")

.rpc_id <- function() {
  paste0("req-", Sys.getpid(), "-", as.integer(Sys.time()),
         "-", sample.int(1e6, 1L))
}

# Build an A2A message (role + parts) from a string or an existing message.
.to_a2a_message <- function(message) {
  if (is.list(message) && !is.null(message$role) && !is.null(message$parts)) {
    return(message)
  }
  if (is.character(message) && length(message) == 1L && !is.na(message)) {
    return(list(role = "user",
                parts = list(list(type = "text", text = message))))
  }
  stop("a2a_send(): `message` must be a single string or an A2A message list.")
}

.task_answer <- function(result) {
  parts <- NULL
  if (!is.null(result$artifacts)) {
    parts <- unlist(lapply(result$artifacts, function(a) a$parts), recursive = FALSE)
  } else if (!is.null(result$parts)) {
    parts <- result$parts
  }
  if (is.null(parts)) return("")
  paste(vapply(parts, function(p) {
    if (!is.null(p$text) && is.character(p$text)) p$text
    else if (!is.null(p$data) && !is.null(p$data$text)) p$data$text
    else ""
  }, character(1L)), collapse = "\n")
}

#' Build an agent card
#'
#' An agent card is the JSON metadata an A2A server advertises: the agent's
#' name, description, endpoint, protocol version, capabilities, and skills.
#' Pass it to [a2a_server()] or inspect it standalone.
#'
#' @param name Agent name
#' @param description Human-readable description
#' @param url Endpoint URL (filled in automatically by [a2a_server()])
#' @param version Agent version
#' @param protocol_version A2A protocol version
#' @param skills A list of skill descriptors, each `list(id, name, description)`
#' @param capabilities A list of capability flags (e.g. `streaming`)
#' @return An agent card (a list)
#' @export
agent_card <- function(name, description = "", url = "", version = "0.0.1",
                       protocol_version = "0.3.0", skills = list(),
                       capabilities = list(streaming = FALSE,
                                           pushNotifications = FALSE)) {
  if (!is.character(name) || length(name) != 1L || is.na(name) || !nzchar(name)) {
    stop("agent_card(): `name` must be a single non-empty string.")
  }
  list(
    name = name,
    description = as.character(description)[1L],
    url = as.character(url)[1L],
    version = as.character(version)[1L],
    protocolVersion = as.character(protocol_version)[1L],
    capabilities = capabilities,
    defaultInputModes = list("text/plain"),
    defaultOutputModes = list("text/plain"),
    skills = skills
  )
}

#' Serve an agent over the A2A protocol
#'
#' Starts a background server (a separate R process) that exposes `agent` via
#' a minimal A2A protocol: `GET /.well-known/agent.json` returns the agent
#' card and `POST /` handles JSON-RPC 2.0 `tasks/send` and `message/send`.
#' Returns a handle; stop it with [a2a_stop()].
#'
#' Only graph-based agents (chat, react, plan-execute, reflection) can be
#' served — they serialize cleanly to the server process. A `router_agent()`
#' carries an R closure that cannot be serialized, so it is rejected.
#'
#' @param agent An agent from [chat_agent()], [react_agent()], etc.
#' @param host Interface to bind (default "127.0.0.1")
#' @param card Optional [agent_card()]; built automatically when omitted
#' @param name Agent name for the auto-built card (defaults to the agent's
#'   description, else "agent")
#' @param description Agent description for the auto-built card
#' @param skills Skills for the auto-built card
#' @param timeout Seconds to wait for the server to report readiness
#' @return An A2A server handle (class `agentgraph_a2a_server`)
#' @export
a2a_server <- function(agent, host = "127.0.0.1", card = NULL,
                       name = NULL, description = NULL, skills = list(),
                       timeout = 30) {
  if (!requireNamespace("httpuv", quietly = TRUE)) {
    stop("a2a_server(): requires the 'httpuv' package.")
  }
  if (!is_agent(agent)) {
    stop("a2a_server(): `agent` must be created by a *_agent() constructor.")
  }
  if (!is.null(agent$run_fn) || is.null(agent$graph)) {
    stop("a2a_server(): only graph-based agents (chat/react/plan-execute/reflection) can be served; router_agent() is not serializable.")
  }
  if (is.null(card)) {
    card_name <- if (!is.null(name) && nzchar(name)) name
                 else if (nzchar(agent$description)) agent$description
                 else "agent"
    card <- agent_card(card_name,
                       description = if (is.null(description)) agent$description else description,
                       skills = skills)
  } else if (!is.list(card) || is.null(card$name)) {
    stop("a2a_server(): `card` must be an agent_card().")
  }

  agent_file <- tempfile(pattern = "agentgraph_a2a_agent_", fileext = ".rds")
  card_file  <- tempfile(pattern = "agentgraph_a2a_card_", fileext = ".rds")
  ready_file <- tempfile(pattern = "agentgraph_a2a_ready_", fileext = ".txt")
  stdout_file <- tempfile(pattern = "agentgraph_a2a_out_")
  stderr_file <- tempfile(pattern = "agentgraph_a2a_err_")
  saveRDS(agent, agent_file)
  saveRDS(card, card_file)

  script <- system.file("tools", "a2a_server.R", package = "agentgraph")
  if (!nzchar(script)) {
    stop("agentgraph: a2a_server.R missing from the installed package (reinstall agentgraph).")
  }
  rscript <- file.path(
    R.home("bin"),
    if (.Platform$OS.type == "windows") "Rscript.exe" else "Rscript"
  )

  proc <- processx::process$new(
    rscript,
    c(script, agent_file, card_file, host, ready_file),
    stdout = stdout_file,
    stderr = stderr_file,
    cleanup = TRUE
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
    stop("a2a_server(): server failed to start\n", err_text)
  }

  port <- suppressWarnings(as.integer(readLines(ready_file, warn = FALSE)[1L]))
  if (is.na(port)) {
    tryCatch(proc$kill(), error = function(e) NULL)
    stop("a2a_server(): server reported an invalid port.")
  }

  url <- paste0("http://", host, ":", port, "/")
  card$url <- url
  structure(
    list(process = proc, host = host, port = port, url = url, card = card,
         files = c(agent_file, card_file, ready_file, stdout_file, stderr_file)),
    class = "agentgraph_a2a_server"
  )
}

#' Stop an A2A server
#'
#' @param server An A2A server handle from [a2a_server()]
#' @return `NULL`, invisibly
#' @export
a2a_stop <- function(server) {
  if (is.null(server)) return(invisible(NULL))
  tryCatch({
    if (server$process$is_alive()) server$process$kill()
  }, error = function(e) NULL)
  tryCatch(unlink(server$files), error = function(e) NULL)
  invisible(NULL)
}

#' Fetch a remote agent card
#'
#' @param url The server's base URL (or its card URL)
#' @return The parsed agent card (a list)
#' @export
a2a_agent_card <- function(url) {
  if (!requireNamespace("curl", quietly = TRUE)) {
    stop("a2a_agent_card(): requires the 'curl' package.")
  }
  endpoint <- .card_endpoint(url)
  r <- curl::curl_fetch_memory(endpoint,
                               handle = curl::new_handle(useragent = "agentgraph"))
  if (r$status_code >= 400L) {
    stop("a2a_agent_card(): HTTP ", r$status_code, " from ", endpoint)
  }
  jsonlite::fromJSON(rawToChar(r$content), simplifyVector = FALSE)
}

#' Send a message to a remote A2A agent
#'
#' Sends a JSON-RPC 2.0 `tasks/send` request to the server and returns the
#' final answer text from the completed task.
#'
#' @param url The server's base URL (or its card URL)
#' @param message A single string, or an A2A message list
#'   (`list(role, parts)`)
#' @param task_id Optional task id (the server generates one when omitted)
#' @return The agent's answer as a string
#' @export
a2a_send <- function(url, message, task_id = NULL) {
  if (!requireNamespace("curl", quietly = TRUE)) {
    stop("a2a_send(): requires the 'curl' package.")
  }
  msg <- .to_a2a_message(message)
  params <- list(id = task_id, message = msg)
  req <- list(jsonrpc = "2.0", id = .rpc_id(),
              method = "tasks/send", params = params)
  body <- jsonlite::toJSON(req, auto_unbox = TRUE, null = "null")

  h <- curl::new_handle(useragent = "agentgraph")
  curl::handle_setopt(h, post = TRUE, postfields = body)
  curl::handle_setopt(h, httpheader = "Content-Type: application/json")
  r <- curl::curl_fetch_memory(.base_url(url), handle = h)
  if (r$status_code >= 400L) {
    stop("a2a_send(): HTTP ", r$status_code, " from ", .base_url(url))
  }
  resp <- jsonlite::fromJSON(rawToChar(r$content), simplifyVector = FALSE)
  if (!is.null(resp$error)) {
    stop("a2a_send(): server error ", resp$error$code, ": ", resp$error$message)
  }
  .task_answer(resp$result)
}

#' Wrap a remote A2A agent as a local agent
#'
#' Returns an agent object whose [run_agent()] call delegates to a remote A2A
#' endpoint via [a2a_send()]. This lets a local agent route to, or compose
#' with, an agent served elsewhere.
#'
#' @param url The remote server's base URL (or its card URL)
#' @param description Optional description for the returned agent
#' @return An agent object (run with [run_agent()])
#' @export
a2a_agent <- function(url, description = "") {
  base <- .base_url(url)
  run_fn <- function(input, ...) {
    ans <- a2a_send(base, input, ...)
    list(answer = ans, state = list(answer = ans, remote = base))
  }
  new_agent(run_fn = run_fn, tools = list(),
            description = if (nzchar(description)) description
                          else paste0("remote A2A agent at ", base))
}

#' Print an A2A server handle
#'
#' @param x An A2A server handle from [a2a_server()]
#' @param ... Unused
#' @return `x`, invisibly
#' @export
print.agentgraph_a2a_server <- function(x, ...) {
  alive <- tryCatch(x$process$is_alive(), error = function(e) FALSE)
  cat(sprintf("agentgraph A2A server: %s (%s) [%s]\n",
              x$card$name, x$url, if (alive) "running" else "stopped"))
  invisible(x)
}
