#!/usr/bin/env Rscript
# agentgraph in-process mock LLM server (subprocess)
#
# Serves an OpenAI-compatible /chat/completions endpoint from a scripted set of
# responses, so tests and demos run fully offline without Python or an API key.
# Two modes (from the serialized config):
#   - "sequence": responses are served in order; the last entry repeats.
#   - "keyed":    responses are a named list; each request's last user message
#                 is matched against the names (exact), falling back to a "*"
#                 entry, then to the first entry.
#
# Usage: Rscript mock_server.R <config_rds> <ready_file>

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 2L) stop("usage: mock_server.R <config_rds> <ready_file>")
config_file <- args[[1L]]
ready_file <- args[[2L]]

suppressPackageStartupMessages({
  library(jsonlite)
  library(httpuv)
})

config <- readRDS(config_file)
mode <- config$mode
responses <- config$responses

last_user_content <- function(body) {
  msgs <- body$messages
  if (is.null(msgs)) return("")
  for (m in rev(msgs)) {
    if (identical(m$role, "user")) {
      if (is.character(m$content)) return(m$content)
      if (is.list(m$content)) {
        txt <- vapply(m$content, function(p) {
          if (!is.null(p$text) && is.character(p$text)) p$text else ""
        }, character(1L))
        return(paste(txt, collapse = ""))
      }
      return("")
    }
  }
  ""
}

build_completion <- function(item, n) {
  content <- if (is.null(item$content)) "" else item$content
  finish <- if (is.null(item$finish_reason)) "stop" else item$finish_reason
  model <- if (is.null(item$model)) "mock" else item$model
  usage <- if (is.null(item$usage)) {
    list(prompt_tokens = 10, completion_tokens = 5, total_tokens = 15)
  } else item$usage

  message <- list(role = "assistant")
  if (is.null(item$tool_calls)) {
    message$content <- content
  } else {
    if (nzchar(content)) message$content <- content
    message$tool_calls <- lapply(item$tool_calls, function(tc) {
      args <- tc$arguments
      if (!is.character(args)) args <- toJSON(args, auto_unbox = TRUE)
      list(id = tc$id, type = "function",
           "function" = list(name = tc$name, arguments = args))
    })
  }

  list(id = paste0("chatcmpl-mock-", n),
       object = "chat.completion", created = 0, model = model,
       choices = list(list(index = 0, message = message, finish_reason = finish)),
       usage = usage)
}

call_count <- 0L

app <- list(call = function(req) {
  method <- req$REQUEST_METHOD
  path <- req$PATH_INFO

  if (identical(method, "POST") && grepl("/chat/completions$", path)) {
    raw <- tryCatch(req$rook.input$read(), error = function(e) raw(0L))
    body <- tryCatch(fromJSON(rawToChar(raw), simplifyVector = FALSE),
                     error = function(e) list())
    call_count <<- call_count + 1L

    item <- NULL
    if (identical(mode, "keyed")) {
      user <- last_user_content(body)
      nm <- names(responses)
      idx <- which(nm == user)
      if (length(idx) == 0L) idx <- which(nm == "*")
      if (length(idx) == 0L) idx <- 1L
      item <- responses[[idx]]
    } else {
      item <- responses[[min(call_count, length(responses))]]
    }

    payload <- build_completion(item, call_count)
    return(list(status = 200L,
                headers = list("Content-Type" = "application/json"),
                body = toJSON(payload, auto_unbox = TRUE)))
  }

  list(status = 404L,
       headers = list("Content-Type" = "application/json"),
       body = toJSON(list(error = "not found"), auto_unbox = TRUE))
})

port <- tryCatch(randomPort(), error = function(e) NULL)
if (is.null(port)) stop("mock_server: httpuv::randomPort() failed")

h <- startServer("127.0.0.1", port, app)
writeLines(as.character(h$getPort()), ready_file)

while (TRUE) {
  httpuv::service(1000L)
}
