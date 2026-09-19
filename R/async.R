# Long-running / async jobs ---------------------------------------------------
#
# run_async() runs an agent, graph, or function in a background mirai process
# and returns a job ID. Poll with job_status(), block for the result with
# job_result(), or cancel with job_cancel(). Jobs live in an in-memory registry
# for the R session (mirai daemons exit with the session).

# Session-scoped job registry: job ID -> list(mirai, submitted).
.agentgraph_jobs <- new.env(parent = emptyenv())

.new_job_id <- function() {
  paste0("job_", paste0(sample(c(0:9, letters[1:6]), 12L, replace = TRUE),
                        collapse = ""))
}

.async_kind <- function(target) {
  if (is_agent(target)) return("agent")
  if (is.list(target) && !is.null(target$entry_point) &&
      !is.null(target$nodes) && !is.null(target$edges)) return("graph")
  if (is.function(target)) return("function")
  stop("run_async(): `target` must be an agent, a graph, or a function.")
}

.async_state <- function(input) {
  if (is.character(input) && length(input) == 1L) {
    list(messages = list(user_msg(input)))
  } else if (is.list(input)) {
    input
  } else {
    stop("run_async(): graph inputs must be a single string or a state list.")
  }
}

.async_target_fn <- function(target, kind, dots) {
  if (identical(kind, "agent")) {
    function(input) do.call(run_agent, c(list(agent = target, input = input), dots))
  } else if (identical(kind, "graph")) {
    function(input) do.call(run, c(list(graph = target, state = .async_state(input)), dots))
  } else {
    function(input) do.call(target, c(list(input), dots))
  }
}

.job_id <- function(job) {
  if (inherits(job, "agentgraph_job")) return(job$id)
  if (is.character(job) && length(job) == 1L && !is.na(job)) return(job)
  stop("job must be a job ID string or a run_async() result.")
}

.get_job <- function(id) {
  entry <- .agentgraph_jobs[[id]]
  if (is.null(entry)) stop("job not found: ", id)
  entry
}

#' Run a target as an async background job
#'
#' Launches `target` in a background mirai process and returns immediately with
#' a job ID. Poll it with [job_status()], retrieve the result with
#' [job_result()], or cancel with [job_cancel()]. Requires the mirai package.
#'
#' `target` may be an agent (each `input` a single string), a graph (each
#' `input` a single string or a state list), or a function (`target(input, ...)`).
#' For agent/graph targets the full result (answer + state, or the state) is
#' returned by [job_result()]; for function targets the function's return value.
#'
#' @param target An agent, a graph, or a function
#' @param input The input for the target
#' @param ... Extra arguments forwarded to the target
#' @return A job handle (class `agentgraph_job`) with a `$id`
#' @export
run_async <- function(target, input, ...) {
  if (!requireNamespace("mirai", quietly = TRUE)) {
    stop("run_async(): requires the mirai package.")
  }
  kind <- .async_kind(target)
  if (identical(kind, "agent") &&
      (!is.character(input) || length(input) != 1L || is.na(input))) {
    stop("run_async(): agent targets require a single-string input.")
  }
  if (identical(kind, "graph") &&
      !(is.character(input) && length(input) == 1L) && !is.list(input)) {
    stop("run_async(): graph inputs must be a single string or a state list.")
  }

  dots <- list(...)
  fn <- .async_target_fn(target, kind, dots)

  # The job needs at least one daemon to run on; leave it running (mirai
  # daemons exit with the R session).
  if (tryCatch(mirai::status()$connections == 0, error = function(e) TRUE)) {
    mirai::daemons(1)
  }

  id <- .new_job_id()
  job_fn <- function() {
    tryCatch(fn(input), error = function(e) list(.job_error = conditionMessage(e)))
  }
  m <- mirai::mirai(.fn(), .args = list(.fn = job_fn))
  .agentgraph_jobs[[id]] <- list(mirai = m, submitted = Sys.time())
  structure(list(id = id), class = "agentgraph_job")
}

#' Report the status of an async job
#'
#' @param job A job ID or [run_async()] result
#' @return "running", "done", or "failed"
#' @export
job_status <- function(job) {
  m <- .get_job(.job_id(job))$mirai
  if (mirai::unresolved(m)) return("running")
  d <- m$data
  if (mirai::is_error_value(d)) return("failed")
  if (is.list(d) && !is.null(d$.job_error)) return("failed")
  "done"
}

#' Wait for and collect an async job's result
#'
#' Blocks until the job finishes (optionally up to `timeout` seconds) and
#' returns its result; a job that errored raises an error.
#'
#' @param job A job ID or [run_async()] result
#' @param timeout Optional maximum seconds to wait; a still-running job raises
#'   an error (the job itself keeps running)
#' @return The job's result
#' @export
job_result <- function(job, timeout = NULL) {
  m <- .get_job(.job_id(job))$mirai
  if (!is.null(timeout)) {
    timeout <- as.numeric(timeout)[1]
    if (is.na(timeout) || timeout <= 0) {
      stop("job_result(): `timeout` must be a positive number or NULL.")
    }
  }
  t0 <- Sys.time()
  while (mirai::unresolved(m)) {
    if (!is.null(timeout) && difftime(Sys.time(), t0, units = "secs") >= timeout) {
      stop("job_result(): job still running after ", timeout, " seconds.")
    }
    Sys.sleep(0.05)
  }
  d <- m$data
  if (mirai::is_error_value(d)) stop("job failed: ", d$message)
  if (is.list(d) && !is.null(d$.job_error)) stop("job failed: ", d$.job_error)
  d
}

#' Cancel a running async job
#'
#' Best-effort cancellation of an unresolved job (mirai may already be
#' executing the target).
#'
#' @param job A job ID or [run_async()] result
#' @return `NULL`, invisibly
#' @export
job_cancel <- function(job) {
  id <- .job_id(job)
  entry <- .get_job(id)
  if (mirai::unresolved(entry$mirai)) {
    try(mirai::stop_mirai(entry$mirai), silent = TRUE)
  }
  invisible(NULL)
}

#' Print an async job
#'
#' @param x A job from [run_async()]
#' @param ... Unused
#' @return `x`, invisibly
#' @export
print.agentgraph_job <- function(x, ...) {
  st <- tryCatch(job_status(x), error = function(e) "unknown")
  cat(sprintf("agentgraph job: %s [%s]\n", x$id, st))
  invisible(x)
}
