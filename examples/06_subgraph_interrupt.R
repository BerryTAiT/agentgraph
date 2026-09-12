# Example 6: Subgraphs + human-in-the-loop (interrupt / resume)
library(agentgraph)

# ---------------------------------------------------------------------------
# Subgraphs: embed a whole graph as a single node. The nested graph shares the
# parent state, so values set inside are visible after it returns.
# ---------------------------------------------------------------------------

# A reusable "review" subgraph: pauses for a human decision, then routes on it.
# (replace the interrupt node with an llm_node(provider, ...) to add a model.)
review <- state_graph(entry = "ask_reviewer") |>
  add_node("ask_reviewer", interrupt_node()) |>
  add_edge("ask_reviewer", "__end__")

# A "fact-check" subgraph that runs its own little workflow.
fact_check <- state_graph(entry = "check") |>
  add_node("check", interrupt_node()) |>
  add_edge("check", "__end__")

# Parent graph composes the two subgraphs as ordinary nodes.
pipeline <- state_graph(entry = "review") |>
  add_node("review", subgraph_node(review)) |>
  add_node("factcheck", subgraph_node(fact_check)) |>
  add_edge("review", "factcheck") |>
  add_edge("factcheck", "__end__")

# ---------------------------------------------------------------------------
# Run + human-in-the-loop: the graph pauses at each interrupt, hands state back
# to R, and waits for resume().
# ---------------------------------------------------------------------------
state <- run(pipeline, list(user_msg("Please review this draft.")))

# The outer graph paused on the FIRST subgraph's interrupt.
cat("Paused:", is_interrupted(state), "\n")

# Human approves, injecting a decision into the shared state, and we resume.
state <- resume(pipeline, state, inject = list(approved = TRUE))

# Paused again: now at the fact-check subgraph's interrupt.
cat("Paused again:", is_interrupted(state), "\n")

# Final resume runs to completion.
state <- resume(pipeline, state)
cat("Finished:", !is_interrupted(state), "\n")

# ---------------------------------------------------------------------------
# Plain top-level interrupt (no subgraph) is the simplest approval gate.
# ---------------------------------------------------------------------------
gate <- state_graph(entry = "approve") |>
  add_node("approve", interrupt_node()) |>
  add_edge("approve", "__end__")

s <- run(gate, list(user_msg("draft v1")))
stopifnot(is_interrupted(s))          # waits for a human
s <- resume(gate, s, inject = list(ok = TRUE))  # human says go
stopifnot(!is_interrupted(s))          # done
