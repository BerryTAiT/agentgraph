# Async jobs (R/async.R). Uses mirai (Suggests) and the mock LLM.

mk_provider <- function(m) {
  agentgraph::provider_openai(
    api_key = "test", model = "mock-model",
    base_url = paste0("http://127.0.0.1:", m$port), max_retries = 0L
  )
}

test_that("run_async validates its target and input", {
  testthat::skip_if_not_installed("mirai")
  e <- err_msg(agentgraph::run_async("nope", "x"))
  expect_true(grepl("agent, a graph, or a function", e, fixed = TRUE))

  agent <- agentgraph::chat_agent(agentgraph::provider_openai())
  e2 <- err_msg(agentgraph::run_async(agent, list("a")))
  expect_true(grepl("single-string input", e2, fixed = TRUE))

  g <- agentgraph::state_graph(entry = "n")
  e3 <- err_msg(agentgraph::run_async(g, 42))
  expect_true(grepl("single string or a state list", e3, fixed = TRUE))
})

test_that("run_async/job_status/job_result round-trip a graph", {
  testthat::skip_if_not_installed("mirai")
  testthat::skip_if_not(python_available())
  m <- start_mock_llm(list(list(content = "async answer")))
  on.exit(stop_py_mock(m), add = TRUE)

  g <- agentgraph::state_graph(entry = "n") |>
    agentgraph::add_node("n", agentgraph::llm_node(provider = mk_provider(m))) |>
    agentgraph::add_edge("n", "__end__")

  job <- agentgraph::run_async(g, "hi")
  expect_s3_class(job, "agentgraph_job")
  expect_true(nzchar(job$id))

  st <- agentgraph::job_status(job)
  expect_true(st %in% c("running", "done"))

  r <- agentgraph::job_result(job)
  expect_identical(tail(r$messages, 1)[[1]]$content, "async answer")
  expect_identical(agentgraph::job_status(job), "done")

  out <- capture.output(print(job))
  expect_true(any(grepl("done", out, fixed = TRUE)))
})

test_that("run_async/job_result round-trip an agent", {
  testthat::skip_if_not_installed("mirai")
  testthat::skip_if_not(python_available())
  m <- start_mock_llm(list(list(content = "agent async")))
  on.exit(stop_py_mock(m), add = TRUE)

  agent <- agentgraph::chat_agent(mk_provider(m))
  job <- agentgraph::run_async(agent, "hello")
  r <- agentgraph::job_result(job)
  expect_identical(r$answer, "agent async")
})

test_that("job_result timeout errors but the job keeps running", {
  testthat::skip_if_not_installed("mirai")
  testthat::skip_if_not(python_available())
  m <- start_latent_mock(delay = 1.0)
  on.exit(stop_py_mock(m), add = TRUE)

  g <- agentgraph::state_graph(entry = "n") |>
    agentgraph::add_node("n", agentgraph::llm_node(provider = mk_provider(m))) |>
    agentgraph::add_edge("n", "__end__")

  job <- agentgraph::run_async(g, "hi")
  e <- err_msg(agentgraph::job_result(job, timeout = 0.2))
  expect_true(grepl("still running", e, fixed = TRUE))

  r <- agentgraph::job_result(job)  # completes later
  expect_identical(agentgraph::job_status(job), "done")
})

test_that("a failing target reports job_status 'failed'", {
  testthat::skip_if_not_installed("mirai")
  # graph with an unreachable provider -> run() errors
  bad <- agentgraph::provider_openai(
    api_key = "test", model = "mock", base_url = "http://127.0.0.1:1",
    max_retries = 0L
  )
  g <- agentgraph::state_graph(entry = "n") |>
    agentgraph::add_node("n", agentgraph::llm_node(provider = bad)) |>
    agentgraph::add_edge("n", "__end__")

  job <- agentgraph::run_async(g, "hi")
  e <- err_msg(agentgraph::job_result(job, timeout = 30))
  expect_true(grepl("job failed", e, fixed = TRUE))
  expect_identical(agentgraph::job_status(job), "failed")
})

test_that("job_cancel and unknown-job errors", {
  testthat::skip_if_not_installed("mirai")
  testthat::skip_if_not(python_available())
  m <- start_latent_mock(delay = 1.0)
  on.exit(stop_py_mock(m), add = TRUE)

  g <- agentgraph::state_graph(entry = "n") |>
    agentgraph::add_node("n", agentgraph::llm_node(provider = mk_provider(m))) |>
    agentgraph::add_edge("n", "__end__")

  job <- agentgraph::run_async(g, "hi")
  expect_null(agentgraph::job_cancel(job))  # cancel a running job does not error

  e <- err_msg(agentgraph::job_status("no-such-job"))
  expect_true(grepl("job not found", e, fixed = TRUE))
  e2 <- err_msg(agentgraph::job_result("no-such-job"))
  expect_true(grepl("job not found", e2, fixed = TRUE))
})
