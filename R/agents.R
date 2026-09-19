# Pre-built agent patterns -------------------------------------------------
#
# Ready-made agent constructors built on top of the graph primitives
# (state_graph / add_node / add_edge / add_conditional_edge / route_on) and the
# node constructors (llm_node / tool_node). Each constructor returns an "agent"
# object: a list carrying a composed `graph` plus the `tools` it needs, runnable
# through run_agent(). router_agent() is an R-level orchestrator and carries a
# `run` closure instead of a single graph.
#
# Every pattern is pure R (no C++ changes), so adding them requires only a
# roxygenise() + reinstall, never a rebuild of the DLL.

# Internal helpers -----------------------------------------------------------

new_agent <- function(graph = NULL, tools = list(), run_fn = NULL, description = "") {
  structure(
    list(graph = graph, tools = tools, run_fn = run_fn, description = description),
    class = "agentgraph_agent"
  )
}

#' Test whether an object is an agent
#'
#' @param x An object
#' @return `TRUE` if `x` is an agent object (built by [chat_agent()],
#'   [react_agent()], [plan_execute_agent()], etc.), `FALSE` otherwise.
#' @export
is_agent <- function(x) {
  inherits(x, "agentgraph_agent")
}

# The final answer is the last non-empty assistant message in the state.
final_answer <- function(state) {
  msgs <- state$messages
  if (is.null(msgs) || length(msgs) == 0L) return("")
  for (i in rev(seq_along(msgs))) {
    m <- msgs[[i]]
    if (identical(m$role, "assistant") && is.character(m$content) && nzchar(m$content)) {
      return(m$content)
    }
  }
  ""
}

# Single-turn conversational agent ------------------------------------------

#' Create a single-turn conversational agent
#'
#' The simplest agent: one LLM node that answers the user's input directly,
#' with no tools and no loop.
#'
#' @param provider A provider configuration (from [provider_openai()], etc.)
#' @param system_prompt Optional system prompt for the agent
#' @return An agent object (run with [run_agent()])
#' @export
chat_agent <- function(provider, system_prompt = "") {
  graph <- state_graph(entry = "agent") |>
    add_node("agent", llm_node(provider = provider, system_prompt = system_prompt))
  new_agent(graph = graph, tools = list(),
            description = "single-turn conversational agent")
}

# ReAct tool-calling agent --------------------------------------------------

#' Create a ReAct (reason + act) tool-calling agent
#'
#' The canonical agent loop: the LLM either calls a tool or finishes; when it
#' calls tools they run and the results loop back to the LLM until it produces
#' a final answer.
#'
#' @param provider A provider configuration
#' @param tools A list of tool definitions (from [tool()])
#' @param system_prompt Optional system prompt
#' @param max_iterations Safety cap on loop iterations
#' @return An agent object (run with [run_agent()])
#' @export
react_agent <- function(provider, tools = list(), system_prompt = "",
                        max_iterations = 25L) {
  if (length(tools) > 0L) {
    ok <- vapply(tools, function(t) {
      is.list(t) && !is.null(t$name) && nzchar(t$name)
    }, logical(1))
    if (any(!ok)) {
      stop("react_agent(): every element of `tools` must be a tool definition with a non-empty `name`.")
    }
  }
  tool_names <- vapply(tools, function(t) t$name, character(1))

  graph <- state_graph(entry = "agent", max_iterations = max_iterations) |>
    add_node("agent", llm_node(provider = provider, system_prompt = system_prompt,
                               tools = tool_names)) |>
    add_node("tools", tool_node()) |>
    add_conditional_edge("agent", route_on(
      field = "has_tool_calls",
      rules = c("true" = "tools", "false" = "__end__")
    )) |>
    add_edge("tools", "agent")

  new_agent(graph = graph, tools = tools,
            description = "ReAct tool-calling agent")
}

# Plan-and-execute agent ----------------------------------------------------

#' Create a plan-and-execute agent
#'
#' A planner LLM first produces a step-by-step plan (as an assistant message),
#' then an executor LLM reads that plan and produces the final answer. Both
#' share the same message history, so the plan flows into the executor as
#' context automatically.
#'
#' @param provider A provider configuration
#' @param system_prompt Optional system prompt for the planner
#' @param executor_system_prompt Optional system prompt for the executor
#' @return An agent object (run with [run_agent()])
#' @export
plan_execute_agent <- function(provider, system_prompt = "",
                               executor_system_prompt = "") {
  planner_prompt <- if (nzchar(system_prompt)) system_prompt else
    "You are a planner. Produce a concise step-by-step plan to answer the user's request."
  executor_prompt <- if (nzchar(executor_system_prompt)) executor_system_prompt else
    "You are an executor. Using the plan above, produce the final answer to the user's request."

  graph <- state_graph(entry = "planner") |>
    add_node("planner", llm_node(provider = provider, system_prompt = planner_prompt)) |>
    add_node("executor", llm_node(provider = provider, system_prompt = executor_prompt)) |>
    add_edge("planner", "executor") |>
    add_edge("executor", "__end__")

  new_agent(graph = graph, tools = list(),
            description = "plan-and-execute agent")
}

# Reflection agent ----------------------------------------------------------

#' Create a reflection (generate-critique-revise) agent
#'
#' A draft LLM produces an initial answer, then a critic LLM flags its flaws,
#' then a reviser LLM improves it. This critique-revise cycle repeats
#' \code{rounds} times (default 1), producing a refined final answer.
#'
#' @param provider A provider configuration
#' @param rounds Number of critique-revise rounds (>= 1)
#' @param system_prompt Optional system prompt for the draft generator
#' @param critic_system_prompt Optional system prompt for the critic
#' @param reviser_system_prompt Optional system prompt for the reviser
#' @return An agent object (run with [run_agent()])
#' @export
reflection_agent <- function(provider, rounds = 1L, system_prompt = "",
                             critic_system_prompt = "",
                             reviser_system_prompt = "") {
  rounds <- as.integer(rounds)
  if (is.na(rounds) || rounds < 1L) {
    stop("reflection_agent(): `rounds` must be an integer >= 1.")
  }

  draft_prompt <- if (nzchar(system_prompt)) system_prompt else
    "You are an assistant. Answer the user's request."
  critic_prompt <- if (nzchar(critic_system_prompt)) critic_system_prompt else
    "You are a critic. Identify flaws or missing details in the latest draft."
  reviser_prompt <- if (nzchar(reviser_system_prompt)) reviser_system_prompt else
    "You are an editor. Revise the draft to address the critique."

  graph <- state_graph(entry = "draft") |>
    add_node("draft", llm_node(provider = provider, system_prompt = draft_prompt))

  prev <- "draft"
  for (i in seq_len(rounds)) {
    critic_id  <- paste0("critic_", i)
    reviser_id <- paste0("revise_", i)
    graph <- graph |>
      add_node(critic_id, llm_node(provider = provider, system_prompt = critic_prompt)) |>
      add_node(reviser_id, llm_node(provider = provider, system_prompt = reviser_prompt)) |>
      add_edge(prev, critic_id) |>
      add_edge(critic_id, reviser_id)
    prev <- reviser_id
  }
  graph <- add_edge(graph, prev, "__end__")

  new_agent(graph = graph, tools = list(),
            description = "reflection (generate-critique-revise) agent")
}

# Router agent --------------------------------------------------------------

#' Create a router agent that dispatches to sub-agents
#'
#' A classifier LLM categorizes the user's request into one of the named
#' \code{routes}, then the corresponding sub-agent handles it. Each route is an
#' agent (built with [chat_agent()], [react_agent()], etc.). The classifier is
#' instructed to reply with exactly one route name.
#'
#' @param provider A provider configuration (used for classification)
#' @param routes A named list of agents to dispatch to
#' @param system_prompt Optional custom classification prompt
#' @param default Optional route name used when the classifier reply is unknown
#' @return An agent object (run with [run_agent()])
#' @export
router_agent <- function(provider, routes, system_prompt = "", default = NULL) {
  if (!is.list(routes) || length(routes) == 0L || is.null(names(routes)) ||
      any(!nzchar(names(routes)))) {
    stop("router_agent(): `routes` must be a named list of agents.")
  }
  if (any(!vapply(routes, is_agent, logical(1)))) {
    stop("router_agent(): every element of `routes` must be an agent built with a *_agent() constructor.")
  }
  keys <- names(routes)

  classify_prompt <- if (nzchar(system_prompt)) system_prompt else paste0(
    "You are a router. Classify the user's request into exactly one of these ",
    "categories and reply with only that single category name and nothing else: ",
    paste(keys, collapse = ", "), "."
  )

  run_fn <- function(input, ...) {
    cls <- chat(input, provider = provider, system_prompt = classify_prompt)
    route <- trimws(cls$content)
    if (!route %in% keys) {
      if (!is.null(default) && default %in% keys) {
        route <- default
      } else {
        stop("router_agent(): classifier returned an unknown route: ", route)
      }
    }
    run_agent(routes[[route]], input, ...)
  }

  new_agent(run_fn = run_fn, tools = list(),
            description = "router agent dispatching to sub-agents")
}

# Run an agent --------------------------------------------------------------

#' Run an agent on a single user input
#'
#' Runs the agent's graph (or, for a router agent, its orchestration closure)
#' with the given input as a single user message and returns a list with two
#' elements: \code{answer} (the final assistant text) and \code{state} (the raw
#' run result: \code{messages} plus \code{data}).
#'
#' @param agent An agent object created by a \code{*_agent()} constructor
#' @param input The user input string
#' @param ... Extra arguments forwarded to [run()] (e.g. \code{on_token},
#'   \code{on_event}, \code{n_threads}, \code{checkpoint_path}, \code{log_path})
#' @return A list with `answer` and `state`
#' @export
run_agent <- function(agent, input, ...) {
  if (!is_agent(agent)) {
    stop("run_agent(): `agent` must be created by a *_agent() constructor.")
  }
  if (!is.null(agent$run_fn)) {
    return(agent$run_fn(input, ...))
  }
  state <- run(agent$graph,
               state = list(messages = list(user_msg(input))),
               tools = agent$tools, ...)
  list(answer = final_answer(state), state = state)
}
