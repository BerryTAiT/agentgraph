# RLHF / feedback loop (R/feedback.R).

test_that("record_feedback extracts input/output from a run result", {
  agentgraph::feedback_reset()
  result <- list(
    answer = "Paris",
    state = list(messages = list(
      list(role = "user", content = "capital of France"),
      list(role = "assistant", content = "Paris")
    ))
  )
  agentgraph::record_feedback(result, rating = "good")

  ds <- agentgraph::feedback_dataset()
  expect_equal(nrow(ds), 1L)
  expect_identical(ds$input, "capital of France")
  expect_identical(ds$output, "Paris")
  expect_identical(ds$rating, "good")
})

test_that("record_feedback accepts explicit input/output and corrections", {
  agentgraph::feedback_reset()
  agentgraph::record_feedback(rating = "bad", input = "2+2", output = "5", correction = "4")
  ds <- agentgraph::feedback_dataset()
  expect_identical(ds$rating, "bad")
  expect_identical(ds$correction, "4")
})

test_that("record_feedback normalizes rating forms", {
  agentgraph::feedback_reset()
  agentgraph::record_feedback(rating = TRUE, input = "a", output = "b")
  agentgraph::record_feedback(rating = -1, input = "a", output = "b")
  agentgraph::record_feedback(rating = "thumbs_up", input = "a", output = "b")
  ds <- agentgraph::feedback_dataset()
  expect_identical(ds$rating, c("good", "bad", "good"))
})

test_that("feedback_stats and feedback_reset", {
  agentgraph::feedback_reset()
  agentgraph::record_feedback(rating = "good", input = "a", output = "b")
  agentgraph::record_feedback(rating = "bad", input = "a", output = "b")
  s <- agentgraph::feedback_stats()
  expect_identical(s$good, 1L)
  expect_identical(s$bad, 1L)
  expect_identical(s$total, 2L)

  agentgraph::feedback_reset()
  expect_equal(nrow(agentgraph::feedback_dataset()), 0L)
  s2 <- agentgraph::feedback_stats()
  expect_identical(s2$total, 0L)
})

test_that("feedback_export writes JSONL", {
  agentgraph::feedback_reset()
  agentgraph::record_feedback(rating = "good", input = "q", output = "a")

  f <- tempfile(fileext = ".jsonl")
  agentgraph::feedback_export(f)
  lines <- readLines(f, warn = FALSE)
  expect_length(lines, 1L)
  j <- jsonlite::fromJSON(lines[1], simplifyVector = FALSE)
  expect_identical(j$rating, "good")
  expect_identical(j$input, "q")
})

test_that("feedback validates its input", {
  e <- err_msg(agentgraph::record_feedback(rating = "maybe", input = "a", output = "b"))
  expect_true(grepl("good/bad", e, fixed = TRUE))

  e2 <- err_msg(agentgraph::record_feedback(rating = "good"))
  expect_true(grepl("input", e2, fixed = TRUE))

  e3 <- err_msg(agentgraph::record_feedback(result = 42, rating = "good"))
  expect_true(grepl("run() state", e3, fixed = TRUE))
})
