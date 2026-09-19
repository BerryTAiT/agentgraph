#!/usr/bin/env Rscript
# agentgraph SSE (Server-Sent Events) server (subprocess)
#
# Streams an agent's tokens to a browser as text/event-stream:
#
#   GET  /health            -> {"status":"ok"}              (open)
#   POST /stream            -> body {"input":"..."} -> SSE  (auth)
#   GET  /stream?input=...  -> SSE                          (auth)
#
# Each token is emitted as `data: <token>` and the stream ends with
# `data: [DONE]`. When <auth_token> is non-empty, /stream requires
# "Authorization: Bearer <auth_token>".
#
# Usage: Rscript sse_server.R <agent_rds> <auth_token> <port> <host> <ready_file>

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 5L) stop("usage: sse_server.R <agent_rds> <auth_token> <port> <host> <ready_file>")
agent_file <- args[[1L]]
auth_token <- args[[2L]]
port <- as.integer(args[[3L]])
host <- args[[4L]]
ready_file <- args[[5L]]

suppressPackageStartupMessages({
  library(jsonlite)
  library(httpuv)
  library(agentgraph)
})

agent <- readRDS(agent_file)
if (!inherits(agent, "agentgraph_agent")) stop("sse_server: agent file is not an agent")
auth_token <- if (nzchar(auth_token)) auth_token else NULL

json_response <- function(status, obj) {
  list(status = status, headers = list("Content-Type" = "application/json"),
       body = toJSON(obj, auto_unbox = TRUE))
}

# Constant-time string comparison (see serve_agent.R for rationale).
.ct_equal <- function(a, b) {
  if (is.null(a) || is.null(b)) return(FALSE)
  ra <- charToRaw(enc2utf8(a))
  rb <- charToRaw(enc2utf8(b))
  if (length(ra) != length(rb)) return(FALSE)
  if (length(ra) == 0L) return(TRUE)
  sum(as.integer(bitwXor(ra, rb))) == 0L
}

# Naive fixed-window rate limiter for /stream (per process).
.rl_env <- new.env(parent = emptyenv())
.rl_env$window_start <- as.numeric(Sys.time())
.rl_env$count <- 0L
.rl_limit <- 120L
.rl_window_sec <- 60
.rate_limited <- function() {
  now <- as.numeric(Sys.time())
  if (now - .rl_env$window_start >= .rl_window_sec) {
    .rl_env$window_start <- now
    .rl_env$count <- 0L
  }
  .rl_env$count <- .rl_env$count + 1L
  .rl_env$count > .rl_limit
}

is_authorized <- function(req) {
  if (is.null(auth_token)) return(TRUE)
  .ct_equal(req$HTTP_AUTHORIZATION, paste0("Bearer ", auth_token))
}

query_input <- function(req) {
  qs <- req$QUERY_STRING
  if (is.null(qs) || !nzchar(qs)) return("")
  qs <- sub("^\\?", "", qs)  # httpuv includes the leading '?'
  for (kv in strsplit(qs, "&", fixed = TRUE)[[1L]]) {
    if (startsWith(kv, "input=")) return(utils::URLdecode(sub("^input=", "", kv)))
  }
  ""
}

app <- list(call = function(req) {
  method <- req$REQUEST_METHOD
  path <- req$PATH_INFO

  if (identical(method, "GET") && grepl("/health$", path)) {
    return(json_response(200L, list(status = "ok")))
  }

  if (grepl("/stream$", path) && method %in% c("GET", "POST")) {
    if (!is_authorized(req)) return(json_response(401L, list(error = "unauthorized")))
    if (.rate_limited()) return(json_response(429L, list(error = "rate limit exceeded")))
    input <- if (identical(method, "POST")) {
      raw <- tryCatch(req$rook.input$read(), error = function(e) raw(0L))
      body <- tryCatch(fromJSON(rawToChar(raw), simplifyVector = FALSE), error = function(e) list())
      if (is.character(body$input)) body$input else ""
    } else {
      query_input(req)
    }
    if (!nzchar(input)) return(json_response(400L, list(error = "missing or empty `input`")))

    acc <- new.env(parent = emptyenv())
    acc$tokens <- character()
    tryCatch(
      agentgraph::run_agent(agent, input,
                            on_token = function(t) acc$tokens <- c(acc$tokens, t)),
      error = function(e) NULL)

    body <- paste0(paste0("data: ", acc$tokens, "\n\n", collapse = ""),
                   "data: [DONE]\n\n")
    return(list(status = 200L,
                headers = list("Content-Type" = "text/event-stream",
                               "Cache-Control" = "no-cache"),
                body = body))
  }

  json_response(404L, list(error = "not found"))
})

if (port == 0L) port <- randomPort()
h <- startServer(host, port, app)
writeLines(as.character(h$getPort()), ready_file)

while (TRUE) {
  httpuv::service(1000L)
}
