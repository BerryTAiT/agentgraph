# Example 5: Streaming token output (requires a real API key)
library(agentgraph)

provider <- provider_openai(model = "gpt-4o")

graph <- state_graph(entry = "agent") |>
  add_node("agent", llm_node(provider,
    system_prompt = "You are a helpful assistant.")) |>
  add_edge("agent", "__end__")

# Tokens print one-by-one as the model generates them
result <- stream(
  graph,
  state = list(messages = list(user_msg("Explain recursion in one sentence."))),
  on_token = function(token) {
    cat(token)
    flush.console()
  }
)

cat("\n\nDone. Final answer:\n", tail(result$messages, 1)[[1]]$content, "\n")
