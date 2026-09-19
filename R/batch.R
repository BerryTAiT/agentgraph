# Batch API --------------------------------------------------------------------
#
# Run a target (agent, graph, or function) over many inputs, either
# synchronously (batch()) or as an async background job (batch_submit() /
# batch_status() / batch_collect()). Sequential mode needs no extra
# dependencies; parallel (concurrency > 1) and async modes use mirai, which
# spawns separate R processes that each run the target independently.

.batch_answer <- function(res) {
  if (is.list(res) && !is.null(res$answer)) as.character(res$answer)[1]
  else as.character(res)[1]
}

.as_batch_state <- function(input) {
  if (is.character(input) && length(input) == 1L) {
    list(messages = list(user_msg(input)))
  } else if (is.list(input)) {
    input
  } else {
    stop("batch(): graph inputs must be a single string or a state list.")
  }
}

.validate_batch_args <- function(target, inputs, concurrency) {
  if (is.list(inputs) || is.character(inputs)) {
    if (length(inputs) == 0L) {
      stop("batch(): `inputs` must contain at least one input.")
    }
  } else {
    stop("batch(): `inputs` must be a character vector or a list.")
  }
  concurrency <- as.integer(concurrency)[1]
  if (is.na(concurrency) || concurrency < 1L) {
    stop("batch(): `concurrency` must be an integer >= 1.")
  }

  if (is_agent(target)) {
    if (any(vapply(as.list(inputs), function(x) !is.character(x) || length(x) != 1L, logical(1)))) {
      stop("batch(): agent targets require single-string inputs.")
    }
    kind <- "agent"
  } else if (is.list(target) && !is.null(target$entry_point) &&
             !is.null(target$nodes) && !is.null(target$edges)) {
    kind <- "graph"
  } else if (is.function(target)) {
    kind <- "function"
  } else {
    stop("batch(): `target` must be an agent, a graph (from state_graph()), or a function.")
  }
  list(kind = kind, concurrency = concurrency)
}

.batch_target_fn <- function(target, kind, dots) {
  if (identical(kind, "agent")) {
    function(input) {
      do.call(run_agent, c(list(agent = target, input = input), dots))$answer
    }
  } else if (identical(kind, "graph")) {
    function(input) {
      st <- do.call(run, c(list(graph = target, state = .as_batch_state(input)), dots))
      final_answer(st)
    }
  } else {
    function(input) .batch_answer(do.call(target, c(list(input), dots)))
  }
}

# Runs one input through `fn`, always returning a uniform row regardless of
# errors. Used directly in sequential mode and inside each daemon in
# parallel mode (so a worker error can never surface as a mirai error).
.batch_run_one <- function(fn, input) {
  t0 <- Sys.time()
  err <- NULL
  ans <- tryCatch(fn(input), error = function(e) { err <<- conditionMessage(e); NULL })
  elapsed <- as.numeric(difftime(Sys.time(), t0, units = "secs"))
  answer <- if (is.null(err)) .batch_answer(ans) else NA_character_
  list(answer = answer,
       error = if (is.null(err)) "" else err,
       elapsed = round(elapsed, 4))
}

#' Run a target over many inputs
#'
#' Executes `target` once per input and returns a data frame with one row per
#' input: `i`, `input`, `answer`, `error`, and `elapsed` (seconds). Errors on
#' individual inputs are contained — the row records the message and the run
#' continues.
#'
#' `target` may be:
#' - an agent (from [chat_agent()], [react_agent()], ...): each input must be
#'   a single string, passed to [run_agent()];
#' - a graph (from [state_graph()]): each input is either a single string
#'   (wrapped as a user message) or a full state list, passed to [run()];
#' - a function: called as `target(input, ...)`; its return value is used as
#'   the answer (a list with an `answer` element is unwrapped).
#'
#' With `concurrency = 1` (default) inputs are processed sequentially in the
#' current process. With `concurrency > 1` inputs are distributed over that
#' many mirai daemons (separate R processes; requires the mirai package).
#' Existing daemons you have already set are reused and left running;
#' otherwise batch() starts its own and tears them down afterwards. In
#' parallel mode the target is serialized to the daemons, so a function
#' target must be self-contained (reference only its arguments and installed
#' packages, not objects from your global environment).
#'
#' @param target An agent, a graph, or a function
#' @param inputs A character vector or list of inputs (length >= 1)
#' @param ... Extra arguments forwarded to the target on every input
#' @param concurrency Number of parallel workers (1 = sequential)
#' @param on_result Optional callback `function(row)` invoked with each
#'   result row (`list(i, input, answer, error, elapsed)`); in parallel mode
#'   rows are reported in input order once all are complete
#' @return A data frame of results (class `agentgraph_batch`)
#' @export
batch <- function(target, inputs, ..., concurrency = 1L, on_result = NULL) {
  spec <- .validate_batch_args(target, inputs, concurrency)
  if (!is.null(on_result) && !is.function(on_result)) {
    stop("batch(): `on_result` must be a function or NULL.")
  }
  dots <- list(...)
  fn <- .batch_target_fn(target, spec$kind, dots)
  inputs_list <- as.list(inputs)
  n <- length(inputs_list)

  rows <- vector("list", n)
  if (spec$concurrency == 1L) {
    for (i in seq_len(n)) rows[[i]] <- .batch_run_one(fn, inputs_list[[i]])
  } else {
    if (!requireNamespace("mirai", quietly = TRUE)) {
      stop("batch(): concurrency > 1 requires the mirai package (install it, or use concurrency = 1).")
    }
    worker <- function(.x) .batch_run_one(fn, .x)
    had_daemons <- tryCatch(mirai::status()$connections > 0, error = function(e) FALSE)
    if (!had_daemons) {
      mirai::daemons(spec$concurrency)
      on.exit(try(mirai::daemons(0), silent = TRUE), add = TRUE)
    }
    collected <- mirai::collect_mirai(mirai::mirai_map(inputs_list, worker))
    for (i in seq_len(n)) {
      r <- collected[[i]]
      rows[[i]] <- if (mirai::is_error_value(r)) {
        list(answer = NA_character_,
             error = paste("worker failed:", r$message),
             elapsed = 0)
      } else r
    }
  }

  answers <- vapply(rows, function(r) r$answer, character(1))
  errors <- vapply(rows, function(r) r$error, character(1))
  elapsed <- vapply(rows, function(r) r$elapsed, numeric(1))
  input_col <- if (is.list(inputs)) I(inputs_list) else inputs

  out <- data.frame(i = seq_len(n), input = input_col, answer = answers,
                    error = errors, elapsed = elapsed,
                    stringsAsFactors = FALSE)
  class(out) <- c("agentgraph_batch", "data.frame")
  attr(out, "concurrency") <- spec$concurrency

  if (!is.null(on_result)) {
    for (i in seq_len(n)) {
      on_result(list(i = i, input = inputs_list[[i]], answer = answers[[i]],
                     error = errors[[i]], elapsed = elapsed[[i]]))
    }
  }
  out
}

#' Submit a batch as an async background job
#'
#' Launches [batch()] in a background mirai process and returns immediately
#' with a job handle. Poll it with [batch_status()] and retrieve the results
#' with [batch_collect()]. Arguments are identical to [batch()] and are
#' validated eagerly, so an invalid job fails at submission time. Requires
#' the mirai package (even for `concurrency = 1` — the background evaluation
#' itself runs in a daemon).
#'
#' @param target An agent, a graph, or a function
#' @param inputs A character vector or list of inputs
#' @param ... Extra arguments forwarded to the target
#' @param concurrency Number of parallel workers (1 = sequential in the job)
#' @return A batch job (class `agentgraph_batch_job`)
#' @export
batch_submit <- function(target, inputs, ..., concurrency = 1L) {
  if (!requireNamespace("mirai", quietly = TRUE)) {
    stop("batch_submit(): requires the mirai package.")
  }
  spec <- .validate_batch_args(target, inputs, concurrency)
  # The job needs at least one daemon to run on. If none are set, start one
  # and leave it running (tearing it down would kill the in-flight job);
  # mirai daemons exit with the R session.
  if (tryCatch(mirai::status()$connections == 0, error = function(e) TRUE)) {
    mirai::daemons(1)
  }
  dots <- list(...)
  job_fn <- function() {
    do.call(batch, c(list(target = target, inputs = inputs,
                          concurrency = spec$concurrency), dots))
  }
  m <- mirai::mirai(.fn(), .args = list(.fn = job_fn))
  structure(
    list(mirai = m, inputs = inputs, concurrency = spec$concurrency,
         submitted = Sys.time()),
    class = "agentgraph_batch_job"
  )
}

#' Report the status of a batch job
#'
#' @param job A job from [batch_submit()]
#' @return "running", "complete", or "error"
#' @export
batch_status <- function(job) {
  if (!inherits(job, "agentgraph_batch_job")) {
    stop("batch_status(): `job` must come from batch_submit().")
  }
  if (mirai::unresolved(job$mirai)) {
    "running"
  } else if (mirai::is_error_value(job$mirai$data)) {
    "error"
  } else {
    "complete"
  }
}

#' Wait for and collect the results of a batch job
#'
#' Blocks until the job finishes (optionally up to `timeout` seconds) and
#' returns its [batch()] result data frame.
#'
#' @param job A job from [batch_submit()]
#' @param timeout Optional maximum seconds to wait; a job that is still
#'   running after the timeout is an error
#' @return The batch results data frame (class `agentgraph_batch`)
#' @export
batch_collect <- function(job, timeout = NULL) {
  if (!inherits(job, "agentgraph_batch_job")) {
    stop("batch_collect(): `job` must come from batch_submit().")
  }
  if (!is.null(timeout)) {
    timeout <- as.numeric(timeout)[1]
    if (is.na(timeout) || timeout <= 0) {
      stop("batch_collect(): `timeout` must be a positive number or NULL.")
    }
  }
  t0 <- Sys.time()
  while (mirai::unresolved(job$mirai)) {
    if (!is.null(timeout) && difftime(Sys.time(), t0, units = "secs") >= timeout) {
      stop("batch_collect(): job still running after ", timeout, " seconds.")
    }
    Sys.sleep(0.05)
  }
  d <- job$mirai$data
  if (mirai::is_error_value(d)) {
    stop("batch job failed: ", d$message)
  }
  d
}

#' Print a batch result
#'
#' @param x A batch result from [batch()]
#' @param ... Unused
#' @return `x`, invisibly
#' @export
print.agentgraph_batch <- function(x, ...) {
  n <- nrow(x)
  n_err <- sum(nzchar(x$error))
  cat(sprintf("agentgraph batch: %d input%s, %d error%s, %.3fs total (concurrency %d)\n",
              n, if (n == 1L) "" else "s",
              n_err, if (n_err == 1L) "" else "s",
              sum(x$elapsed), attr(x, "concurrency")))
  invisible(x)
}

#' Print a batch job
#'
#' @param x A job from [batch_submit()]
#' @param ... Unused
#' @return `x`, invisibly
#' @export
print.agentgraph_batch_job <- function(x, ...) {
  st <- tryCatch(batch_status(x), error = function(e) "unknown")
  cat(sprintf("agentgraph batch job: %d input%s, concurrency %d, status: %s\n",
              length(x$inputs), if (length(x$inputs) == 1L) "" else "s",
              x$concurrency, st))
  invisible(x)
}
