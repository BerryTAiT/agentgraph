#!/usr/bin/env Rscript
# agentgraph REST server (subprocess)
#
# Exposes an agent over a minimal JSON REST API:
#
#   GET  /health          -> {"status":"ok"}                       (open)
#   POST /run             -> {"input":"..."} -> {"answer","state"} (auth)
#   POST /stream          -> {"input":"..."} -> {"answer","tokens"}(auth)
#
# When <auth_token> is non-empty, /run and /stream require
# "Authorization: Bearer <auth_token>". The agent is deserialized from an .rds
# file produced by R/serve.R serve_agent(). A ready file receives the actual
# bound port; the server runs forever (parent kills it with serve_stop()).
#
# Usage: Rscript serve_agent.R <agent_rds> <auth_token> <host> <ready_file>

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 4L) {
  stop("usage: serve_agent.R <agent_rds> <auth_token> <host> <ready_file>")
}
agent_file <- args[[1L]]
auth_token <- args[[2L]]
host       <- args[[3L]]
ready_file <- args[[4L]]

suppressPackageStartupMessages({
  library(jsonlite)
  library(httpuv)
  library(agentgraph)
})

agent <- readRDS(agent_file)
if (!inherits(agent, "agentgraph_agent")) {
  stop("serve_agent: agent file does not contain an agentgraph agent")
}
auth_token <- if (nzchar(auth_token)) auth_token else NULL

json_response <- function(status, obj) {
  list(status = status,
       headers = list("Content-Type" = "application/json"),
       body = toJSON(obj, auto_unbox = TRUE))
}

# Constant-time string comparison: always compares every byte so the response
# time does not leak how many leading characters of the token were correct.
.ct_equal <- function(a, b) {
  if (is.null(a) || is.null(b)) return(FALSE)
  ra <- charToRaw(enc2utf8(a))
  rb <- charToRaw(enc2utf8(b))
  if (length(ra) != length(rb)) return(FALSE)
  if (length(ra) == 0L) return(TRUE)
  sum(as.integer(bitwXor(ra, rb))) == 0L
}

# Naive fixed-window rate limiter for the auth'd endpoints (per process).
# Not a substitute for a real reverse proxy, but blunts naive abuse loops.
.rl_env <- new.env(parent = emptyenv())
.rl_env$window_start <- as.numeric(Sys.time())
.rl_env$count <- 0L
.rl_limit <- 120L          # requests ...
.rl_window_sec <- 60       # ... per window
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

read_input <- function(req) {
  raw <- tryCatch(req$rook.input$read(), error = function(e) raw(0L))
  body <- tryCatch(fromJSON(rawToChar(raw), simplifyVector = FALSE),
                   error = function(e) list())
  if (is.character(body$input) && length(body$input) == 1L) body$input else ""
}

app <- list(call = function(req) {
  method <- req$REQUEST_METHOD
  path <- req$PATH_INFO

  if (identical(method, "GET") && grepl("/health$", path)) {
    return(json_response(200L, list(status = "ok")))
  }

  if (identical(method, "POST") &&
      (grepl("/run$", path) || grepl("/stream$", path))) {
    if (!is_authorized(req)) {
      return(json_response(401L, list(error = "unauthorized")))
    }
    if (.rate_limited()) {
      return(json_response(429L, list(error = "rate limit exceeded")))
    }
    input <- read_input(req)
    if (!nzchar(input)) {
      return(json_response(400L, list(error = "missing or empty `input`")))
    }

    if (grepl("/stream$", path)) {
      acc <- new.env(parent = emptyenv())
      acc$tokens <- character()
      ans <- tryCatch(
        agentgraph::run_agent(
          agent, input,
          on_token = function(t) acc$tokens <- c(acc$tokens, t))$answer,
        error = function(e) NULL)
      if (is.null(ans)) return(json_response(500L, list(error = "agent failed")))
      return(json_response(200L, list(answer = ans, tokens = acc$tokens)))
    }

    res <- tryCatch(agentgraph::run_agent(agent, input), error = function(e) NULL)
    if (is.null(res)) return(json_response(500L, list(error = "agent failed")))
    return(json_response(200L, list(answer = res$answer, state = res$state)))
  }

  json_response(404L, list(error = "not found"))
})

port <- tryCatch(randomPort(), error = function(e) NULL)
if (is.null(port)) stop("serve_agent: httpuv::randomPort() failed")

h <- startServer(host, port, app)
writeLines(as.character(h$getPort()), ready_file)

while (TRUE) {
  httpuv::service(1000L)
}
