#' Send a single chat message to an LLM
#'
#' @param message The user message
#' @param provider A provider configuration
#' @param system_prompt Optional system prompt
#' @return The LLM response as a list
#' @export
chat <- function(message, provider, system_prompt = "") {
  messages <- list(user_msg(message))
  chat_native_cpp(
    provider = provider,
    messages_r = messages,
    system_prompt = system_prompt
  )
}

#' Send multiple chat messages to an LLM in parallel (native C++ threads)
#'
#' Each element of `messages` is itself a list of message objects. The
#' requests run concurrently on a C++ thread pool and return in input order.
#'
#' @param messages A list of message lists (one per request)
#' @param provider A provider configuration
#' @param n_threads Number of concurrent requests
#' @param system_prompt Optional system prompt
#' @return A list of LLM responses, one per input request
#' @export
chat_parallel <- function(messages, provider, n_threads = 4L, system_prompt = "") {
  chat_parallel_cpp(
    provider = provider,
    messages_list = messages,
    system_prompt = system_prompt,
    n_threads = as.integer(n_threads)
  )
}

#' Run a graph with initial state
#'
#' @param graph A graph object (from state_graph())
#' @param state Initial state as a list of messages
#' @param tools List of tool definitions
#' @param state_data Named list of additional state data
#' @param n_threads Thread pool size for parallel nodes (0 = auto)
#' @param on_token Optional callback invoked for each streamed token
#' @param on_event Optional callback invoked for engine lifecycle events
#'   (node_start, node_end, llm_start, llm_end, tool_call, tool_result,
#'   iteration, parallel_start, parallel_end, interrupt, complete). Signature:
#'   \code{function(event, data)} where \code{data} is a named list.
#' @param resume_from Internal: node ID to resume execution from (used by resume())
#' @param checkpoint_path Optional file path. When set, the graph state is
#'   persisted (atomically) to this file after every node and on interrupt, so
#'   a crashed run can be resumed with checkpoint_resume().
#' @param log_path Optional file path. When set, every engine event
#'   (node/LLM/tool lifecycle) is appended as one JSON line, giving a durable
#'   trace of token usage, latency, and tool calls.
#' @param max_total_tokens Kill switch: abort the run once cumulative token
#'   usage across all LLM calls exceeds this (0 = unlimited).
#' @param max_time_sec Kill switch: abort the run once wall-clock seconds
#'   elapsed exceed this (0 = unlimited).
#' @param max_cost_usd Kill switch: abort the run once the estimated cost
#'   exceeds this USD amount (0 = unlimited; requires per-provider pricing
#'   set via [provider_pricing()]).
#' @param tenant Optional [tenant()] to enforce rate limits / usage caps and
#'   record an audit line for this run.
#' @return The final state after graph execution
#' @export
run <- function(graph, state, tools = list(), state_data = list(),
                n_threads = 0L, on_token = NULL, resume_from = "",
                on_event = NULL, checkpoint_path = NULL, log_path = NULL,
                max_total_tokens = 0L, max_time_sec = 0, max_cost_usd = 0,
                tenant = NULL) {
  if (is.null(checkpoint_path)) checkpoint_path <- ""
  if (is.null(log_path)) log_path <- ""
  messages <- list()
  if (is.list(state) && !is.null(names(state))) {
    if ("messages" %in% names(state)) {
      messages <- state$messages
      state_data <- state[names(state) != "messages"]
    }
  } else if (is.list(state)) {
    messages <- state
  }

  graph_config <- list(
    entry_point = graph$entry_point,
    nodes = graph$nodes,
    edges = graph$edges,
    max_iterations = graph$max_iterations
  )

  # Custom R tools run in an isolated tool-server process so the C++ engine
  # never calls back into R from worker threads (safe under parallel fan-out).
  server <- NULL
  if (length(tools) > 0) server <- .start_tool_server(tools)
  on.exit(.stop_tool_server(server), add = TRUE)

  # Wrap the R on_event function so that the JSON payload string from C++ is
  # parsed into a named list before it reaches the user callback.
  # Always collect metrics from engine events (and call the user's callback).
  on_event_wrapped <- .wrap_event_callback(on_event)

  tenant_before <- NULL
  if (!is.null(tenant)) {
    if (!inherits(tenant, "agentgraph_tenant")) {
      stop("run(): `tenant` must be created by tenant() or NULL.")
    }
    .tenant_check(tenant)
    tenant_before <- agentgraph_usage()
  }

  result <- run_graph_cpp(
    graph_config = graph_config,
    state_data = state_data,
    messages_r = messages,
    tools_r = tools,
    n_threads = as.integer(n_threads),
    on_token = on_token,
    resume_from = resume_from,
    tool_server_port = if (is.null(server)) 0L else server$port,
    tool_server_token = if (is.null(server)) "" else server$token,
    on_event = on_event_wrapped,
    checkpoint_path = checkpoint_path,
    log_path = log_path,
    max_total_tokens = as.integer(max_total_tokens),
    max_time_sec = as.numeric(max_time_sec),
    max_cost_usd = as.numeric(max_cost_usd)
  )

  if (!is.null(tenant)) {
    tenant_after <- agentgraph_usage()
    .tenant_record(tenant,
                   tenant_after$total_tokens - tenant_before$total_tokens,
                   tenant_after$cost_usd - tenant_before$cost_usd)
  }

  .metrics_write()
  result
}

#' Load a crash-durable checkpoint written by run()/resume()
#'
#' Reads a checkpoint file created with \code{checkpoint_path} and returns a
#' list with two elements: \code{state} (same shape as a run() return value:
#' \code{data} plus \code{messages}) and \code{resume_node} (the next node that
#' would run; empty or \code{"__end__"} means the run had already completed).
#'
#' @param checkpoint_path Path to a checkpoint file written by the engine
#' @return A list with `state` and `resume_node`
#' @export
checkpoint_load <- function(checkpoint_path) {
  checkpoint_load_cpp(checkpoint_path)
}

#' Resume a graph from a crash-durable checkpoint
#'
#' Loads a checkpoint file, then continues execution from the node where the
#' previous run stopped. If the checkpoint marks the run as already complete
#' (\code{resume_node} empty or \code{"__end__"}), the saved state is returned
#' unchanged. When \code{checkpoint_path} is reused, execution keeps appending
#' checkpoints so the run remains crash-safe across resumptions.
#'
#' @param graph The same graph object passed to the original run()
#' @param checkpoint_path Path to a checkpoint file written by the engine
#' @param tools List of tool definitions
#' @param inject Named list of state values to set/override before resuming
#' @param n_threads Thread pool size for parallel nodes (0 = auto)
#' @param on_token Optional callback invoked for each streamed token
#' @param on_event Optional callback invoked for engine lifecycle events
#' @param log_path Optional file path to append a JSONL trace to while resuming
#' @param max_total_tokens Kill switch on cumulative token usage (0 = unlimited)
#' @param max_time_sec Kill switch on wall-clock seconds (0 = unlimited)
#' @param max_cost_usd Kill switch on estimated USD cost (0 = unlimited)
#' @return The final state after resuming
#' @export
checkpoint_resume <- function(graph, checkpoint_path, tools = list(),
                              inject = list(), n_threads = 0L, on_token = NULL,
                              on_event = NULL, log_path = NULL,
                              max_total_tokens = 0L, max_time_sec = 0,
                              max_cost_usd = 0) {
  if (is.null(log_path)) log_path <- ""
  loaded <- checkpoint_load_cpp(checkpoint_path)
  state <- loaded$state
  resume_node <- loaded$resume_node

  # A completed run has no further node to resume.
  if (is.null(resume_node) || nchar(resume_node) == 0 ||
      identical(resume_node, "__end__")) {
    return(state)
  }

  data <- state$data
  if (is.null(data)) data <- list()

  # Clear the in-memory interrupt markers so the resumed run starts cleanly.
  # The actual resume target is `resume_node`, passed below as `resume_from`
  # (a subgraph resume still re-enters via `__resume_path__`, which we keep).
  data[["__interrupted__"]] <- NULL
  data[["__resume_node__"]] <- NULL

  for (k in names(inject)) {
    data[[k]] <- jsonlite::toJSON(inject[[k]], auto_unbox = TRUE)
  }

  messages <- state$messages
  if (is.null(messages)) messages <- list()

  graph_config <- list(
    entry_point = graph$entry_point,
    nodes = graph$nodes,
    edges = graph$edges,
    max_iterations = graph$max_iterations
  )

  server <- NULL
  if (length(tools) > 0) server <- .start_tool_server(tools)
  on.exit(.stop_tool_server(server), add = TRUE)

  on_event_wrapped <- .wrap_event_callback(on_event)

  res <- run_graph_cpp(
    graph_config = graph_config,
    state_data = data,
    messages_r = messages,
    tools_r = tools,
    n_threads = as.integer(n_threads),
    on_token = on_token,
    resume_from = resume_node,
    tool_server_port = if (is.null(server)) 0L else server$port,
    tool_server_token = if (is.null(server)) "" else server$token,
    on_event = on_event_wrapped,
    checkpoint_path = checkpoint_path,
    log_path = log_path,
    max_total_tokens = as.integer(max_total_tokens),
    max_time_sec = as.numeric(max_time_sec),
    max_cost_usd = as.numeric(max_cost_usd)
  )
  .metrics_write()
  res
}

#' Test whether a returned state was paused by an interrupt node
#'
#' @param state A state list returned by run() or resume()
#' @return TRUE if the graph paused at an interrupt node
#' @export
is_interrupted <- function(state) {
  d <- state$data
  if (is.null(d)) return(FALSE)
  flag <- d[["__interrupted__"]]
  if (is.null(flag)) return(FALSE)
  isTRUE(tryCatch(jsonlite::fromJSON(flag), error = function(e) FALSE))
}

#' Resume a graph that paused at an interrupt node
#'
#' Takes the state returned by a previous interrupted run() (or resume()) and
#' continues execution from the interrupt node's outgoing edge. The full state
#' (messages + data) is round-tripped back into the C++ engine, so any values
#' set before the pause are preserved.
#'
#' @param graph The same graph object passed to run()
#' @param interrupted_state The state list returned by the interrupted run()
#' @param tools List of tool definitions
#' @param inject Named list of state values to set/override before resuming
#'   (e.g. \code{list(approved = TRUE)}); values are JSON-encoded automatically
#' @param n_threads Thread pool size for parallel nodes (0 = auto)
#' @param on_token Optional callback invoked for each streamed token
#' @param on_event Optional callback invoked for engine lifecycle events
#' @param checkpoint_path Optional file path to persist state to while resuming
#' @param log_path Optional file path to append a JSONL trace to while resuming
#' @param max_total_tokens Kill switch on cumulative token usage (0 = unlimited)
#' @param max_time_sec Kill switch on wall-clock seconds (0 = unlimited)
#' @param max_cost_usd Kill switch on estimated USD cost (0 = unlimited)
#' @return The final state after resuming (may itself be interrupted again)
#' @export
resume <- function(graph, interrupted_state, tools = list(),
                   inject = list(), n_threads = 0L, on_token = NULL,
                   on_event = NULL, checkpoint_path = NULL, log_path = NULL,
                   max_total_tokens = 0L, max_time_sec = 0, max_cost_usd = 0) {
  if (is.null(checkpoint_path)) checkpoint_path <- ""
  if (is.null(log_path)) log_path <- ""
  data <- interrupted_state$data
  if (is.null(data) || is.null(data[["__resume_node__"]])) {
    stop("resume(): the provided state is not an interrupted state (no __resume_node__).")
  }

  resume_node <- jsonlite::fromJSON(data[["__resume_node__"]])

  # Inject / override state values before resuming. Values are JSON-encoded to
  # match the JSON-string round-trip used by the C++ state store.
  for (k in names(inject)) {
    data[[k]] <- jsonlite::toJSON(inject[[k]], auto_unbox = TRUE)
  }

  # Clear the interrupt markers so the resumed run starts cleanly.
  data[["__interrupted__"]] <- NULL
  data[["__resume_node__"]] <- NULL

  messages <- interrupted_state$messages
  if (is.null(messages)) messages <- list()

  graph_config <- list(
    entry_point = graph$entry_point,
    nodes = graph$nodes,
    edges = graph$edges,
    max_iterations = graph$max_iterations
  )

  server <- NULL
  if (length(tools) > 0) server <- .start_tool_server(tools)
  on.exit(.stop_tool_server(server), add = TRUE)

  on_event_wrapped <- .wrap_event_callback(on_event)

  res <- run_graph_cpp(
    graph_config = graph_config,
    state_data = data,
    messages_r = messages,
    tools_r = tools,
    n_threads = as.integer(n_threads),
    on_token = on_token,
    resume_from = resume_node,
    tool_server_port = if (is.null(server)) 0L else server$port,
    tool_server_token = if (is.null(server)) "" else server$token,
    on_event = on_event_wrapped,
    checkpoint_path = checkpoint_path,
    log_path = log_path,
    max_total_tokens = as.integer(max_total_tokens),
    max_time_sec = as.numeric(max_time_sec),
    max_cost_usd = as.numeric(max_cost_usd)
  )
  .metrics_write()
  res
}

#' Run a graph with streaming output
#'
#' @param graph A graph object
#' @param state Initial state
#' @param tools List of tool definitions
#' @param on_token Callback function for each streamed token
#' @param on_event Callback function for engine lifecycle events
#' @param state_data Named list of additional state data
#' @param n_threads Thread pool size for parallel nodes (0 = auto)
#' @param checkpoint_path Optional file path to persist state to while running
#' @param log_path Optional file path to append a JSONL trace to while running
#' @param max_total_tokens Kill switch on cumulative token usage (0 = unlimited)
#' @param max_time_sec Kill switch on wall-clock seconds (0 = unlimited)
#' @param max_cost_usd Kill switch on estimated USD cost (0 = unlimited)
#' @return The final state
#' @export
stream <- function(graph, state, tools = list(),
                   on_token = NULL, on_event = NULL,
                   state_data = list(), n_threads = 0L,
                   checkpoint_path = NULL, log_path = NULL,
                   max_total_tokens = 0L, max_time_sec = 0, max_cost_usd = 0) {
  run(graph, state, tools, state_data,
      n_threads = n_threads, on_token = on_token, on_event = on_event,
      checkpoint_path = checkpoint_path, log_path = log_path,
      max_total_tokens = max_total_tokens, max_time_sec = max_time_sec,
      max_cost_usd = max_cost_usd)
}
