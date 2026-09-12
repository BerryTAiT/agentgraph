test_that("interrupt_node pauses and resume completes with injected values", {
  testthat::skip_if_not(python_available())
  m <- start_mock_llm(list(
    list(finish_reason = "stop", content = "approved by human")
  ))
  on.exit(stop_py_mock(m), add = TRUE)
  provider <- mock_provider(m)

  graph <- state_graph(entry = "checkpoint") |>
    add_node("checkpoint", interrupt_node()) |>
    add_node("finalize", llm_node(provider = provider, system_prompt = "finalize")) |>
    add_edge("checkpoint", "finalize") |>
    add_edge("finalize", "__end__")

  run1 <- run(graph, state = list(messages = list(user_msg("review this"))))

  expect_true(is_interrupted(run1))
  resume_node <- jsonlite::fromJSON(run1$data[["__resume_node__"]])
  expect_identical(resume_node, "finalize")
  expect_length(run1$messages, 1L)

  run2 <- resume(graph, run1, inject = list(approved = TRUE, reviewer = "alice"))

  expect_false(is_interrupted(run2))
  final <- tail(run2$messages, 1)[[1]]
  expect_identical(final$role, "assistant")
  expect_identical(final$content, "approved by human")
  expect_identical(run2$data[["approved"]], "true")
  expect_identical(jsonlite::fromJSON(run2$data[["reviewer"]]), "alice")
  expect_length(readLines(m$log, warn = FALSE), 1L)

  expect_error(resume(graph, run2))
})
