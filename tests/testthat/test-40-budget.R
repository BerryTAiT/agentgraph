# Budget / kill switch (max_total_tokens + max_time_sec). Uses the mock LLM
# for token counts and the latent mock for wall-clock delays.

mk_graph <- function(provider) {
  agentgraph::state_graph(entry = "a") |>
    agentgraph::add_node("a", agentgraph::llm_node(provider = provider)) |>
    agentgraph::add_node("b", agentgraph::llm_node(provider = provider)) |>
    agentgraph::add_node("c", agentgraph::llm_node(provider = provider)) |>
    agentgraph::add_edge("a", "b") |>
    agentgraph::add_edge("b", "c") |>
    agentgraph::add_edge("c", "__end__")
}

mock_openai <- function(m) {
  agentgraph::provider_openai(
    api_key = "test", model = "mock-model",
    base_url = paste0("http://127.0.0.1:", m$port), max_retries = 0L
  )
}

test_that("max_total_tokens aborts the run when exceeded", {
  testthat::skip_if_not(python_available())
  m <- start_mock_llm(list(list(content = "a"), list(content = "b"), list(content = "c")))
  on.exit(stop_py_mock(m), add = TRUE)

  g <- mk_graph(mock_openai(m))
  # 3 LLM calls * 15 total_tokens each = 45; limit 30 triggers on the 3rd.
  e <- err_msg(agentgraph::run(g, state = list(messages = list(agentgraph::user_msg("hi"))),
                               max_total_tokens = 30))
  expect_true(grepl("max_total_tokens", e, fixed = TRUE))
})

test_that("max_total_tokens allows the run when under the limit", {
  testthat::skip_if_not(python_available())
  m <- start_mock_llm(list(list(content = "a"), list(content = "b"), list(content = "c")))
  on.exit(stop_py_mock(m), add = TRUE)

  g <- mk_graph(mock_openai(m))
  r <- agentgraph::run(g, state = list(messages = list(agentgraph::user_msg("hi"))),
                       max_total_tokens = 100)
  expect_identical(tail(r$messages, 1)[[1]]$content, "c")
})

test_that("no budget means unlimited", {
  testthat::skip_if_not(python_available())
  m <- start_mock_llm(list(list(content = "a"), list(content = "b"), list(content = "c")))
  on.exit(stop_py_mock(m), add = TRUE)

  g <- mk_graph(mock_openai(m))
  r <- agentgraph::run(g, state = list(messages = list(agentgraph::user_msg("hi"))))
  expect_identical(tail(r$messages, 1)[[1]]$content, "c")
})

test_that("max_time_sec aborts a slow run", {
  testthat::skip_if_not(python_available())
  m <- start_latent_mock(delay = 1.0)
  on.exit(stop_py_mock(m), add = TRUE)

  g <- agentgraph::state_graph(entry = "a") |>
    agentgraph::add_node("a", agentgraph::llm_node(provider = mock_openai(m)))
  e <- err_msg(agentgraph::run(g, state = list(messages = list(agentgraph::user_msg("hi"))),
                               max_time_sec = 0.3))
  expect_true(grepl("max_time_sec", e, fixed = TRUE))
})

test_that("max_time_sec allows a fast run", {
  testthat::skip_if_not(python_available())
  m <- start_latent_mock(delay = 0)
  on.exit(stop_py_mock(m), add = TRUE)

  g <- agentgraph::state_graph(entry = "a") |>
    agentgraph::add_node("a", agentgraph::llm_node(provider = mock_openai(m)))
  r <- agentgraph::run(g, state = list(messages = list(agentgraph::user_msg("hi"))),
                       max_time_sec = 5)
  expect_length(r$messages, 2L)  # user + assistant
})

test_that("max_total_tokens accumulates across a ReAct tool loop", {
  testthat::skip_if_not(python_available())
  m <- start_mock_llm(list(
    list(finish_reason = "tool_calls",
         tool_calls = list(list(id = "c1", name = "echo", arguments = '{"x":"1"}'))),
    list(finish_reason = "stop", content = "done")
  ))
  on.exit(stop_py_mock(m), add = TRUE)

  echo <- agentgraph::tool(
    name = "echo", description = "echo", parameters = list(x = agentgraph::param_string("x")),
    handler = function(args_json) '{"ok":true}'
  )
  agent <- agentgraph::react_agent(mock_openai(m), tools = list(echo))
  # 2 LLM calls * 15 = 30 tokens; limit 10 triggers after the first call.
  e <- err_msg(agentgraph::run_agent(agent, "hi", max_total_tokens = 10))
  expect_true(grepl("max_total_tokens", e, fixed = TRUE))
})
