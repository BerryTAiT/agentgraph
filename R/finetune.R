# Fine-tuning integration -----------------------------------------------------
#
# fine_tune() uploads a JSONL training set and creates an OpenAI-compatible
# fine-tuning job, returning the job ID; fine_tune_status()/fine_tune_list()/
# fine_tune_cancel() manage it. Examples may come from feedback_dataset(),
# eval_dataset(), or any input/output pairs. HTTP uses curl (Suggests).

.pick_output_col <- function(df) {
  for (col in c("output", "expected", "correction")) {
    if (col %in% names(df)) return(df[[col]])
  }
  stop("fine_tune(): `examples` needs an 'input' column plus 'output'/'expected'/'correction'.")
}

# Convert examples to a character vector of OpenAI chat JSONL lines. Accepts:
#   - a data.frame (or named list) with `input` + `output`/`expected`/`correction`
#   - a list of `list(input, output)` pairs
.to_finetune_jsonl <- function(examples) {
  is_vector_form <- (is.data.frame(examples)) ||
    (is.list(examples) && !is.null(examples$input) && is.atomic(examples$input))
  if (is_vector_form) {
    inp <- examples$input
    out <- .pick_output_col(examples)
    if (length(inp) != length(out)) {
      stop("fine_tune(): `input` and output columns must have the same length.")
    }
    pairs <- lapply(seq_along(inp), function(i) {
      list(input = inp[i], output = out[i])
    })
  } else if (is.list(examples)) {
    pairs <- examples
  } else {
    stop("fine_tune(): `examples` must be a data.frame or a list of input/output pairs.")
  }
  vapply(pairs, function(p) {
    if (is.null(p$input) || is.null(p$output)) {
      stop("fine_tune(): each example needs `input` and `output`.")
    }
    msgs <- list(
      list(role = "user", content = as.character(p$input)[1L]),
      list(role = "assistant", content = as.character(p$output)[1L])
    )
    jsonlite::toJSON(list(messages = msgs), auto_unbox = TRUE)
  }, character(1L))
}

.fine_tune_handle <- function(provider, post = FALSE) {
  h <- curl::new_handle(useragent = "agentgraph")
  if (is.character(provider$api_key) && nzchar(provider$api_key)) {
    curl::handle_setopt(h, httpheader = paste0("Authorization: Bearer ", provider$api_key))
  }
  if (post) curl::handle_setopt(h, customrequest = "POST")
  h
}

#' Create an OpenAI-compatible fine-tuning job
#'
#' Converts `examples` to a JSONL chat training set, uploads it, and creates a
#' fine-tuning job on `model`. Returns the job ID; poll [fine_tune_status()]
#' until `status == "succeeded"` and use its `fine_tuned_model` as the model in
#' a provider.
#'
#' @param provider A provider configuration (its `base_url` + `api_key` are used)
#' @param examples A data.frame (with `input` + `output`/`expected`/`correction`)
#'   or a list of `list(input, output)` pairs
#' @param model Base model to fine-tune
#' @param suffix Optional job suffix
#' @param n_epochs Optional number of epochs
#' @return The fine-tuning job ID (a string)
#' @export
fine_tune <- function(provider, examples, model = "gpt-4o-mini",
                      suffix = NULL, n_epochs = NULL) {
  if (!requireNamespace("curl", quietly = TRUE)) {
    stop("fine_tune(): requires the 'curl' package.")
  }
  jsonl <- .to_finetune_jsonl(examples)
  tmp <- tempfile(fileext = ".jsonl")
  writeLines(jsonl, tmp)
  base <- sub("/+$", "", provider$base_url)

  # upload the training file
  h <- .fine_tune_handle(provider, post = TRUE)
  curl::handle_setform(h, purpose = "fine-tune", file = curl::form_file(tmp))
  r <- curl::curl_fetch_memory(paste0(base, "/files"), handle = h)
  if (r$status_code >= 400L) stop("fine_tune(): file upload HTTP ", r$status_code)
  file_id <- jsonlite::fromJSON(rawToChar(r$content), simplifyVector = FALSE)$id

  # create the job
  body <- list(model = model, training_file = file_id)
  if (!is.null(suffix)) body$suffix <- suffix
  if (!is.null(n_epochs)) body$hyperparameters <- list(n_epochs = as.integer(n_epochs))
  h2 <- .fine_tune_handle(provider, post = TRUE)
  curl::handle_setopt(h2, postfields = jsonlite::toJSON(body, auto_unbox = TRUE),
                      httpheader = c("Content-Type: application/json",
                                     if (is.character(provider$api_key) && nzchar(provider$api_key))
                                       paste0("Authorization: Bearer ", provider$api_key)
                                     else "Content-Type: application/json"))
  r2 <- curl::curl_fetch_memory(paste0(base, "/fine_tuning/jobs"), handle = h2)
  if (r2$status_code >= 400L) stop("fine_tune(): job creation HTTP ", r2$status_code)
  jsonlite::fromJSON(rawToChar(r2$content), simplifyVector = FALSE)$id
}

#' Get a fine-tuning job's status
#'
#' @param job_id A job ID from [fine_tune()]
#' @param provider The provider configuration
#' @return The job object (a list; `fine_tuned_model` is set once `status`
#'   is "succeeded")
#' @export
fine_tune_status <- function(job_id, provider) {
  if (!requireNamespace("curl", quietly = TRUE)) {
    stop("fine_tune_status(): requires the 'curl' package.")
  }
  base <- sub("/+$", "", provider$base_url)
  h <- .fine_tune_handle(provider)
  r <- curl::curl_fetch_memory(paste0(base, "/fine_tuning/jobs/", job_id), handle = h)
  if (r$status_code >= 400L) stop("fine_tune_status(): HTTP ", r$status_code)
  jsonlite::fromJSON(rawToChar(r$content), simplifyVector = FALSE)
}

#' List fine-tuning jobs
#'
#' @param provider The provider configuration
#' @return A list of job objects (the API's `data` array)
#' @export
fine_tune_list <- function(provider) {
  if (!requireNamespace("curl", quietly = TRUE)) {
    stop("fine_tune_list(): requires the 'curl' package.")
  }
  base <- sub("/+$", "", provider$base_url)
  h <- .fine_tune_handle(provider)
  r <- curl::curl_fetch_memory(paste0(base, "/fine_tuning/jobs"), handle = h)
  if (r$status_code >= 400L) stop("fine_tune_list(): HTTP ", r$status_code)
  jsonlite::fromJSON(rawToChar(r$content), simplifyVector = FALSE)$data
}

#' Cancel a fine-tuning job
#'
#' @param job_id A job ID from [fine_tune()]
#' @param provider The provider configuration
#' @return The updated job object
#' @export
fine_tune_cancel <- function(job_id, provider) {
  if (!requireNamespace("curl", quietly = TRUE)) {
    stop("fine_tune_cancel(): requires the 'curl' package.")
  }
  base <- sub("/+$", "", provider$base_url)
  h <- .fine_tune_handle(provider, post = TRUE)
  r <- curl::curl_fetch_memory(paste0(base, "/fine_tuning/jobs/", job_id, "/cancel"),
                               handle = h)
  if (r$status_code >= 400L) stop("fine_tune_cancel(): HTTP ", r$status_code)
  jsonlite::fromJSON(rawToChar(r$content), simplifyVector = FALSE)
}

#' Wait for a fine-tuning job to finish
#'
#' Polls [fine_tune_status()] until the job reaches a terminal state
#' ("succeeded", "failed", "cancelled") or `timeout` elapses, and returns the
#' final status.
#'
#' @param job_id A job ID
#' @param provider The provider configuration
#' @param timeout Maximum seconds to wait (default 600)
#' @param poll_interval Seconds between polls (default 5)
#' @return The final job object
#' @export
fine_tune_wait <- function(job_id, provider, timeout = 600, poll_interval = 5) {
  deadline <- Sys.time() + timeout
  repeat {
    st <- fine_tune_status(job_id, provider)
    if (st$status %in% c("succeeded", "failed", "cancelled")) return(st)
    if (Sys.time() >= deadline) stop("fine_tune_wait(): timed out after ", timeout, "s")
    Sys.sleep(poll_interval)
  }
}
