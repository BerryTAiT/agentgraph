# Example 3: Custom R tool (requires a real API key)
library(agentgraph)

provider <- provider_openai(model = "gpt-4o")

# Define a custom tool with an R handler
get_time_tool <- tool(
  name = "get_current_time",
  description = "Get the current system time",
  parameters = list(
    timezone = param_string("Timezone name (e.g. UTC)", required = FALSE)
  ),
  handler = function(args_json) {
    args <- jsonlite::fromJSON(args_json)
    tz <- if (is.null(args$timezone)) "UTC" else args$timezone
    jsonlite::toJSON(
      list(time = format(Sys.time(), tz = tz, usetz = TRUE)),
      auto_unbox = TRUE
    )
  }
)

graph <- state_graph(entry = "agent") |>
  add_node("agent", llm_node(
    provider = provider,
    system_prompt = "You are a helpful assistant.",
    tools = "get_current_time"
  )) |>
  add_node("tools", tool_node()) |>
  add_conditional_edge("agent", route_on(
    field = "has_tool_calls",
    rules = c("true" = "tools", "false" = "__end__")
  )) |>
  add_edge("tools", "agent")

result <- run(
  graph,
  state = list(messages = list(user_msg("What time is it right now?"))),
  tools = list(get_time_tool)
)

cat("Final answer:", tail(result$messages, 1)[[1]]$content, "\n")
