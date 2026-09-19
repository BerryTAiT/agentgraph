# Live console monitoring for agentgraph ------------------------------------
#
# `monitor_run()` runs a graph exactly like `run()` but paints a live,
# ANSI-updating status panel while the C++ engine executes. It shows:
#   * live LLM API connection status (idle / connecting / connected / error)
#   * how many worker threads the engine thread pool is using
#   * current node + iteration
#   * per-node wall-clock timings and the last LLM call duration
#   * a rolling event log of engine lifecycle events
#
# The panel is redrawn in place using ANSI cursor-up + clear-line sequences,
# which work in Positron's terminal, Windows Terminal, and the RStudio console.
# Set `live = FALSE` (or run non-interactively) to fall back to a plain
# one-line-per-event log.

# --- ANSI helpers -----------------------------------------------------------

.ag_col <- function(code, x) paste0("\033[", code, "m", x, "\033[0m")
.ag_paint <- function(env, code, x) {
  if (isTRUE(env$color)) .ag_col(code, x) else x
}
.ag_red    <- function(env, x) .ag_paint(env, "31", x)
.ag_green  <- function(env, x) .ag_paint(env, "32", x)
.ag_yellow <- function(env, x) .ag_paint(env, "33", x)
.ag_blue   <- function(env, x) .ag_paint(env, "34", x)
.ag_mag    <- function(env, x) .ag_paint(env, "35", x)
.ag_cyan   <- function(env, x) .ag_paint(env, "36", x)
.ag_bold   <- function(env, x) .ag_paint(env, "1", x)
.ag_dim    <- function(env, x) .ag_paint(env, "2", x)

.ag_dur <- function(ms) {
  if (is.null(ms) || length(ms) == 0 || is.na(ms)) return("--")
  ms <- as.numeric(ms)
  if (ms < 1000) return(sprintf("%.0f ms", ms))
  if (ms < 60000) return(sprintf("%.2f s", ms / 1000))
  sprintf("%.1f min", ms / 60000)
}

.ag_get <- function(data, key, default = NA) {
  if (is.list(data) && key %in% names(data)) return(data[[key]])
  default
}

# Effective thread-pool size the C++ engine will use.
.ag_threads <- function(n_threads) {
  n_threads <- suppressWarnings(as.integer(n_threads))
  if (length(n_threads) == 0 || is.na(n_threads) || n_threads <= 0) {
    cores <- tryCatch(
      parallel::detectCores(logical = TRUE),
      error = function(e) NA_integer_)
    if (is.na(cores) || length(cores) == 0) {
      cores <- suppressWarnings(as.integer(Sys.getenv("NUMBER_OF_PROCESSORS", "1")))
    }
    return(if (is.na(cores) || cores < 1) 1L else as.integer(cores))
  }
  n_threads
}

.ag_ts <- function(t) format(t, "%H:%M:%S")

# --- Panel construction -----------------------------------------------------

.AG_PANEL_LINES <- 14L

.ag_status <- function(env) {
  switch(env$llm_status,
    idle       = .ag_dim(env, "IDLE"),
    connecting = .ag_yellow(env, "CONNECTING"),
    connected  = .ag_green(env, "CONNECTED"),
    error      = .ag_red(env, "ERROR"),
    .ag_dim(env, toupper(env$llm_status)))
}

.ag_panel <- function(env) {
  elapsed <- (proc.time() - env$start_time)[["elapsed"]]

  # Status line: LLM connection.
  llm_line <- sprintf(" LLM     : %s", .ag_status(env))
  if (nzchar(env$llm_model)) {
    llm_line <- paste0(llm_line, .ag_dim(env, sprintf("  (%s)", env$llm_model)))
  }
  if (!is.null(env$last_llm_ms)) {
    llm_line <- paste0(llm_line, .ag_dim(env, sprintf("  last %s", .ag_dur(env$last_llm_ms))))
  }

  # Thread line.
  parallel_part <- ""
  if (env$active_parallel > 0) {
    parallel_part <- .ag_yellow(env, sprintf("  |  active parallel: %d", env$active_parallel))
  }
  thread_line <- sprintf(" Threads : %s workers%s",
                         .ag_blue(env, as.character(env$threads)), parallel_part)

  # Node line.
  node_part <- if (nzchar(env$current_node)) env$current_node else "--"
  node_line <- sprintf(" Node    : %s  (iter %d)",
                       .ag_cyan(env, node_part), env$iteration)

  # Counters (tokens = usage-reported totals from llm_response events;
  # deltas = streamed SSE chunks, only set when on_token fires).
  counter_line <- sprintf(" Tokens  : %d%s  |  tool calls: %d",
                          env$tokens,
                          if (env$deltas > 0) sprintf(" (%d deltas)", env$deltas) else "",
                          env$tool_calls)

  # Elapsed.
  elapsed_line <- sprintf(" Elapsed : %.2f s", elapsed)

  # Last LLM call.
  if (is.null(env$last_llm_ms)) {
    lastllm_line <- sprintf(" Last LLM: %s", .ag_dim(env, "--"))
  } else {
    lastllm_line <- sprintf(" Last LLM: %s -> %s", env$last_llm_node,
                            .ag_dur(env$last_llm_ms))
  }

  # Per-node timings (mean per node seen so far).
  if (length(env$node_durations) == 0) {
    node_times_line <- sprintf(" Nodes   : %s", .ag_dim(env, "--"))
  } else {
    parts <- vapply(names(env$node_durations), function(id) {
      ms <- mean(env$node_durations[[id]], na.rm = TRUE)
      sprintf("%s %s", id, .ag_dur(ms))
    }, character(1))
    node_times_line <- paste0(" Nodes   : ", paste(parts, collapse = "  |  "))
  }

  # Streaming output preview (last line of streamed content, trimmed).
  out_text <- env$output
  if (nchar(out_text) > 60) out_text <- paste0(substr(out_text, nchar(out_text) - 59, nchar(out_text)), "")
  out_line <- sprintf(" Output  : %s", if (nzchar(out_text)) out_text else .ag_dim(env, "--"))

  # Rolling event log (last 3).
  ev <- env$events
  ev_lines <- vapply(ev, function(e) paste0("   ", e), character(1))
  while (length(ev_lines) < 3) ev_lines <- c(ev_lines, "")

  panel <- c(
    .ag_bold(env, " agentgraph console monitor"),
    .ag_dim(env, paste(rep("-", 40), collapse = "")),
    llm_line,
    thread_line,
    node_line,
    counter_line,
    elapsed_line,
    lastllm_line,
    node_times_line,
    out_line,
    .ag_dim(env, " events:"),
    ev_lines[[1]],
    ev_lines[[2]],
    ev_lines[[3]]
  )

  panel
}

.ag_render <- function(env) {
  lines <- .ag_panel(env)
  n <- env$panel_lines
  if (n > 0) {
    cat(paste0("\033[", n, "A"))
  }
  for (ln in lines) {
    cat("\033[2K", ln, "\n", sep = "")
  }
  env$panel_lines <- length(lines)
  utils::flush.console()
}

# --- Event handling ---------------------------------------------------------

.ag_push_event <- function(env, line) {
  env$events <- c(env$events, line)
  if (length(env$events) > 3) env$events <- tail(env$events, 3)
  if (!isTRUE(env$live)) cat(" ", line, "\n", sep = "")
  invisible(NULL)
}

.ag_handle <- function(env, event, data) {
  data <- if (is.list(data)) data else list()

  switch(event,
    iteration = {
      env$iteration <- .ag_get(data, "iteration", env$iteration)
      env$current_node <- .ag_get(data, "current_node", env$current_node)
    },
    node_start = {
      env$node_count <- env$node_count + 1L
      id <- .ag_get(data, "node_id", "?")
      type <- .ag_get(data, "type", "?")
      env$current_node <- id
      env$node_times[[id]] <- proc.time()[["elapsed"]]
      .ag_push_event(env, sprintf("%s %s %s (%s)",
        .ag_ts(Sys.time()), .ag_cyan(env, "node_start"), id, type))
    },
    node_end = {
      id <- .ag_get(data, "node_id", "?")
      status <- .ag_get(data, "status", "?")
      dur <- NA_real_
      start <- env$node_times[[id]]
      if (!is.null(start)) {
        dur <- (proc.time()[["elapsed"]] - start) * 1000
        env$node_durations[[id]] <- c(env$node_durations[[id]], dur)
      }
      tag <- if (identical(status, "success")) "node_end" else "node_end(ERR)"
      col <- if (identical(status, "success")) .ag_green else .ag_red
      .ag_push_event(env, sprintf("%s %s %s %s",
        .ag_ts(Sys.time()), col(env, tag), id, .ag_dur(dur)))
    },
    llm_start = {
      id <- .ag_get(data, "node_id", "?")
      env$llm_status <- "connecting"
      env$llm_model <- .ag_get(data, "model", "")
      env$last_llm_node <- id
      env$last_llm_ms <- NULL
      .ag_push_event(env, sprintf("%s %s %s %s",
        .ag_ts(Sys.time()), .ag_yellow(env, "llm_start"), id, env$llm_model))
    },
    llm_end = {
      id <- .ag_get(data, "node_id", "?")
      ok <- isTRUE(.ag_get(data, "success", FALSE))
      ms <- .ag_get(data, "duration_ms", NA_real_)
      env$llm_status <- if (ok) "connected" else "error"
      env$last_llm_ms <- ms
      env$llm_times[[id]] <- c(env$llm_times[[id]], ms)
      tag <- if (ok) "llm_end" else "llm_end(ERR)"
      col <- if (ok) .ag_green else .ag_red
      .ag_push_event(env, sprintf("%s %s %s %s",
        .ag_ts(Sys.time()), col(env, tag), id, .ag_dur(ms)))
    },
    tool_call = {
      env$tool_calls <- env$tool_calls + 1L
      name <- .ag_get(data, "name", "?")
      .ag_push_event(env, sprintf("%s %s %s",
        .ag_ts(Sys.time()), .ag_mag(env, "tool_call"), name))
    },
    tool_result = {
      name <- .ag_get(data, "name", "?")
      ok <- isTRUE(.ag_get(data, "success", FALSE))
      col <- if (ok) .ag_green else .ag_red
      .ag_push_event(env, sprintf("%s %s %s",
        .ag_ts(Sys.time()), col(env, "tool_result"), name))
    },
    llm_response = {
      u <- .ag_get(data, "usage", NULL)
      if (!is.null(u)) {
        t <- .ag_get(u, "total_tokens", 0)
        if (is.numeric(t)) env$tokens <- env$tokens + as.integer(t)
      }
    },
    parallel_start = {
      env$active_parallel <- .ag_get(data, "count", env$active_parallel)
      .ag_push_event(env, sprintf("%s %s %s",
        .ag_ts(Sys.time()), .ag_blue(env, "parallel_start"),
        paste0(env$active_parallel, " workers")))
    },
    parallel_end = {
      env$active_parallel <- 0L
      .ag_push_event(env, sprintf("%s %s %s",
        .ag_ts(Sys.time()), .ag_blue(env, "parallel_end"), ""))
    },
    interrupt = {
      .ag_push_event(env, sprintf("%s %s %s",
        .ag_ts(Sys.time()), .ag_yellow(env, "interrupt"),
        .ag_get(data, "node_id", "?")))
    },
    complete = {
      env$done <- TRUE
    }
  )

  if (isTRUE(env$live)) .ag_render(env)
  invisible(NULL)
}

# --- Public API -------------------------------------------------------------

#' Run a graph with a live console monitor
#'
#' Behaves exactly like \code{\link{run}} but renders a live status panel while
#' the graph executes, showing LLM API connection status, thread-pool size,
#' current node/iteration, per-node timings, and a rolling event log.
#'
#' @param graph A graph object (from \code{state_graph()})
#' @param state Initial state as a list of messages
#' @param tools List of tool definitions
#' @param state_data Named list of additional state data
#' @param n_threads Thread pool size for parallel nodes (0 = auto)
#' @param live When TRUE (the default in interactive sessions), paint a live
#'   ANSI-updating panel. Set FALSE for a plain one-line-per-event log.
#' @param color When TRUE, colourise the panel with ANSI codes.
#' @return The final state after graph execution (same as \code{run()})
#' @export
monitor_run <- function(graph, state, tools = list(), state_data = list(),
                        n_threads = 0L, live = interactive(), color = live) {
  env <- new.env(parent = emptyenv())
  env$threads <- .ag_threads(n_threads)
  env$color <- isTRUE(color)
  env$live <- isTRUE(live)
  env$llm_status <- "idle"
  env$llm_model <- ""
  env$current_node <- ""
  env$iteration <- 0L
  env$node_count <- 0L
  env$active_parallel <- 0L
  env$tool_calls <- 0L
  env$tokens <- 0L
  env$deltas <- 0L
  env$last_llm_ms <- NULL
  env$last_llm_node <- ""
  env$output <- ""
  env$node_times <- list()
  env$llm_times <- list()
  env$node_durations <- list()
  env$events <- character(0)
  env$start_time <- proc.time()
  env$panel_lines <- 0L
  env$done <- FALSE

  on_event <- function(event, data) .ag_handle(env, event, data)
  on_token <- function(tok) {
    env$deltas <- env$deltas + 1L
    env$output <- paste0(env$output, tok)
    # Keep only the trailing chunk so the panel preview stays bounded.
    if (nchar(env$output) > 200) {
      env$output <- substr(env$output, nchar(env$output) - 199, nchar(env$output))
    }
    if (isTRUE(env$live)) .ag_render(env)
  }

  # Print the header panel before execution starts.
  if (isTRUE(env$live)) .ag_render(env)

  result <- run(
    graph, state,
    tools = tools,
    state_data = state_data,
    n_threads = n_threads,
    on_token = on_token,
    on_event = on_event
  )

  if (isTRUE(env$live)) {
    .ag_render(env)
    cat("\n")
  } else {
    cat(.ag_dim(env, sprintf("[monitor] done: %d nodes, %d tool calls, %d tokens\n",
                             env$node_count, env$tool_calls, env$tokens)))
  }

  invisible(result)
}
