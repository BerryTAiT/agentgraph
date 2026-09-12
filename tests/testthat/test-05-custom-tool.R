test_that("custom R tool runs in an isolated server and returns emphasized result", {
  testthat::skip_if_not(python_available())

  m <- start_mock_llm(list(
    list(finish_reason = "tool_calls",
         tool_calls = list(list(id = "call_1", name = "shout",
                                arguments = '{"text":"hello world"}'))),
    list(finish_reason = "stop", content = "The result is HELLO WORLD!!")
  ))
  on.exit(stop_py_mock(m), add = TRUE)

  provider <- mock_provider(m)

  shout_tool <- agentgraph::tool(
    name = "shout",
    description = "Convert text to uppercase and add emphasis",
    parameters = list(text = agentgraph::param_string("Text to shout")),
    handler = function(args_json) {
      args <- jsonlite::fromJSON(args_json, simplifyVector = FALSE)
      jsonlite::toJSON(list(result = paste0(toupper(args$text), "!!")),
                       auto_unbox = TRUE)
    }
  )

  graph <- state_graph(entry = "agent") |>
    add_node("agent", llm_node(provider = provider, system_prompt = "calc",
                               tools = "shout")) |>
    add_node("tools", tool_node()) |>
    add_conditional_edge("agent", route_on(field = "has_tool_calls",
                                           rules = c("true" = "tools", "false" = "__end__"))) |>
    add_edge("tools", "agent")

  result <- run(graph,
                state = list(messages = list(user_msg("shout hello world"))),
                tools = list(shout_tool))

  msgs <- result$messages
  final <- tail(msgs, 1)[[1]]
  expect_identical(final$role, "assistant")
  expect_identical(final$content, "The result is HELLO WORLD!!")

  tool_msgs <- Filter(function(m) identical(m$role, "tool"), msgs)
  expect_length(tool_msgs, 1L)
  tool_res <- jsonlite::fromJSON(tool_msgs[[1]]$content)
  expect_identical(tool_res$result, "HELLO WORLD!!")

  expect_length(readLines(m$log, warn = FALSE), 2L)
})
