# Example 7: Live console monitor (requires a real API key)
#
# Run this in an interactive R session (Positron / RStudio). `monitor_run()`
# paints a live panel showing LLM connection status, thread-pool size, current
# node, per-node timings, and a rolling event log while the graph executes.
library(agentgraph)

# Point at your provider. For a DeepSeek-compatible endpoint use e.g.:
#   provider_openai(api_key = "sk-...", model = "deepseek-v4-flash",
#                   base_url = "https://api.mstech.ai/v1")
provider <- provider_openai(model = Sys.getenv("AGENTGRAPH_MODEL", "gpt-4o"))

graph <- state_graph(entry = "agent") |>
  add_node("agent", llm_node(provider,
    system_prompt = "You are a concise, helpful assistant.")) |>
  add_edge("agent", "__end__")

result <- monitor_run(
  graph,
  state = list(messages = list(user_msg(
    "List three benefits of graph-based agent orchestration."))),
  n_threads = 0L          # 0 = auto (all logical cores)
)

cat("\nFinal answer:\n", tail(result$messages, 1)[[1]]$content, "\n")
