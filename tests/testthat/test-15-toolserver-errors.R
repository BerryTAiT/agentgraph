test_that("tool server propagates handler errors and dead-server failures", {
  good    <- list(name = "good", handler = function(args_json) {
    args <- jsonlite::fromJSON(args_json, simplifyVector = FALSE)
    jsonlite::toJSON(list(result = args$x * 2), auto_unbox = TRUE)
  })
  boom    <- list(name = "boom", handler = function(args_json) stop("boom"))
  badjson <- list(name = "badjson", handler = function(args_json) "not-json")

  srv <- agentgraph:::.start_tool_server(list(good, boom, badjson))
  on.exit(agentgraph:::.stop_tool_server(srv), add = TRUE)
  port <- srv$port
  token <- srv$token
  expect_true(is.character(token) && nzchar(token))

  r_good <- agentgraph:::rpc_call_cpp(port, "good", '{"x":21}', token)
  expect_true(r_good$ok)
  expect_equal(
    as.numeric(jsonlite::fromJSON(r_good$result, simplifyVector = FALSE)$result),
    42
  )

  # Requests without the token (or with the wrong one) are rejected.
  r_notoken <- agentgraph:::rpc_call_cpp(port, "good", '{"x":21}')
  expect_false(r_notoken$ok)
  expect_true(grepl("unauthorized", r_notoken$error, fixed = TRUE))
  r_badtoken <- agentgraph:::rpc_call_cpp(port, "good", '{"x":21}', "wrong")
  expect_false(r_badtoken$ok)
  expect_true(grepl("unauthorized", r_badtoken$error, fixed = TRUE))

  r_boom <- agentgraph:::rpc_call_cpp(port, "boom", "{}", token)
  expect_false(r_boom$ok)
  expect_identical(r_boom$error, "boom")

  r_badjson <- agentgraph:::rpc_call_cpp(port, "badjson", "{}", token)
  expect_false(r_badjson$ok)
  expect_true(grepl("tool handler returned invalid JSON", r_badjson$error, fixed = TRUE))

  r_unknown <- agentgraph:::rpc_call_cpp(port, "nope", "{}", token)
  expect_false(r_unknown$ok)
  expect_true(grepl("Tool not found", r_unknown$error, fixed = TRUE))

  dead_port <- port
  agentgraph:::.stop_tool_server(srv)
  srv <- NULL
  Sys.sleep(0.5)
  r_dead <- agentgraph:::rpc_call_cpp(dead_port, "good", "{}", token)
  expect_false(r_dead$ok)
  expect_true(grepl("cannot connect", r_dead$error, fixed = TRUE))
})

test_that("graph captures tool error as a tool message instead of aborting", {
  testthat::skip_if_not(python_available())
  m <- start_mock_llm(list(
    list(finish_reason = "tool_calls",
         tool_calls = list(list(id = "call_1", name = "boom_tool",
                                arguments = '{}'))),
    list(finish_reason = "stop", content = "Handled the error gracefully.")
  ))
  on.exit(stop_py_mock(m), add = TRUE)
  provider <- mock_provider(m)

  boom_tool <- agentgraph::tool(
    name = "boom_tool",
    description = "Always fails",
    parameters = list(),
    handler = function(args_json) stop("boom")
  )

  graph <- state_graph(entry = "agent") |>
    add_node("agent", llm_node(provider = provider, system_prompt = "x",
                               tools = "boom_tool")) |>
    add_node("tools", tool_node()) |>
    add_conditional_edge("agent", route_on(field = "has_tool_calls",
                                           rules = c("true" = "tools",
                                                     "false" = "__end__"))) |>
    add_edge("tools", "agent")

  result <- run(graph, state = list(messages = list(user_msg("go"))),
                tools = list(boom_tool))

  msgs  <- result$messages
  final <- tail(msgs, 1)[[1]]
  expect_identical(final$role, "assistant")
  expect_identical(final$content, "Handled the error gracefully.")

  tool_msgs <- Filter(function(x) identical(x$role, "tool"), msgs)
  expect_length(tool_msgs, 1L)
  tm <- tool_msgs[[1]]
  expect_identical(
    jsonlite::fromJSON(tm$content, simplifyVector = FALSE),
    list(error = "boom")
  )
  expect_identical(tm$name, "boom_tool")
  expect_identical(tm$tool_call_id, "call_1")

  expect_length(readLines(m$log, warn = FALSE), 2L)
})
