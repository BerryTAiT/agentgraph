# Example 2: Agent with tool calling (requires a real API key)
library(agentgraph)

provider <- provider_openai(model = "gpt-4o")

graph <- state_graph(entry = "agent") |>
  add_node("agent", llm_node(
    provider = provider,
    system_prompt = "You are a helpful assistant with a calculator tool.",
    tools = "calculator"
  )) |>
  add_node("tools", tool_node()) |>
  add_conditional_edge("agent", route_on(
    field = "has_tool_calls",
    rules = c("true" = "tools", "false" = "__end__")
  )) |>
  add_edge("tools", "agent")

result <- run(
  graph,
  state = list(messages = list(
    user_msg("What is 15 times 37?")
  ))
)

cat("Final answer:", tail(result$messages, 1)[[1]]$content, "\n")
