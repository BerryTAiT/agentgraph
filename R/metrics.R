# Metrics ---------------------------------------------------------------------
#
# In-memory observability for graph runs: the collector accumulates LLM call
# counts, latency samples, token usage, error counts, tool-call counts, and node
# runs from engine events (wired into run() automatically). metrics_snapshot()
# returns them; start_metrics_server() serves them as Prometheus text on /metrics.

# Mutable metrics state (namespace bindings are locked).
.agentgraph_metrics <- new.env(parent = emptyenv())

.metrics_reset_env <- function() {
  .agentgraph_metrics$llm_calls <- 0L
  .agentgraph_metrics$llm_errors <- 0L
  .agentgraph_metrics$latencies <- numeric()
  .agentgraph_metrics$prompt_tokens <- 0
  .agentgraph_metrics$completion_tokens <- 0
  .agentgraph_metrics$total_tokens <- 0
  .agentgraph_metrics$tool_calls <- 0L
  .agentgraph_metrics$node_runs <- 0L
  invisible(NULL)
}
.metrics_reset_env()

# Internal: accumulate one engine event into the metrics state.
.metrics_collect <- function(event, data) {
  m <- .agentgraph_metrics
  if (identical(event, "llm_end")) {
    m$llm_calls <- m$llm_calls + 1L
    if (!isTRUE(data$success)) m$llm_errors <- m$llm_errors + 1L
    d <- data$duration_ms
    if (is.numeric(d) && length(d) == 1L && !is.na(d)) {
      m$latencies <- c(m$latencies, d)
    }
  } else if (identical(event, "llm_response")) {
    u <- data$usage
    if (is.list(u)) {
      m$prompt_tokens <- m$prompt_tokens + as.numeric(u$prompt_tokens %||% 0)
      m$completion_tokens <- m$completion_tokens + as.numeric(u$completion_tokens %||% 0)
      m$total_tokens <- m$total_tokens + as.numeric(u$total_tokens %||% 0)
    }
  } else if (identical(event, "tool_call")) {
    m$tool_calls <- m$tool_calls + 1L
  } else if (identical(event, "node_start")) {
    m$node_runs <- m$node_runs + 1L
  }
  invisible(NULL)
}

# Wrap the user's on_event so metrics are always collected (and the user
# callback still fires). Used by run()/resume()/checkpoint_resume().
.wrap_event_callback <- function(user_on_event) {
  function(event, data_json) {
    data <- tryCatch(jsonlite::fromJSON(data_json, simplifyVector = FALSE),
                     error = function(e) data_json)
    .metrics_collect(event, data)
    if (!is.null(user_on_event)) user_on_event(event, data)
  }
}

#' Snapshot the current metrics
#'
#' Returns the accumulated metrics for this session: LLM call/error counts,
#' latency quantiles (p50/p95/p99), token totals, tool-call and node counts,
#' and cache hit/miss totals. Latency samples come from `llm_end` events.
#'
#' @return A named list of metrics
#' @export
metrics_snapshot <- function() {
  m <- .agentgraph_metrics
  lat <- m$latencies
  q <- function(p) if (length(lat) == 0L) 0 else as.numeric(stats::quantile(lat, p, names = FALSE))
  ch <- cache_hit_stats_cpp()
  list(
    llm_calls = m$llm_calls,
    llm_errors = m$llm_errors,
    error_rate = if (m$llm_calls == 0L) 0 else m$llm_errors / m$llm_calls,
    latency_p50 = q(0.5), latency_p95 = q(0.95), latency_p99 = q(0.99),
    latency_count = length(lat),
    prompt_tokens = m$prompt_tokens,
    completion_tokens = m$completion_tokens,
    total_tokens = m$total_tokens,
    tool_calls = m$tool_calls,
    node_runs = m$node_runs,
    cache_hits = ch$hits,
    cache_misses = ch$misses
  )
}

#' Reset the metrics accumulator
#'
#' @return Invisibly `NULL`
#' @export
metrics_reset <- function() {
  .metrics_reset_env()
  invisible(NULL)
}

# Render a metrics snapshot as Prometheus text format.
.metrics_prometheus <- function(s) {
  paste(c(
    "# HELP agentgraph_llm_calls_total Total number of LLM calls.",
    "# TYPE agentgraph_llm_calls_total counter",
    paste0("agentgraph_llm_calls_total ", s$llm_calls),
    "# HELP agentgraph_llm_errors_total Total number of failed LLM calls.",
    "# TYPE agentgraph_llm_errors_total counter",
    paste0("agentgraph_llm_errors_total ", s$llm_errors),
    "# HELP agentgraph_llm_latency_ms LLM call latency in milliseconds.",
    "# TYPE agentgraph_llm_latency_ms summary",
    paste0("agentgraph_llm_latency_ms{quantile=\"0.5\"} ", round(s$latency_p50, 3)),
    paste0("agentgraph_llm_latency_ms{quantile=\"0.95\"} ", round(s$latency_p95, 3)),
    paste0("agentgraph_llm_latency_ms{quantile=\"0.99\"} ", round(s$latency_p99, 3)),
    "# TYPE agentgraph_total_tokens counter",
    paste0("agentgraph_total_tokens ", s$total_tokens),
    "# TYPE agentgraph_prompt_tokens counter",
    paste0("agentgraph_prompt_tokens ", s$prompt_tokens),
    "# TYPE agentgraph_completion_tokens counter",
    paste0("agentgraph_completion_tokens ", s$completion_tokens),
    "# TYPE agentgraph_tool_calls_total counter",
    paste0("agentgraph_tool_calls_total ", s$tool_calls),
    "# TYPE agentgraph_cache_hits_total counter",
    paste0("agentgraph_cache_hits_total ", s$cache_hits),
    "# TYPE agentgraph_cache_misses_total counter",
    paste0("agentgraph_cache_misses_total ", s$cache_misses)
  ), collapse = "\n")
}

# Well-known snapshot file the metrics server reads (updated after every run).
.metrics_file <- function() file.path(tempdir(), "agentgraph_metrics.txt")

# Internal: write the current metrics to the snapshot file (no-op if none).
.metrics_write <- function() {
  tryCatch(writeLines(.metrics_prometheus(metrics_snapshot()), .metrics_file()),
           error = function(e) NULL)
  invisible(NULL)
}

#' Start a metrics server
#'
#' Spawns a background server exposing `GET /metrics` (Prometheus text format)
#' and `GET /health`. The metrics file is refreshed after every [run()], so
#' scrapes always reflect the latest session activity. Stop it with
#' [metrics_stop()].
#'
#' @param port Port to bind
#' @param host Interface to bind (default "127.0.0.1")
#' @param timeout Seconds to wait for readiness
#' @return A server handle (class `agentgraph_metrics_server`)
#' @export
start_metrics_server <- function(port = 9090, host = "127.0.0.1", timeout = 30) {
  if (!requireNamespace("httpuv", quietly = TRUE)) {
    stop("start_metrics_server(): requires the 'httpuv' package.")
  }
  .metrics_write()
  ready <- tempfile(pattern = "agentgraph_metrics_ready_", fileext = ".txt")
  out <- tempfile(pattern = "agentgraph_metrics_out_")
  err <- tempfile(pattern = "agentgraph_metrics_err_")
  script <- system.file("tools", "metrics_server.R", package = "agentgraph")
  if (!nzchar(script)) {
    stop("agentgraph: metrics_server.R missing from the installed package (reinstall agentgraph).")
  }
  rscript <- file.path(R.home("bin"),
                       if (.Platform$OS.type == "windows") "Rscript.exe" else "Rscript")
  proc <- processx::process$new(
    rscript,
    c(script, .metrics_file(), as.character(port), host, ready),
    stdout = out, stderr = err, cleanup = TRUE
  )
  deadline <- Sys.time() + timeout
  while (!file.exists(ready) && proc$is_alive() && Sys.time() < deadline) Sys.sleep(0.05)
  if (!file.exists(ready)) {
    err_text <- if (file.exists(err)) paste(readLines(err, warn = FALSE), collapse = "\n") else ""
    tryCatch(proc$kill(), error = function(e) NULL)
    stop("start_metrics_server(): server failed to start\n", err_text)
  }
  actual_port <- suppressWarnings(as.integer(readLines(ready, warn = FALSE)[1L]))
  structure(
    list(process = proc, host = host, port = if (is.na(actual_port)) port else actual_port,
         url = paste0("http://", host, ":", if (is.na(actual_port)) port else actual_port, "/"),
         files = c(ready, out, err)),
    class = "agentgraph_metrics_server"
  )
}

#' Stop a metrics server
#'
#' @param server A server handle from [start_metrics_server()]
#' @return `NULL`, invisibly
#' @export
metrics_stop <- function(server) {
  if (is.null(server)) return(invisible(NULL))
  tryCatch({
    if (server$process$is_alive()) server$process$kill()
  }, error = function(e) NULL)
  tryCatch(unlink(server$files), error = function(e) NULL)
  invisible(NULL)
}

#' Print a metrics server handle
#'
#' @param x A server handle from [start_metrics_server()]
#' @param ... Unused
#' @return `x`, invisibly
#' @export
print.agentgraph_metrics_server <- function(x, ...) {
  alive <- tryCatch(x$process$is_alive(), error = function(e) FALSE)
  cat(sprintf("agentgraph metrics server: %s [%s]\n",
              x$url, if (alive) "running" else "stopped"))
  invisible(x)
}

`%||%` <- function(a, b) if (is.null(a)) b else a
