# Built-in mock LLM + replay --------------------------------------------------
#
# `provider_mock()` returns an OpenAI-compatible provider served by an in-
# process R mock server (no Python, no API key), so tests and demos run fully
# offline. `provider_replay()` re-serves the LLM responses recorded in a JSONL
# trace (produced by `run(..., log_path = ...)`), giving deterministic replay.

# Registry of live mock-server processes, so they can all be stopped.
# Namespace bindings are locked, so mutable state lives in an environment.
.mock_servers <- new.env(parent = emptyenv())
.mock_state <- new.env(parent = emptyenv())
.mock_state$counter <- 0L

.normalize_mock_response <- function(x) {
  if (is.character(x) && length(x) == 1L) return(list(content = x))
  if (is.list(x)) {
    if (is.null(x$finish_reason)) x$finish_reason <- "stop"
    if (is.null(x$usage)) {
      x$usage <- list(prompt_tokens = 10, completion_tokens = 5, total_tokens = 15)
    }
    return(x)
  }
  stop("provider_mock(): each response must be a string or a list.")
}

.start_mock_server <- function(responses, mode) {
  cfg <- tempfile(pattern = "agentgraph_mock_", fileext = ".rds")
  ready <- tempfile(pattern = "agentgraph_mock_ready_", fileext = ".txt")
  out <- tempfile(pattern = "agentgraph_mock_out_")
  err <- tempfile(pattern = "agentgraph_mock_err_")
  saveRDS(list(mode = mode, responses = responses), cfg)

  script <- system.file("tools", "mock_server.R", package = "agentgraph")
  if (!nzchar(script)) {
    stop("agentgraph: mock_server.R missing from the installed package (reinstall agentgraph).")
  }
  rscript <- file.path(
    R.home("bin"),
    if (.Platform$OS.type == "windows") "Rscript.exe" else "Rscript"
  )

  proc <- processx::process$new(rscript, c(script, cfg, ready),
                                stdout = out, stderr = err, cleanup = TRUE)
  deadline <- Sys.time() + 30
  while (!file.exists(ready) && proc$is_alive() && Sys.time() < deadline) {
    Sys.sleep(0.05)
  }
  if (!file.exists(ready)) {
    err_text <- if (file.exists(err)) paste(readLines(err, warn = FALSE), collapse = "\n") else ""
    tryCatch(proc$kill(), error = function(e) NULL)
    stop("provider_mock(): mock server failed to start\n", err_text)
  }
  port <- suppressWarnings(as.integer(readLines(ready, warn = FALSE)[1L]))
  if (is.na(port)) {
    tryCatch(proc$kill(), error = function(e) NULL)
    stop("provider_mock(): mock server reported an invalid port.")
  }

  .mock_state$counter <- .mock_state$counter + 1L
  assign(paste0("m", .mock_state$counter), proc, envir = .mock_servers)
  port
}

#' Create an offline mock LLM provider
#'
#' Returns an OpenAI-compatible provider backed by a built-in mock server (no
#' Python, no API key, no network). Responses are scripted:
#'
#' - A named list maps input text -> response: each request's last user message
#'   is matched exactly against the names, falling back to a `"*"` entry, then
#'   to the first entry. E.g. `list("What is 2+2?" = "4", "*" = "I don't know")`.
#' - An unnamed list (or character vector) serves responses in order, repeating
#'   the last one.
#'
#' Each response may be a string (the assistant text) or a list with `content`,
#' `finish_reason`, `tool_calls` (`list(id, name, arguments)`), `usage`, `model`.
#' Stop all mock servers with [mock_stop_all()].
#'
#' @param responses A named or unnamed list of responses
#' @param model Model name reported by the mock
#' @return A provider configuration list
#' @export
provider_mock <- function(responses = list("*" = "I don't know"), model = "mock") {
  if (!requireNamespace("httpuv", quietly = TRUE)) {
    stop("provider_mock(): requires the 'httpuv' package.")
  }
  if (is.character(responses)) responses <- as.list(responses)
  if (!is.list(responses) || length(responses) == 0L) {
    stop("provider_mock(): `responses` must be a non-empty list or character vector.")
  }
  nm <- names(responses)
  mode <- if (is.null(nm) || all(!nzchar(nm))) "sequence" else "keyed"
  norm <- lapply(responses, .normalize_mock_response)
  if (identical(mode, "keyed")) names(norm) <- nm

  port <- .start_mock_server(norm, mode)
  provider_openai(api_key = "test", model = model,
                  base_url = paste0("http://127.0.0.1:", port),
                  max_retries = 0L)
}

#' Replay LLM responses recorded in a JSONL trace
#'
#' Reads a JSONL trace produced by [run()] with `log_path`, extracts the
#' `llm_response` events in order, and returns a mock provider that re-serves
#' them (no API calls). Lets a previously recorded session be replayed
#' deterministically in CI or benchmarks.
#'
#' @param trace_path Path to a JSONL trace file
#' @param model Model name reported by the replay provider
#' @return A provider configuration list
#' @export
provider_replay <- function(trace_path, model = "replay") {
  if (!is.character(trace_path) || length(trace_path) != 1L || !file.exists(trace_path)) {
    stop("provider_replay(): `trace_path` must be an existing trace file.")
  }
  lines <- readLines(trace_path, warn = FALSE)
  responses <- list()
  for (ln in lines) {
    if (!nzchar(ln)) next
    j <- tryCatch(jsonlite::fromJSON(ln, simplifyVector = FALSE),
                  error = function(e) NULL)
    if (is.null(j) || !identical(j$event, "llm_response")) next
    d <- j$data
    responses[[length(responses) + 1L]] <- list(
      content = if (is.null(d$content)) "" else d$content,
      finish_reason = if (is.null(d$finish_reason)) "stop" else d$finish_reason,
      tool_calls = d$tool_calls,
      usage = if (is.null(d$usage)) list(prompt_tokens = 0, completion_tokens = 0,
                                         total_tokens = 0) else d$usage,
      model = if (is.null(d$model)) "replay" else d$model
    )
  }
  if (length(responses) == 0L) {
    stop("provider_replay(): no llm_response events found in ", trace_path)
  }
  port <- .start_mock_server(responses, "sequence")
  provider_openai(api_key = "test", model = model,
                  base_url = paste0("http://127.0.0.1:", port),
                  max_retries = 0L)
}

#' Stop all mock/replay servers started this session
#'
#' @return `NULL`, invisibly
#' @export
mock_stop_all <- function() {
  ids <- ls(.mock_servers, all.names = TRUE)
  for (id in ids) {
    tryCatch(.mock_servers[[id]]$kill(), error = function(e) NULL)
    rm(list = id, envir = .mock_servers)
  }
  invisible(NULL)
}
