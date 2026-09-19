test_that("run() writes a crash-durable checkpoint and checkpoint_resume() completes", {
  testthat::skip_if_not(python_available())
  m <- start_mock_llm(list(
    list(finish_reason = "stop", content = "approved by human")
  ))
  on.exit(stop_py_mock(m), add = TRUE)
  provider <- mock_provider(m)

  cp <- tempfile(fileext = ".json")
  trace <- tempfile(fileext = ".jsonl")

  graph <- state_graph(entry = "checkpoint") |>
    add_node("checkpoint", interrupt_node()) |>
    add_node("finalize", llm_node(provider = provider, system_prompt = "finalize")) |>
    add_edge("checkpoint", "finalize") |>
    add_edge("finalize", "__end__")

  run1 <- run(graph, state = list(messages = list(user_msg("review this"))),
              checkpoint_path = cp, log_path = trace)

  # First run pauses at the interrupt node and persists a checkpoint.
  expect_true(is_interrupted(run1))
  expect_true(file.exists(cp))

  loaded <- checkpoint_load(cp)
  expect_true(is.list(loaded$state))
  expect_identical(loaded$resume_node, "finalize")
  expect_length(loaded$state$messages, 1L)

  # Resuming from the checkpoint drives the run to completion.
  run2 <- checkpoint_resume(graph, cp, inject = list(approved = TRUE))
  expect_false(is_interrupted(run2))
  final <- tail(run2$messages, 1)[[1]]
  expect_identical(final$role, "assistant")
  expect_identical(final$content, "approved by human")
  expect_identical(jsonlite::fromJSON(run2$data[["approved"]]), TRUE)

  # The trace file captured engine events as JSON lines.
  events <- readLines(trace, warn = FALSE)
  expect_true(length(events) > 0)
  kinds <- vapply(events, function(ln) jsonlite::fromJSON(ln)$event, character(1))
  expect_true("checkpoint" %in% kinds)

  # A completed checkpoint reports no further resume node.
  done <- checkpoint_load(cp)
  expect_true(done$resume_node %in% c("", "__end__"))
})

test_that("checkpoint_load errors cleanly on a missing file", {
  expect_error(checkpoint_load(tempfile(fileext = ".json")), "not found")
})
