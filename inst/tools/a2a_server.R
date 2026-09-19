#!/usr/bin/env Rscript
# agentgraph A2A server (subprocess)
#
# Serves an agent over HTTP using a minimal Agent-to-Agent (A2A) protocol:
#
#   GET  /.well-known/agent.json   -> the agent card (JSON)
#   GET  /agent-card.json          -> the agent card (alias)
#   POST /                         -> JSON-RPC 2.0 "tasks/send" or "message/send"
#
# The agent and its card are deserialized from .rds files produced by
# R/a2a.R a2a_server(). A ready file receives the actual bound port. The
# server runs forever (the parent process kills it with a2a_stop()).
#
# Usage: Rscript a2a_server.R <agent_rds> <card_rds> <host> <ready_file>

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 4L) {
  stop("usage: a2a_server.R <agent_rds> <card_rds> <host> <ready_file>")
}
agent_file <- args[[1L]]
card_file  <- args[[2L]]
host       <- args[[3L]]
ready_file <- args[[4L]]

suppressPackageStartupMessages({
  library(jsonlite)
  library(httpuv)
  library(agentgraph)
})

agent <- readRDS(agent_file)
card  <- readRDS(card_file)
if (!inherits(agent, "agentgraph_agent")) {
  stop("a2a_server: agent file does not contain an agentgraph agent")
}
if (is.null(card) || !is.list(card)) {
  stop("a2a_server: card file does not contain an agent card")
}

text_from_parts <- function(parts) {
  if (is.null(parts) || length(parts) == 0L) return("")
  paste(vapply(parts, function(p) {
    if (!is.null(p$text) && is.character(p$text)) p$text
    else if (!is.null(p$data) && !is.null(p$data$text)) p$data$text
    else ""
  }, character(1L)), collapse = "\n")
}

message_text <- function(msg) {
  if (is.character(msg)) return(paste(msg, collapse = "\n"))
  if (is.null(msg)) return("")
  text_from_parts(msg$parts)
}

answer_parts <- function(text) list(list(type = "text", text = text))

rpc_error <- function(id, code, message) {
  list(jsonrpc = "2.0", id = id, error = list(code = code, message = message))
}

run_one <- function(method, params, id) {
  if (identical(method, "tasks/send") || identical(method, "message/send")) {
    input <- message_text(params$message)
    if (!nzchar(input)) {
      return(rpc_error(id, -32602L, "message has no text"))
    }
    err <- NULL
    ans <- tryCatch(agentgraph::run_agent(agent, input)$answer,
                    error = function(e) { err <<- conditionMessage(e); NULL })
    if (!is.null(err)) {
      return(rpc_error(id, -32000L, paste("agent failed:", err)))
    }
    ans <- as.character(ans)[1L]

    if (identical(method, "tasks/send")) {
      task_id <- if (!is.null(params$id) && nzchar(params$id)) params$id
                 else paste0("task-", as.integer(Sys.time()), "-",
                             sample.int(1e6, 1L))
      context_id <- if (!is.null(params$contextId)) params$contextId
                    else paste0("ctx-", sample.int(1e9, 1L))
      result <- list(
        id = task_id,
        contextId = context_id,
        status = list(state = "completed"),
        artifacts = list(list(name = "answer", parts = answer_parts(ans)))
      )
    } else {
      result <- list(role = "agent", parts = answer_parts(ans))
    }
    list(jsonrpc = "2.0", id = id, result = result)
  } else {
    rpc_error(id, -32601L, paste0("method not supported: ", method))
  }
}

app <- list(call = function(req) {
  method <- req$REQUEST_METHOD
  path <- req$PATH_INFO

  if (identical(method, "GET") &&
      (grepl("agent.json$", path) || grepl("agent-card.json$", path))) {
    return(list(
      status = 200L,
      headers = list("Content-Type" = "application/json"),
      body = toJSON(card, auto_unbox = TRUE)
    ))
  }

  if (identical(method, "POST")) {
    raw <- tryCatch(req$rook.input$read(), error = function(e) raw(0L))
    resp <- tryCatch({
      rpc <- fromJSON(rawToChar(raw), simplifyVector = FALSE)
      if (is.null(rpc$jsonrpc) || is.null(rpc$method)) {
        rpc_error(rpc$id, -32600L, "invalid JSON-RPC request")
      } else {
        params <- if (is.null(rpc$params)) list() else rpc$params
        run_one(rpc$method, params, rpc$id)
      }
    }, error = function(e) {
      rpc_error(NULL, -32700L, paste("parse error:", conditionMessage(e)))
    })
    return(list(
      status = 200L,
      headers = list("Content-Type" = "application/json"),
      body = toJSON(resp, auto_unbox = TRUE, null = "null")
    ))
  }

  list(
    status = 404L,
    headers = list("Content-Type" = "application/json"),
    body = toJSON(list(error = "not found"), auto_unbox = TRUE)
  )
})

port <- tryCatch(randomPort(), error = function(e) NULL)
if (is.null(port)) stop("a2a_server: httpuv::randomPort() failed")

h <- startServer(host, port, app)
card$url <- paste0("http://", host, ":", h$getPort(), "/")
writeLines(as.character(h$getPort()), ready_file)

while (TRUE) {
  httpuv::service(1000L)
}
