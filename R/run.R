# Internal: convert a message list to the OpenAI chat-completions format
.message_to_openai <- function(msg) {
  out <- list(role = msg$role)

  tool_calls <- msg$tool_calls
  if (!is.null(tool_calls) && length(tool_calls) > 0) {
    out$content <- if (is.null(msg$content) || nchar(msg$content) == 0) NULL else msg$content
    out$tool_calls <- lapply(tool_calls, function(tc) {
      list(
        id = tc$id,
        type = "function",
        `function` = list(
          name = tc$name,
          arguments = if (is.character(tc$arguments)) tc$arguments
                     else jsonlite::toJSON(tc$arguments, auto_unbox = TRUE)
        )
      )
    })
  } else if (!is.null(msg$tool_call_id) && nchar(msg$tool_call_id) > 0) {
    out$content <- msg$content
    out$tool_call_id <- msg$tool_call_id
  } else {
    out$content <- msg$content
  }

  out
}

# Internal: convert a tool schema list to the OpenAI format
.tool_to_openai <- function(t) {
  params <- t$parameters
  if (is.character(params)) {
    params <- jsonlite::fromJSON(params, simplifyVector = FALSE)
  }
  list(
    type = "function",
    `function` = list(
      name = t$name,
      description = if (is.null(t$description)) "" else t$description,
      parameters = params
    )
  )
}

# Internal: the LLM callback invoked by the C++ engine.
# This is the single point where an actual HTTP request to the LLM API happens.
.llm_call <- function(provider, messages, tools, system_prompt) {
  # Build request body in OpenAI chat-completions format
  msgs <- list()
  if (!is.null(system_prompt) && nchar(system_prompt) > 0) {
    msgs[[length(msgs) + 1]] <- list(role = "system", content = system_prompt)
  }
  for (m in messages) {
    msgs[[length(msgs) + 1]] <- .message_to_openai(m)
  }

  body <- list(
    model = provider$model,
    messages = msgs,
    max_tokens = if (is.null(provider$max_tokens)) 4096 else provider$max_tokens,
    temperature = if (is.null(provider$temperature)) 0.7 else provider$temperature,
    stream = FALSE
  )

  if (length(tools) > 0) {
    body$tools <- lapply(tools, .tool_to_openai)
  }

  url <- paste0(provider$base_url, "/chat/completions")
  headers <- c(
    "Content-Type" = "application/json",
    "Authorization" = paste("Bearer", provider$api_key)
  )

  resp <- curl::curl_fetch_memory(
    url,
    handle = curl::new_handle(
      customrequest = "POST",
      postfields = jsonlite::toJSON(body, auto_unbox = TRUE, null = "null"),
      httpheader = headers,
      connecttimeout = 30,
      timeout = 300
    )
  )

  if (resp$status_code != 200) {
    stop("LLM API error (", resp$status_code, "): ",
         rawToChar(resp$content))
  }

  parsed <- jsonlite::fromJSON(rawToChar(resp$content), simplifyVector = FALSE)

  if (!is.null(parsed$error)) {
    stop("LLM API error: ", parsed$error$message)
  }

  choice <- parsed$choices[[1]]
  msg <- choice$message

  content <- msg$content
  if (is.null(content)) content <- ""

  finish_reason <- choice$finish_reason
  if (is.null(finish_reason)) finish_reason <- "stop"

  tool_calls <- list()
  if (!is.null(msg$tool_calls)) {
    tool_calls <- lapply(msg$tool_calls, function(tc) {
      fn <- tc[["function"]]
      list(
        id = tc$id,
        name = fn$name,
        arguments = fn$arguments
      )
    })
  }

  list(
    content = content,
    finish_reason = finish_reason,
    model = if (is.null(parsed$model)) provider$model else parsed$model,
    tool_calls = tool_calls,
    prompt_tokens = if (is.null(parsed$usage$prompt_tokens)) 0 else parsed$usage$prompt_tokens,
    completion_tokens = if (is.null(parsed$usage$completion_tokens)) 0 else parsed$usage$completion_tokens,
    total_tokens = if (is.null(parsed$usage$total_tokens)) 0 else parsed$usage$total_tokens
  )
}

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
    api_key = provider$api_key,
    model = provider$model,
    base_url = provider$base_url,
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
    api_key = provider$api_key,
    model = provider$model,
    base_url = provider$base_url,
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
#' @param resume_from Internal: node ID to resume execution from (used by resume())
#' @return The final state after graph execution
#' @export
run <- function(graph, state, tools = list(), state_data = list(),
                n_threads = 0L, on_token = NULL, resume_from = "") {
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

  result <- run_graph_cpp(
    graph_config = graph_config,
    state_data = state_data,
    messages_r = messages,
    tools_r = tools,
    n_threads = as.integer(n_threads),
    on_token = on_token,
    resume_from = resume_from,
    tool_server_port = if (is.null(server)) 0L else server$port
  )

  result
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
#' @return The final state after resuming (may itself be interrupted again)
#' @export
resume <- function(graph, interrupted_state, tools = list(),
                   inject = list(), n_threads = 0L, on_token = NULL) {
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

  run_graph_cpp(
    graph_config = graph_config,
    state_data = data,
    messages_r = messages,
    tools_r = tools,
    n_threads = as.integer(n_threads),
    on_token = on_token,
    resume_from = resume_node,
    tool_server_port = if (is.null(server)) 0L else server$port
  )
}

#' Run a graph with streaming output
#'
#' @param graph A graph object
#' @param state Initial state
#' @param tools List of tool definitions
#' @param on_token Callback function for each streamed token
#' @param on_event Callback function for graph events (reserved)
#' @param state_data Named list of additional state data
#' @param n_threads Thread pool size for parallel nodes (0 = auto)
#' @return The final state
#' @export
stream <- function(graph, state, tools = list(),
                   on_token = NULL, on_event = NULL,
                   state_data = list(), n_threads = 0L) {
  run(graph, state, tools, state_data,
      n_threads = n_threads, on_token = on_token)
}
