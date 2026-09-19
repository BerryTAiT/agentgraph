#=====================================================================
# debate_synthesis :: a multi-agent debate & synthesis workflow
#
# A STANDALONE example project built ON TOP of the `agentgraph`
# framework. It exists to stress-test the framework under realistic use:
#
#   parallelism - parallel_node() fans a research question out to several
#                 specialist "debater" agents that run concurrently on the
#                 C++ thread pool
#   shared state- every debater appends its position to ONE shared message
#                 history, then a synthesizer node merges them
#   tools       - the lead agent is wired to the built-in web_search tool
#                 so claims can be grounded
#   routing     - a conditional edge decides tool-round-trip vs fan-out
#   evaluation  - evaluate() scores the final synthesis against criteria
#   checkpoint  - checkpoint_path lets a run pause and resume
#   guardrails  - max_total_tokens / max_time_sec abort over-budget runs
#   streams     - on_token/on_event trace execution live
#
# Usage:
#   Rscript run_debate.R                        # deterministic mock run
#   Rscript run_debate.R --live --topic="..."   # real provider + topic
#=====================================================================

library(agentgraph)

## ---- graph builder ----------------------------------------------------------
#' Build the debate/synthesis state graph.
#'
#'   (entry: lead --web_search) -> (lead_tools -> loop) -> (fan_out parallel)
#'       +--- debater_pro   \
#'       +--- debater_con    +--> (synthesize) -> __end__
#'       +--- debater_neutral/
#'
#' @param provider  an agentgraph provider (provider_openai(),
#'                  provider_mock(), provider_ollama(), ...)
#' @param topic     the proposition to debate
#' @param lead_system  system prompt for the entry agent (NULL = default)
#' @param debater_systems  named list; each element is one concurrent
#'                         debater's system prompt (name -> node id suffix)
#' @param synthesizer_system  system prompt for the final verdict node
#' @return an `agentgraph` graph object
build_debate_graph <- function(provider, topic,
                               lead_system = NULL,
                               debater_systems = NULL,
                               synthesizer_system = NULL,
                               use_tools = TRUE) {

  if (is.null(debater_systems)) {
    debater_systems <- list(
      pro   = paste0('You argue STRONGLY FOR the proposition: "', topic,
                     '". Give 3 concrete reasons.'),
      con   = paste0('You argue STRONGLY AGAINST the proposition: "', topic,
                     '". Give 3 concrete reasons.'),
      neutral = paste0('Provide a BALANCED view on the proposition: "', topic,
                       '". Give 3 key considerations.')
    )
  }
  if (is.null(lead_system)) {
    lead_system <- paste0(
      'You are the debate coordinator for the proposition: "', topic,
      '". If useful, use web_search to gather a fact, then state the',
      ' proposition clearly and hand off. Keep it to one short paragraph.')
  }
  if (is.null(synthesizer_system)) {
    synthesizer_system <- paste(
      "You are the final synthesizer. You are given a debate transcript",
      "with positions FOR, AGAINST, and NEUTRAL. Produce a concise, fair",
      "verdict that weighs the strongest claims on each side and ends with",
      "one clear overall conclusion.")
  }

  fan_targets <- paste0("debater_", names(debater_systems))

  g <- state_graph(entry = "lead")
  if (use_tools) {
    g <- add_node(g, "lead", llm_node(
      provider = provider,
      system_prompt = lead_system,
      tools = "web_search"
    ))
    g <- add_node(g, "lead_tools", tool_node())
    g <- add_conditional_edge(g, "lead", route_on(
      field = "has_tool_calls",
      rules = c("true" = "lead_tools", "false" = "fan_out"),
      default = "fan_out"
    ))
    g <- add_edge(g, "lead_tools", "lead")
  } else {
    g <- add_node(g, "lead", llm_node(
      provider = provider,
      system_prompt = lead_system
    ))
    g <- add_edge(g, "lead", "fan_out")
  }
  g <- add_node(g, "fan_out", parallel_node(fan_targets))

  for (id in names(debater_systems)) {
    nid <- paste0("debater_", id)
    g <- add_node(g, nid, llm_node(provider = provider,
                                   system_prompt = debater_systems[[id]]))
    g <- add_edge(g, nid, "synthesize")
  }

  g <- add_node(g, "synthesize",
                llm_node(provider = provider, system_prompt = synthesizer_system))
  g <- add_edge(g, "fan_out", "synthesize")
  g <- add_edge(g, "synthesize", "__end__")
  g
}

## ---- run helper --------------------------------------------------------------
#' Run the debate graph, tracing events, and return final state.
#' @param graph       graph from build_debate_graph()
#' @param topic       the proposition to debate
#' @param checkpoint  optional path for checkpoint()-able resume
#' @param on_event    optional event trace callback
#' @param max_tokens  budget guard (0 = off)
#' @param max_seconds time guard (0 = off)
run_debate <- function(graph, topic, checkpoint = NULL, on_event = NULL,
                       max_tokens = 0L, max_seconds = 0) {
  run(
    graph,
    state = list(messages = list(user_msg(topic))),
    n_threads = 4L,
    on_token = NULL,
    on_event = on_event,
    checkpoint_path = checkpoint,
    max_total_tokens = max_tokens,
    max_time_sec = max_seconds
  )
}

## ---- answer extractor (used by evaluate()) ----------------------------------
#' Produce just the final synthesis text for a topic. This is the "target"
#' that evaluate() can score from a small dataset.
debate_answer <- function(provider, topic) {
  g <- build_debate_graph(provider, topic)
  st <- run_debate(g, topic)
  as <- Filter(function(m) m$role == "assistant", st$messages)
  if (length(as) == 0L) return("")
  tail(as, 1)[[1]]$content
}

## ---- CLI ---------------------------------------------------------------------
main <- function(argv = commandArgs(trailingOnly = TRUE)) {
  live     <- "--live" %in% argv
  deepseek <- "--deepseek" %in% argv
  doEval   <- "--eval" %in% argv
  top <- grep("^--topic=", argv, value = TRUE)
  topic <- if (length(top)) sub("^--topic=", "", top[1])
           else "Should public transport be free?"

  cat("== debate_synthesis ==\n")
  cat("topic:", topic, "\n")

  provider <- if (deepseek) {
    key <- Sys.getenv("DEEPSEEK_API_KEY", "")
    if (!nzchar(key)) {
      stop("--deepseek requires DEEPSEEK_API_KEY env var ",
           "(set it in your session, e.g. $env:DEEPSEEK_API_KEY='sk-...' before running).")
    }
    provider_openai(api_key = key, model = "deepseek-v4-flash",
                    base_url = "https://api.deepseek.com")
  } else if (live) {
    provider_openai(model = "gpt-4o")
  } else {
    # Sequence mode: each successive LLM call gets a DIFFERENT canned reply.
    # Because the 3 debaters run concurrently, a distinct answer per position
    # proves the fan-out really wrote 3 independent turns into the shared
    # message history (rather than one turn being broadcast to all).
    provider_mock(responses = c(
      "I am the coordinator. I will open the debate and then hand off to the three panelists.",
      "I argue FOR the proposition. Reason one, reason two, reason three.",
      "I argue AGAINST the proposition. Objection one, objection two, objection three.",
      "I take a NEUTRAL stance. Consideration one, consideration two, consideration three.",
      "Verdict: weighing the arguments for and against, the balanced conclusion is..."
    ))
  }

  # DeepSeek's flash model has no web_search tool; disable tool routing for it.
  g <- build_debate_graph(provider, topic, use_tools = !deepseek)
  cat("graph : nodes =", length(g$nodes),
      ", edges =", length(g$edges),
      ", fan-out targets =", length(g$nodes[["fan_out"]]$sub_node_ids), "\n")

  trace <- function(event, data) {
    if (event %in% c("node_start", "parallel_end", "complete")) {
      cat(sprintf("  [%s] %s\n", event,
                  if (!is.null(data$node_id)) data$node_id else ""))
    }
  }

  st <- run_debate(g, topic, on_event = trace)

  cat("\n---- assistant turns ----\n")
  n <- 0L
  for (r in Filter(function(rr) rr$role == "assistant", st$messages)) {
    cat(sprintf("[%2d] %s\n", n <- n + 1L, substr(r$content, 1, 64)))
  }

  if (doEval) {
    cat("\n---- evaluation (mock) ----\n")
    ds <- eval_dataset(
      c("Should public transport be free?",
        "Should social media be age-restricted?")
    )
    ev <- evaluate(
      function(input) debate_answer(provider, input),
      dataset = ds,
      evaluators = list(
        eval_contains(needles = c("for", "against", "verdict"), all = TRUE)
      )
    )
    print(ev)
  }

  invisible(st)
}

if (sys.nframe() == 0) {
  if (!interactive()) main()
}