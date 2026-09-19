# Shared mock-server helpers for agentgraph tests.
#
# `R CMD check` runs tests from a temporary installed copy of the package, so
# mock scripts are located portably via testthat::test_path() rather than a
# hardcoded absolute path. Python mocks are used when `python` is on PATH;
# otherwise the relevant tests are skipped.

# Locate a mock file shipped under tests/testthat/mock/.
mock_file <- function(name) {
  testthat::test_path("mock", name)
}

python_available <- function() {
  nzchar(Sys.which("python"))
}

# Launch a Python mock server and wait until it reports a ready port.
# `middle_args` are the per-script positional arguments placed between the port
# range and the <ready_file> <request_log> pair (e.g. the scenario JSON path).
launch_py_mock <- function(script, middle_args, tmp) {
  testthat::skip_if_not(python_available(), "python not available on PATH")
  py <- Sys.which("python")
  ready_file <- file.path(tmp, "ready.txt")
  log_file   <- file.path(tmp, "requests.log")
  proc <- processx::process$new(
    py,
    args = c(mock_file(script), "18300", "18600", middle_args, ready_file, log_file),
    stdout = "|", stderr = "|"
  )
  port <- NULL
  for (i in 1:100) {
    if (file.exists(ready_file) && file.info(ready_file)$size > 0) {
      port <- as.integer(readLines(ready_file, warn = FALSE))
      break
    }
    if (!proc$is_alive()) break
    Sys.sleep(0.1)
  }
  if (is.null(port)) {
    err <- tryCatch(proc$read_error(), error = function(e) "")
    proc$kill()
    stop("mock server did not become ready: ", script, " ", err)
  }
  list(proc = proc, port = port, tmp = tmp, log = log_file)
}

stop_py_mock <- function(m) {
  if (!is.null(m$proc)) try(m$proc$kill(), silent = TRUE)
  unlink(m$tmp, recursive = TRUE)
  invisible(NULL)
}

# Start the standard OpenAI-compatible scripted mock with the given responses.
start_mock_llm <- function(responses) {
  tmp <- tempfile("mock"); dir.create(tmp)
  sf <- file.path(tmp, "scenario.json")
  writeLines(jsonlite::toJSON(responses, auto_unbox = TRUE), sf)
  launch_py_mock("mock_llm_server.py", sf, tmp)
}

# Start the raw-HTTP error mock (scripted status/body responses).
start_error_mock <- function(responses) {
  tmp <- tempfile("mock"); dir.create(tmp)
  sf <- file.path(tmp, "scenario.json")
  writeLines(jsonlite::toJSON(responses, auto_unbox = TRUE), sf)
  launch_py_mock("error_mock.py", sf, tmp)
}

# Start the latency mock (echoes system prompt after a fixed delay).
start_latent_mock <- function(delay = 0) {
  tmp <- tempfile("mock"); dir.create(tmp)
  launch_py_mock("latent_mock.py", as.character(delay), tmp)
}

# Start the SSE streaming mock (emits one delta chunk per token).
start_stream_mock <- function(tokens) {
  tmp <- tempfile("mock"); dir.create(tmp)
  tf <- file.path(tmp, "tokens.json")
  writeLines(jsonlite::toJSON(tokens, auto_unbox = TRUE), tf)
  launch_py_mock("stream_mock.py", tf, tmp)
}

# Start the voice mock (STT transcriptions + TTS synthesis).
start_voice_mock <- function() {
  tmp <- tempfile("mock"); dir.create(tmp)
  launch_py_mock("voice_mock.py", character(0), tmp)
}

# Start the fine-tuning mock (files + fine_tuning/jobs endpoints).
start_fine_tune_mock <- function() {
  tmp <- tempfile("mock"); dir.create(tmp)
  launch_py_mock("fine_tune_mock.py", character(0), tmp)
}

# Build an OpenAI-compatible provider pointed at a running mock.
mock_provider <- function(m, model = "mock-model") {
  agentgraph::provider_openai(
    api_key = "test", model = model,
    base_url = paste0("http://127.0.0.1:", m$port)
  )
}

# Extract the system prompt of each logged LLM request (identifies which node ran).
sys_prompts <- function(log_file) {
  lines <- readLines(log_file, warn = FALSE)
  sp <- vapply(lines, function(ln) {
    j <- jsonlite::fromJSON(ln, simplifyVector = FALSE)
    for (m in j$messages) if (identical(m$role, "system")) return(m$content)
    ""
  }, character(1))
  unname(sp)
}

# Read the whole request log into a single string (after a short settle delay).
read_log <- function(m, settle = 0.3) {
  Sys.sleep(settle)
  paste(readLines(file.path(m$tmp, "requests.log"), warn = FALSE), collapse = "\n")
}

# Capture the error message produced by an expression, or NULL if it succeeds.
err_msg <- function(expr) {
  tryCatch({ force(expr); NULL }, error = function(e) conditionMessage(e))
}
