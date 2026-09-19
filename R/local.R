# Local-model (llama.cpp) support.
#
# Two layers are provided:
#   1. provider_local()   -> config for ANY local OpenAI-compatible server
#                            (llama.cpp's llama-server, LM Studio, vLLM, Ollama).
#   2. llama_server()     -> launch llama.cpp's `llama-server` binary from R,
#                            wait until it is listening, and return a ready
#                            provider plus a process handle you can stop.
#
# llama.cpp exposes an OpenAI-compatible HTTP API, so the existing C++ engine
# (OpenAIClient) talks to it with zero changes. Running a GGUF through
# llama-server keeps inference in native C++ (same engine the agent uses),
# which is faster and uses less memory than driving llama.cpp through Python.

#' Create a local OpenAI-compatible provider configuration
#'
#' Points the engine at any local server that speaks the OpenAI chat-completions
#' protocol: llama.cpp's `llama-server`, LM Studio, vLLM, Ollama, etc. Runs fully
#' offline with no API key.
#'
#' @param model Model name as served by the local server (e.g. "mistral-7b")
#' @param base_url Base URL of the local server
#' @param max_tokens Maximum tokens in response
#' @param temperature Sampling temperature
#' @param max_retries Retry transient HTTP failures (429/5xx); 0 disables
#' @param retry_base_delay_ms Initial backoff delay (ms), doubles each attempt
#' @param retry_max_delay_ms Upper bound on the backoff delay (ms)
#' @param requests_per_minute Token-bucket request cap; 0 disables rate limiting
#' @return A provider configuration list
#' @export
provider_local <- function(model = "local-model",
                           base_url = "http://127.0.0.1:8080/v1",
                           max_tokens = 4096,
                           temperature = 0.7,
                           max_retries = 3L,
                           retry_base_delay_ms = 500L,
                           retry_max_delay_ms = 8000L,
                           requests_per_minute = 0L) {
  list(
    name = "openai",
    api_key = "local",
    model = model,
    base_url = base_url,
    max_tokens = as.integer(max_tokens),
    temperature = temperature,
    max_retries = as.integer(max_retries),
    retry_base_delay_ms = as.integer(retry_base_delay_ms),
    retry_max_delay_ms = as.integer(retry_max_delay_ms),
    requests_per_minute = as.integer(requests_per_minute)
  )
}

# Internal: read a process log file, returning "" if it is absent/unreadable.
.llama_log_text <- function(path) {
  if (!file.exists(path)) return("")
  paste(readLines(path, warn = FALSE), collapse = "\n")
}

#' Launch a local llama.cpp server and return a ready provider
#'
#' Starts llama.cpp's `llama-server` binary against a GGUF model, waits until it
#' reports it is listening, and returns a handle containing a ready `provider`
#' (for `chat()` / `run()` / graph nodes) plus the underlying process so you can
#' stop it later with `llama_server_stop()`.
#'
#' @param model_path Path to a `.gguf` model file
#' @param binary Path to the `llama-server` executable; defaults to
#'   `llama-server` on `PATH`
#' @param host Interface to bind (default `127.0.0.1`)
#' @param port TCP port to bind (default `8080`)
#' @param n_ctx Context window size (optional; passed through if given)
#' @param n_gpu_layers GPU layers to offload; `NULL` leaves llama.cpp defaults
#' @param extra_args Additional command-line arguments passed verbatim
#' @param timeout Seconds to wait for the server to start listening
#' @return A list with `provider`, `process`, `host`, `port`, `model_path`
#' @export
llama_server <- function(model_path,
                         binary = Sys.getenv("LLAMA_SERVER", "llama-server"),
                         host = "127.0.0.1",
                         port = 8080L,
                         n_ctx = NULL,
                         n_gpu_layers = NULL,
                         extra_args = character(),
                         timeout = 60) {
  if (missing(model_path) || is.null(model_path) || !nzchar(model_path)) {
    stop("llama_server(): `model_path` is required (path to a .gguf file)")
  }
  if (!file.exists(model_path)) {
    stop("llama_server(): model file not found: ", model_path)
  }

  out_file <- tempfile(pattern = "agentgraph_llama_out_")
  err_file <- tempfile(pattern = "agentgraph_llama_err_")

  args <- c(
    "--model", model_path,
    "--host", host,
    "--port", as.character(as.integer(port))
  )
  if (!is.null(n_ctx))       args <- c(args, "--ctx-size", as.character(as.integer(n_ctx)))
  if (!is.null(n_gpu_layers)) args <- c(args, "--n-gpu-layers", as.character(as.integer(n_gpu_layers)))
  if (length(extra_args) > 0) args <- c(args, as.character(extra_args))

  p <- processx::process$new(
    binary,
    args,
    stdout = out_file,
    stderr = err_file,
    cleanup = TRUE
  )

  deadline <- Sys.time() + timeout
  listening <- FALSE
  while (p$is_alive() && Sys.time() < deadline) {
    logtext <- paste0(.llama_log_text(out_file), "\n", .llama_log_text(err_file))
    if (grepl("listening", logtext, ignore.case = TRUE)) {
      listening <- TRUE
      break
    }
    Sys.sleep(0.1)
  }

  if (!listening) {
    err_text <- .llama_log_text(err_file)
    if (!nzchar(err_text)) err_text <- .llama_log_text(out_file)
    tryCatch(p$kill(), error = function(e) NULL)
    stop("llama_server(): server did not report listening within ", timeout,
         "s. Ensure `llama-server` is installed and `model_path` is a valid GGUF.\n",
         err_text)
  }

  list(
    provider = provider_local(
      model = basename(model_path),
      base_url = sprintf("http://%s:%d/v1", host, as.integer(port))
    ),
    process = p,
    host = host,
    port = as.integer(port),
    model_path = model_path
  )
}

#' Stop a local llama.cpp server started by \code{llama_server()}
#'
#' @param server Handle returned by \code{llama_server()}
#' @return Invisibly \code{NULL}
#' @export
llama_server_stop <- function(server) {
  if (is.null(server) || is.null(server$process)) {
    return(invisible(NULL))
  }
  proc <- server$process
  if (!is.null(proc) && proc$is_alive()) {
    tryCatch(proc$kill(), error = function(e) NULL)
  }
  invisible(NULL)
}
