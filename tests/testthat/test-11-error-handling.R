mk_err_graph <- function(provider, max_iterations = 25L) {
  state_graph(entry = "gen", max_iterations = max_iterations) |>
    add_node("gen", llm_node(provider = provider, system_prompt = "ERR")) |>
    add_edge("gen", "__end__")
}

test_that("HTTP 500 with JSON error body throws a descriptive error", {
  testthat::skip_if_not(python_available())
  m <- start_error_mock(list(list(
    status = 500, body = '{"error":{"message":"simulated server failure"}}'
  )))
  on.exit(stop_py_mock(m), add = TRUE)
  provider <- mock_provider(m)
  e <- err_msg(run(mk_err_graph(provider),
                   state = list(messages = list(user_msg("x")))))
  expect_false(is.null(e))
  expect_true(grepl("500", e, fixed = TRUE))
  expect_true(grepl("simulated server failure", e, fixed = TRUE))
})

test_that("HTTP 429 rate limit is surfaced", {
  testthat::skip_if_not(python_available())
  m <- start_error_mock(list(list(
    status = 429, body = '{"error":{"message":"rate limited"}}'
  )))
  on.exit(stop_py_mock(m), add = TRUE)
  provider <- mock_provider(m)
  e <- err_msg(run(mk_err_graph(provider),
                   state = list(messages = list(user_msg("x")))))
  expect_false(is.null(e))
  expect_true(grepl("429", e, fixed = TRUE))
  expect_true(grepl("rate limited", e, fixed = TRUE))
})

test_that("200 with malformed JSON body throws a parse error", {
  testthat::skip_if_not(python_available())
  m <- start_error_mock(list(list(status = 200, body = "this is not json")))
  on.exit(stop_py_mock(m), add = TRUE)
  provider <- mock_provider(m)
  e <- err_msg(run(mk_err_graph(provider),
                   state = list(messages = list(user_msg("x")))))
  expect_false(is.null(e))
  expect_true(grepl("parse", e, ignore.case = TRUE))
})

test_that("connection refused throws an error", {
  provider <- provider_openai(
    api_key = "test", model = "m", base_url = "http://127.0.0.1:18999"
  )
  e <- err_msg(run(mk_err_graph(provider),
                   state = list(messages = list(user_msg("x")))))
  expect_false(is.null(e))
})

test_that("self-loop exceeding max iterations throws the cap error", {
  testthat::skip_if_not(python_available())
  m <- start_error_mock(list(list(
    status = 200,
    body = '{"choices":[{"message":{"content":"ok"},"finish_reason":"stop"}]}'
  )))
  on.exit(stop_py_mock(m), add = TRUE)
  provider <- mock_provider(m)
  loop_graph <- state_graph(entry = "gen", max_iterations = 2L) |>
    add_node("gen", llm_node(provider = provider, system_prompt = "LOOP")) |>
    add_edge("gen", "gen")
  e <- err_msg(run(loop_graph, state = list(messages = list(user_msg("x")))))
  expect_false(is.null(e))
  expect_true(grepl("maximum iterations", e, fixed = TRUE))
})
