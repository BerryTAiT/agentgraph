# Fine-tuning integration (R/finetune.R).

mk <- function(m) {
  agentgraph::provider_openai(
    api_key = "test", model = "mock-model",
    base_url = paste0("http://127.0.0.1:", m$port), max_retries = 0L
  )
}

test_that("fine_tune creates a job and reports status (mock)", {
  testthat::skip_if_not(python_available())
  testthat::skip_if_not_installed("curl")
  m <- start_fine_tune_mock()
  on.exit(stop_py_mock(m), add = TRUE)

  examples <- data.frame(input = c("2+2", "capital"), output = c("4", "Paris"))
  job_id <- agentgraph::fine_tune(mk(m), examples, model = "gpt-4o-mini")
  expect_identical(job_id, "ftjob-mock-1")

  st <- agentgraph::fine_tune_status(job_id, mk(m))
  expect_identical(st$status, "succeeded")
  expect_identical(st$fine_tuned_model, "ft:gpt-4o-mini:mock")

  jobs <- agentgraph::fine_tune_list(mk(m))
  expect_length(jobs, 1L)
  expect_identical(jobs[[1]]$id, "ftjob-mock-1")

  cancelled <- agentgraph::fine_tune_cancel(job_id, mk(m))
  expect_identical(cancelled$status, "cancelled")
})

test_that("fine_tune accepts list pairs and feedback/eval data", {
  testthat::skip_if_not(python_available())
  testthat::skip_if_not_installed("curl")
  m <- start_fine_tune_mock()
  on.exit(stop_py_mock(m), add = TRUE)

  pairs <- list(list(input = "a", output = "b"), list(input = "c", output = "d"))
  expect_identical(agentgraph::fine_tune(mk(m), pairs), "ftjob-mock-1")

  # eval_dataset-style (input + expected)
  ds <- agentgraph::eval_dataset(c("q1", "q2"), c("a1", "a2"))
  expect_identical(agentgraph::fine_tune(mk(m), ds), "ftjob-mock-1")
})

test_that(".to_finetune_jsonl builds OpenAI chat lines", {
  lines <- agentgraph:::.to_finetune_jsonl(data.frame(input = "2+2", output = "4"))
  expect_length(lines, 1L)
  j <- jsonlite::fromJSON(lines[1], simplifyVector = FALSE)
  expect_identical(j$messages[[1]]$role, "user")
  expect_identical(j$messages[[1]]$content, "2+2")
  expect_identical(j$messages[[2]]$role, "assistant")
  expect_identical(j$messages[[2]]$content, "4")
})

test_that("fine_tune validates examples", {
  testthat::skip_if_not_installed("curl")
  e <- err_msg(agentgraph::fine_tune(
    agentgraph::provider_openai(), 42))
  expect_true(grepl("data.frame or a list", e, fixed = TRUE))

  e2 <- err_msg(agentgraph::fine_tune(
    agentgraph::provider_openai(), data.frame(foo = "bar")))
  expect_true(grepl("input", e2, fixed = TRUE))
})
