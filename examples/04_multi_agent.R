# Example 4: Multi-agent parallel fan-out (requires a real API key)
library(agentgraph)

provider <- provider_openai(model = "gpt-4o")

# Three specialized agents run concurrently, then merge results
graph <- state_graph(entry = "fan_out") |>
  add_node("fan_out", parallel_node(c("researcher", "critic", "writer"))) |>
  add_node("researcher", llm_node(provider,
    system_prompt = "You are a researcher. List 3 key facts.")) |>
  add_node("critic", llm_node(provider,
    system_prompt = "You are a critic. Point out weaknesses.")) |>
  add_node("writer", llm_node(provider,
    system_prompt = "You are a writer. Write a one-line summary.")) |>
  add_edge("fan_out", "__end__")

result <- run(
  graph,
  state = list(messages = list(user_msg("Explain quantum computing."))),
  n_threads = 3
)

# Each agent's response was appended to the shared message history
assistant_msgs <- Filter(function(m) m$role == "assistant", result$messages)
for (m in assistant_msgs) {
  cat("---\n", m$content, "\n")
}
