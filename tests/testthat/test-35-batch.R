# Batch API (R/batch.R). Sequential tests need no extra packages; parallel
# and async tests use mirai (Suggests) and are skipped when unavailable.

mk_provider <- function(m) {
  agentgraph::provider_openai(
    api_key = "test", model = "mock-model",
    base_url = paste0("http://127.0.0.1:", m$port),
    max_retries = 0L
  )
}

count_requests <- function(m) {
  f <- m$log
  if (!file.exists(f)) return(0L)
  length(readLines(f, warn = FALSE))
}

test_that("batch validates its arguments", {
  f <- function(x) x
  e <- err_msg(agentgraph::batch(42, c("a")))
  expect_true(grepl("an agent, a graph", e, fixed = TRUE))

  e <- err_msg(agentgraph::batch(f, character(0)))
  expect_true(grepl("at least one input", e, fixed = TRUE))

  e <- err_msg(agentgraph::batch(f, 42))
  expect_true(grepl("character vector or a list", e, fixed = TRUE))

  e <- err_msg(agentgraph::batch(f, NULL))
  expect_true(grepl("character vector or a list", e, fixed = TRUE))

  e <- err_msg(agentgraph::batch(f, c("a"), concurrency = 0))
  expect_true(grepl("integer >= 1", e, fixed = TRUE))

  e <- err_msg(agentgraph::batch(f, c("a"), on_result = "nope"))
  expect_true(grepl("function or NULL", e, fixed = TRUE))

  agent <- agentgraph::chat_agent(agentgraph::provider_openai())
  e <- err_msg(agentgraph::batch(agent, list(list(messages = list()))))
  expect_true(grepl("single-string inputs", e, fixed = TRUE))
})

test_that("batch runs a function target sequentially with error containment", {
  target <- function(x) if (identical(x, "boom")) stop("kaboom") else paste0("ok-", x)
  seen <- list()
  r <- agentgraph::batch(target, c("a", "boom", "c"),
                         on_result = function(row) {
                           seen[[length(seen) + 1L]] <<- row
                         })

  expect_s3_class(r, "agentgraph_batch")
  expect_s3_class(r, "data.frame")
  expect_identical(r$i, 1:3)
  expect_identical(r$input, c("a", "boom", "c"))
  expect_identical(r$answer, c("ok-a", NA, "ok-c"))
  expect_identical(r$error, c("", "kaboom", ""))
  expect_true(all(r$elapsed >= 0))
  expect_identical(attr(r, "concurrency"), 1L)

  expect_length(seen, 3L)
  expect_identical(seen[[2]]$error, "kaboom")
  expect_identical(seen[[3]]$answer, "ok-c")

  out <- capture.output(print(r))
  expect_true(any(grepl("agentgraph batch", out, fixed = TRUE)))
  expect_true(any(grepl("1 error", out, fixed = TRUE)))
})

test_that("batch unwraps list answers and forwards extra args", {
  target <- function(x, prefix) list(answer = paste0(prefix, x))
  r <- agentgraph::batch(target, c("a", "b"), prefix = "ans-")
  expect_identical(r$answer, c("ans-a", "ans-b"))
  expect_identical(r$error, c("", ""))
})

test_that("batch runs an agent target (mock LLM)", {
  testthat::skip_if_not(python_available())
  m <- start_mock_llm(list(list(content = "one"), list(content = "two")))
  on.exit(stop_py_mock(m), add = TRUE)

  agent <- agentgraph::chat_agent(mk_provider(m))
  r <- agentgraph::batch(agent, c("q1", "q2"))
  expect_identical(r$answer, c("one", "two"))
  Sys.sleep(0.2)
  expect_identical(count_requests(m), 2L)
})

test_that("batch runs a graph target (mock LLM) with string and state inputs", {
  testthat::skip_if_not(python_available())
  m <- start_mock_llm(list(list(content = "one"), list(content = "two"),
                           list(content = "three")))
  on.exit(stop_py_mock(m), add = TRUE)

  g <- agentgraph::state_graph(entry = "n") |>
    agentgraph::add_node("n", agentgraph::llm_node(provider = mk_provider(m)))

  r <- agentgraph::batch(g, c("q1", "q2"))
  expect_identical(r$answer, c("one", "two"))

  r2 <- agentgraph::batch(g, list(list(messages = list(agentgraph::user_msg("q3")))))
  expect_identical(r2$answer, "three")
  expect_true(is.list(r2$input))

  # invalid state inputs are contained per row (like any target error)
  r3 <- agentgraph::batch(g, list(42, "q4"))
  expect_identical(r3$answer[[2]], "three") # 4th request: last scenario entry repeats
  expect_true(grepl("single string or a state list", r3$error[[1]], fixed = TRUE))
  expect_identical(r3$error[[2]], "")
})

test_that("batch parallel (mirai) preserves order and reports per-input errors", {
  testthat::skip_if_not_installed("mirai")
  target <- function(x) if (identical(x, "boom")) stop("kaboom") else paste0("p-", x)
  r <- agentgraph::batch(target, c("a", "boom", "c", "d"), concurrency = 2L)
  expect_identical(r$answer, c("p-a", NA, "p-c", "p-d"))
  expect_identical(r$error, c("", "kaboom", "", ""))
  expect_identical(attr(r, "concurrency"), 2L)
  expect_identical(r$i, 1:4)
})

test_that("batch parallel (mirai) runs an agent target against the mock", {
  testthat::skip_if_not_installed("mirai")
  testthat::skip_if_not(python_available())
  m <- start_mock_llm(list(list(content = "ok")))
  on.exit(stop_py_mock(m), add = TRUE)

  agent <- agentgraph::chat_agent(mk_provider(m))
  r <- agentgraph::batch(agent, c("q1", "q2", "q3"), concurrency = 3L)
  expect_identical(r$answer, c("ok", "ok", "ok"))
  Sys.sleep(0.3)
  expect_identical(count_requests(m), 3L)
})

test_that("batch_submit / batch_status / batch_collect round-trip", {
  testthat::skip_if_not_installed("mirai")
  target <- function(x) paste0("j-", x)
  job <- agentgraph::batch_submit(target, c("a", "b"))
  expect_s3_class(job, "agentgraph_batch_job")

  st <- agentgraph::batch_status(job)
  expect_true(st %in% c("running", "complete"))

  r <- agentgraph::batch_collect(job)
  expect_s3_class(r, "agentgraph_batch")
  expect_identical(r$answer, c("j-a", "j-b"))
  expect_identical(agentgraph::batch_status(job), "complete")

  out <- capture.output(print(job))
  expect_true(any(grepl("agentgraph batch job", out, fixed = TRUE)))
  expect_true(any(grepl("complete", out, fixed = TRUE)))
})

test_that("batch_collect timeout errors but the job keeps running", {
  testthat::skip_if_not_installed("mirai")
  target <- function(x) { Sys.sleep(1.5); paste0("s-", x) }
  job <- agentgraph::batch_submit(target, c("a"))
  e <- err_msg(agentgraph::batch_collect(job, timeout = 0.2))
  expect_true(grepl("still running", e, fixed = TRUE))

  r <- agentgraph::batch_collect(job)
  expect_identical(r$answer, "s-a")
})

test_that("batch_submit validates eagerly; status/collect validate the job", {
  testthat::skip_if_not_installed("mirai")
  e <- err_msg(agentgraph::batch_submit(42, c("a")))
  expect_true(grepl("an agent, a graph", e, fixed = TRUE))

  e <- err_msg(agentgraph::batch_submit(function(x) x, c("a"), concurrency = 0))
  expect_true(grepl("integer >= 1", e, fixed = TRUE))

  e <- err_msg(agentgraph::batch_status("nope"))
  expect_true(grepl("batch_submit()", e, fixed = TRUE))

  e <- err_msg(agentgraph::batch_collect("nope"))
  expect_true(grepl("batch_submit()", e, fixed = TRUE))

  e <- err_msg(agentgraph::batch_collect(
    agentgraph::batch_submit(function(x) x, "a"), timeout = -1))
  expect_true(grepl("positive number", e, fixed = TRUE))
})
