# Provider fallback chain: hard-failure failover across providers.
#
# provider_fallback() wraps a list of provider configurations into a single
# "fallback" config. The C++ FallbackClient tries each provider in order,
# moving to the next only when the previous one fails hard (its retries are
# exhausted or it errors). The first successful response wins.

mk_provider <- function(m, model = "mock-model", max_retries = 0L) {
  agentgraph::provider_openai(
    api_key = "test", model = model,
    base_url = paste0("http://127.0.0.1:", m$port),
    max_retries = max_retries
  )
}

count_requests <- function(m) {
  f <- m$log
  if (!file.exists(f)) return(0L)
  length(readLines(f, warn = FALSE))
}

chat <- function(provider, msg = list(list(role = "user", content = "hello"))) {
  agentgraph:::chat_native_cpp(provider, msg, "")
}

test_that("falls through to the backup when the primary fails hard", {
  testthat::skip_if_not(python_available())
  primary <- start_mock_llm(list(list(status = 500L, content = "boom")))
  backup  <- start_mock_llm(list(list(content = "recovered by backup")))
  on.exit(stop_py_mock(primary), add = TRUE)
  on.exit(stop_py_mock(backup), add = TRUE)

  provider <- agentgraph::provider_fallback(
    mk_provider(primary), mk_provider(backup)
  )

  r <- chat(provider)
  expect_identical(r$content, "recovered by backup")

  Sys.sleep(0.1)
  expect_identical(count_requests(primary), 1L)
  expect_identical(count_requests(backup), 1L)
})

test_that("a successful primary short-circuits and never calls the backup", {
  testthat::skip_if_not(python_available())
  primary <- start_mock_llm(list(list(content = "primary wins")))
  backup  <- start_mock_llm(list(list(content = "must not run")))
  on.exit(stop_py_mock(primary), add = TRUE)
  on.exit(stop_py_mock(backup), add = TRUE)

  provider <- agentgraph::provider_fallback(
    mk_provider(primary), mk_provider(backup)
  )

  r <- chat(provider)
  expect_identical(r$content, "primary wins")

  Sys.sleep(0.1)
  expect_identical(count_requests(primary), 1L)
  expect_identical(count_requests(backup), 0L)
})

test_that("reports a combined error when every provider fails", {
  testthat::skip_if_not(python_available())
  primary <- start_mock_llm(list(list(status = 500L)))
  backup  <- start_mock_llm(list(list(status = 500L)))
  on.exit(stop_py_mock(primary), add = TRUE)
  on.exit(stop_py_mock(backup), add = TRUE)

  provider <- agentgraph::provider_fallback(
    mk_provider(primary), mk_provider(backup)
  )

  e <- err_msg(chat(provider))
  expect_false(is.null(e))
  expect_true(grepl("all fallback providers failed", e, fixed = TRUE))
})

test_that("fallback chain applies inside a graph node", {
  testthat::skip_if_not(python_available())
  primary <- start_mock_llm(list(list(status = 500L)))
  backup  <- start_mock_llm(list(list(content = "graph fallback ok")))
  on.exit(stop_py_mock(primary), add = TRUE)
  on.exit(stop_py_mock(backup), add = TRUE)

  provider <- agentgraph::provider_fallback(
    mk_provider(primary), mk_provider(backup)
  )

  graph <- state_graph(entry = "llm") |>
    add_node("llm", llm_node(provider = provider))

  result <- run(graph, state = list(messages = list(user_msg("hi"))))
  expect_identical(tail(result$messages, 1)[[1]]$content, "graph fallback ok")
})

test_that("provider_fallback() validates its arguments", {
  p <- agentgraph::provider_openai()

  e <- err_msg(agentgraph::provider_fallback(p))
  expect_false(is.null(e))
  expect_true(grepl("at least 2", e, fixed = TRUE))

  e <- err_msg(agentgraph::provider_fallback(p, "not a provider"))
  expect_false(is.null(e))
  expect_true(grepl("provider configuration", e, fixed = TRUE))
})
