#!/usr/bin/env Rscript
# agentgraph tool server
#
# Runs in an isolated R process. Receives serialized custom tool handlers via
# an .rds file, binds a TCP port (scanning a caller-supplied range), reports
# the chosen port through a ready file, then serves newline-delimited JSON
# requests:
#
#   request:  {"name": "<tool>", "args_json": "<raw JSON string of arguments>"}
#   response: {"ok": true, "result_str": "<raw JSON string returned by handler>"}
#          or {"ok": false, "error": "<message>"}
#
# The handler receives the args JSON string exactly as the C++ engine dumped
# it (same contract as the in-process callback path) and returns a JSON
# string. The server is a pure pipe: it never re-serializes args or results,
# so semantics are identical to direct in-process tool handlers.
#
# Usage: Rscript tool_server.R <handlers_rds> <port_file> <port_start> <port_end>

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 4) {
  stop("usage: tool_server.R <handlers_rds> <port_file> <port_start> <port_end>")
}
handlers_file <- args[1]
port_file <- args[2]
port_start <- as.integer(args[3])
port_end <- as.integer(args[4])

suppressPackageStartupMessages(library(jsonlite))

if (!file.exists(handlers_file)) {
  stop("tool_server: handlers file not found: ", handlers_file)
}
tool_defs <- readRDS(handlers_file)
if (!is.list(tool_defs) || length(tool_defs) == 0) {
  stop("tool_server: handlers file contains no tool definitions")
}
handlers <- new.env(parent = emptyenv())
for (td in tool_defs) {
  if (is.null(td$name) || is.null(td$handler)) {
    stop("tool_server: malformed tool definition (needs name + handler)")
  }
  assign(td$name, td$handler, envir = handlers)
}

sock <- NULL
port <- NULL
for (p in seq.int(port_start, port_end)) {
  s <- tryCatch(serverSocket(p), error = function(e) NULL)
  if (!is.null(s)) {
    sock <- s
    port <- p
    break
  }
}
if (is.null(sock)) {
  stop("tool_server: no free port in range ", port_start, "-", port_end)
}

# Ready signal for the parent process.
pf <- file(port_file, open = "wt")
writeLines(as.character(port), pf)
close(pf)

serve_connection <- function(con) {
  repeat {
    line <- tryCatch(
      readLines(con, n = 1L, warn = FALSE),
      error = function(e) NULL
    )
    if (is.null(line) || length(line) == 0L || !nzchar(line)) break

    resp <- tryCatch({
      req <- fromJSON(line, simplifyVector = FALSE)
      if (is.null(req$name)) stop("request missing 'name'")
      h <- get0(req$name, envir = handlers, inherits = FALSE, ifnotfound = NULL)
      if (is.null(h)) {
        list(ok = FALSE, error = paste0("Tool not found: ", req$name))
      } else {
        out_str <- h(req$args_json)
        if (length(out_str) > 1L) out_str <- out_str[[1]]
        list(ok = TRUE, result_str = out_str)
      }
    }, error = function(e) {
      list(ok = FALSE, error = conditionMessage(e))
    })

    payload <- charToRaw(paste0(toJSON(resp, auto_unbox = TRUE), "\n"))
    writeBin(payload, con)
  }
}

repeat {
  client <- tryCatch(
    socketAccept(sock, open = "r+b", blocking = TRUE),
    error = function(e) NULL
  )
  if (is.null(client)) next
  tryCatch(serve_connection(client), error = function(e) NULL)
  tryCatch(close(client), error = function(e) NULL)
}
