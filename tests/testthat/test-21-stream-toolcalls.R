# Streamed tool calls: the SSE mock splits the tool-call arguments JSON into
# fragments across deltas, exactly like real providers. The engine must
# accumulate the fragments and execute the tool with the full arguments.

test_that("streamed tool-call arguments are reassembled and executed", {
  testthat::skip_if_not(python_available())

  s <- start_stream_mock(list(
    tokens = "let me calculate.",
    tool_calls = list(list(
      id = "call_frag_1",
      name = "calculator",
      arg_fragments = c('{"expr', 'ession":', ' "2+3"}')
    )),
    final_finish = "tool_calls"
  ))
  on.exit(stop_py_mock(s), add = TRUE)
  provider <- mock_provider(s)

  graph <- state_graph(entry = "agent") |>
    add_node("agent", llm_node(provider = provider, system_prompt = "S")) |>
    add_conditional_edge("agent", route_on(
      field = "has_tool_calls",
      rules = c("true" = "tools", "false" = "__end__")
    )) |>
    add_node("tools", tool_node()) |>
    add_edge("tools", "__end__")

  res <- run(graph,
             state = list(messages = list(user_msg("what is 2+3?"))),
             on_token = function(tok) NULL)

  msgs <- res$messages
  assistant <- Filter(function(m) identical(m$role, "assistant"), msgs)
  expect_length(assistant, 1)
  expect_length(assistant[[1]]$tool_calls, 1)
  expect_identical(assistant[[1]]$tool_calls[[1]]$name, "calculator")
  # The fragments must have been joined into valid JSON.
  expect_identical(
    jsonlite::fromJSON(assistant[[1]]$tool_calls[[1]]$arguments)$expression,
    "2+3"
  )

  tool_msg <- Filter(function(m) identical(m$role, "tool"), msgs)
  expect_length(tool_msg, 1)
  expect_identical(tool_msg[[1]]$tool_call_id, "call_frag_1")
  expect_identical(
    jsonlite::fromJSON(tool_msg[[1]]$content)$result,
    5
  )

  state <- res$data
  expect_false(jsonlite::fromJSON(state$has_tool_calls))
})
