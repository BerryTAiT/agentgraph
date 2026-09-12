#!/usr/bin/env Rscript
# agentgraph mock LLM server (test harness only)
#
# Serves a *scripted* sequence of OpenAI chat-completions responses over
# plain HTTP so the native C++ WinHTTP client can be exercised offline.
# The responses come from a scenario JSON file (an array of response
# objects) and are served in order; the final entry repeats for any further
# request. This mirrors the isolated-process pattern of inst/tools/tool_server.R.
#
# Usage: Rscript mock_llm_server.R <port_start> <port_end> <scenario_json> <ready_file> <request_log_file>
#
# Scenario response object fields:
#   finish_reason  "stop" | "tool_calls" | "length" | "error"   (default "stop")
#   content        assistant message content (default "")
#   tool_calls     array of {id, name, arguments}
#   model          model name echoed back (default "mock-model")
#   usage          {prompt_tokens, completion_tokens, total_tokens}
#   status         HTTP status code (default 200)

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 5) {
  stop("usage: mock_llm_server.R <port_start> <port_end> <scenario_json> <ready_file> <request_log_file>")
}
port_start <- as.integer(args[1])
port_end   <- as.integer(args[2])
scenario_file <- args[3]
ready_file    <- args[4]
request_log   <- args[5]

suppressPackageStartupMessages({
  library(httpuv)
  library(jsonlite)
})

scenario <- fromJSON(scenario_file, simplifyVector = FALSE)
if (!is.list(scenario) || length(scenario) == 0) {
  stop("mock_llm_server: empty or malformed scenario file")
}

call_count <- 0L

`%||%` <- function(a, b) if (is.null(a)) b else a

read_body <- function(req) {
  inp <- req$rook.input
  if (is.null(inp)) return("")
  tryCatch({
    lines <- inp$read_lines()
    if (length(lines) == 0) "" else paste(lines, collapse = "\n")
  }, error = function(e) {
    tryCatch(rawToChar(inp$read()), error = function(e2) "")
  })
}

build_response <- function(item, idx) {
  status <- item$status %||% 200L
  finish <- item$finish_reason %||% "stop"
  content <- item$content %||% ""
  model  <- item$model %||% "mock-model"

  message <- list(role = "assistant")
  if (is.null(item$tool_calls)) {
    message$content <- content
  } else {
    if (!is.null(content) && nzchar(content)) message$content <- content
    message$tool_calls <- lapply(item$tool_calls, function(tc) {
      list(
        id = tc$id,
        type = "function",
        `function` = list(name = tc$name, arguments = tc$arguments)
      )
    })
  }

  usage <- item$usage %||% list(prompt_tokens = 10, completion_tokens = 5, total_tokens = 15)

  list(
    id = paste0("chatcmpl-mock-", idx),
    object = "chat.completion",
    created = as.integer(Sys.time()),
    model = model,
    choices = list(list(
      index = 0L,
      message = message,
      finish_reason = finish
    )),
    usage = usage
  )
}

app <- list(call = function(req) {
  if (identical(req$REQUEST_METHOD, "GET")) {
    return(list(status = 200L,
                headers = list(`Content-Type` = "text/plain"),
                body = "OK"))
  }

  call_count <<- call_count + 1L
  body <- read_body(req)

  # Append the raw request body to the log (one compact line per request).
  if (nzchar(request_log)) {
    line <- gsub("[\r\n]+", " ", body)
    if (!nzchar(line)) line <- "<empty>"
    tryCatch({
      con <- file(request_log, open = "at")
      writeLines(paste0(line), con, useBytes = TRUE)
      close(con)
    }, error = function(e) NULL)
  }

  idx <- min(call_count, length(scenario))
  payload <- build_response(scenario[[idx]], idx)

  list(status = as.integer(payload$status %||% 200L),
       headers = list(`Content-Type` = "application/json"),
       body = toJSON(payload, auto_unbox = TRUE, null = "null"))
})

srv <- NULL
chosen <- NULL
for (p in seq.int(port_start, port_end)) {
  s <- tryCatch(startServer("127.0.0.1", p, app, quiet = TRUE),
                error = function(e) NULL)
  if (!is.null(s)) {
    srv <- s
    chosen <- p
    break
  }
}
if (is.null(srv)) {
  stop("mock_llm_server: no free port in range ", port_start, "-", port_end)
}

pf <- file(ready_file, open = "wt")
writeLines(as.character(chosen), pf)
close(pf)

repeat {
  service(1000)
}
