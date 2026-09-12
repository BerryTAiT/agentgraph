test_that("agent loop drives a tool call and returns the final answer", {
  testthat::skip_if_not(python_available())

  m <- start_mock_llm(list(
    list(finish_reason = "tool_calls",
         tool_calls = list(list(id = "call_1", name = "calculator",
                                arguments = '{"expression":"2+3"}'))),
    list(finish_reason = "stop", content = "The answer is 5.")
  ))
  on.exit(stop_py_mock(m), add = TRUE)

  provider <- mock_provider(m)

  graph <- state_graph(entry = "agent") |>
    add_node("agent", llm_node(provider = provider, system_prompt = "calc",
                               tools = "calculator")) |>
    add_node("tools", tool_node()) |>
    add_conditional_edge("agent", route_on(field = "has_tool_calls",
                                           rules = c("true" = "tools", "false" = "__end__"))) |>
    add_edge("tools", "agent")

  result <- run(graph, state = list(messages = list(user_msg("2+3?"))))

  msgs <- result$messages
  final <- tail(msgs, 1)[[1]]
  expect_identical(final$role, "assistant")
  expect_identical(final$content, "The answer is 5.")

  tool_msgs <- Filter(function(m) identical(m$role, "tool"), msgs)
  expect_length(tool_msgs, 1L)
  tool_res <- jsonlite::fromJSON(tool_msgs[[1]]$content)
  expect_equal(tool_res$result, 5)

  expect_length(readLines(m$log, warn = FALSE), 2L)
})
