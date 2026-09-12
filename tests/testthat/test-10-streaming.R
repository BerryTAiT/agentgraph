run_stream_case <- function(tokens) {
  s <- start_stream_mock(tokens)
  on.exit(stop_py_mock(s), add = TRUE)
  provider <- mock_provider(s)

  graph <- state_graph(entry = "gen") |>
    add_node("gen", llm_node(provider = provider, system_prompt = "STREAM")) |>
    add_edge("gen", "__end__")

  received <- character(0)
  res <- run(graph, state = list(messages = list(user_msg("write hello"))),
             on_token = function(t) { received <<- c(received, t) })
  list(tokens = received, result = res)
}

test_that("on_token streams deltas in order and reassembles content", {
  testthat::skip_if_not(python_available())
  r <- run_stream_case(c("Hel", "lo", " ", "wor", "ld"))
  expect_identical(r$tokens, c("Hel", "lo", " ", "wor", "ld"))
  final <- tail(r$result$messages, 1)[[1]]
  expect_identical(final$role, "assistant")
  expect_identical(final$content, "Hello world")
  expect_false(is_interrupted(r$result))
})

test_that("empty stream completes with empty content", {
  testthat::skip_if_not(python_available())
  r <- run_stream_case(character(0))
  expect_identical(r$tokens, character(0))
  final <- tail(r$result$messages, 1)[[1]]
  expect_identical(final$content, "")
})
