#!/usr/bin/env Rscript
# agentgraph metrics server (subprocess)
#
# Serves the current Prometheus-format metrics snapshot:
#
#   GET /metrics  -> text/plain metrics (read from <metrics_file>)
#   GET /health   -> {"status":"ok"}
#
# The metrics file is refreshed by the parent R session after every run()
# (and by start_metrics_server() at startup). Pass port 0 to bind a random
# free port; the actual port is written to <ready_file>.
#
# Usage: Rscript metrics_server.R <metrics_file> <port> <host> <ready_file>

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 4L) stop("usage: metrics_server.R <metrics_file> <port> <host> <ready_file>")
metrics_file <- args[[1L]]
port <- as.integer(args[[2L]])
host <- args[[3L]]
ready_file <- args[[4L]]

suppressPackageStartupMessages({
  library(jsonlite)
  library(httpuv)
})

app <- list(call = function(req) {
  method <- req$REQUEST_METHOD
  path <- req$PATH_INFO

  if (identical(method, "GET") && grepl("/health$", path)) {
    return(list(status = 200L, headers = list("Content-Type" = "application/json"),
                body = toJSON(list(status = "ok"), auto_unbox = TRUE)))
  }

  if (identical(method, "GET") && grepl("/metrics$", path)) {
    txt <- if (file.exists(metrics_file)) {
      paste(readLines(metrics_file, warn = FALSE), collapse = "\n")
    } else ""
    return(list(status = 200L, headers = list("Content-Type" = "text/plain"),
                body = txt))
  }

  list(status = 404L, headers = list("Content-Type" = "application/json"),
       body = toJSON(list(error = "not found"), auto_unbox = TRUE))
})

if (port == 0L) port <- randomPort()
h <- startServer(host, port, app)
writeLines(as.character(h$getPort()), ready_file)

while (TRUE) {
  httpuv::service(1000L)
}
