# Metrics (R/metrics.R + C++ cache hit/miss + inst/tools/metrics_server.R).

mk_provider <- function(m) {
  agentgraph::provider_openai(
    api_key = "test", model = "mock-model",
    base_url = paste0("http://127.0.0.1:", m$port), max_retries = 0L
  )
}

test_that("metrics_snapshot reports calls, tokens, latency, and nodes", {
  testthat::skip_if_not(python_available())
  agentgraph::metrics_reset()

  m <- start_mock_llm(list(list(content = "one"), list(content = "two")))
  on.exit(stop_py_mock(m), add = TRUE)

  g <- agentgraph::state_graph(entry = "a") |>
    agentgraph::add_node("a", agentgraph::llm_node(provider = mk_provider(m))) |>
    agentgraph::add_node("b", agentgraph::llm_node(provider = mk_provider(m))) |>
    agentgraph::add_edge("a", "b") |>
    agentgraph::add_edge("b", "__end__")
  agentgraph::run(g, state = list(messages = list(agentgraph::user_msg("hi"))))

  s <- agentgraph::metrics_snapshot()
  expect_equal(s$llm_calls, 2L)
  expect_equal(s$llm_errors, 0L)
  expect_equal(s$latency_count, 2L)
  expect_equal(s$total_tokens, 30)   # 2 * 15 (mock default usage)
  expect_equal(s$prompt_tokens, 20)  # 2 * 10
  expect_equal(s$completion_tokens, 10)  # 2 * 5
  expect_equal(s$node_runs, 2L)
  expect_true(s$latency_p50 >= 0)
})

test_that("metrics report errors from a failing run", {
  testthat::skip_if_not(python_available())
  agentgraph::metrics_reset()

  bad <- agentgraph::provider_openai(
    api_key = "test", model = "mock", base_url = "http://127.0.0.1:1",
    max_retries = 0L
  )
  g <- agentgraph::state_graph(entry = "n") |>
    agentgraph::add_node("n", agentgraph::llm_node(provider = bad)) |>
    agentgraph::add_edge("n", "__end__")
  e <- err_msg(agentgraph::run(g, state = list(messages = list(agentgraph::user_msg("hi")))))
  expect_false(is.null(e))

  s <- agentgraph::metrics_snapshot()
  expect_equal(s$llm_calls, 1L)
  expect_equal(s$llm_errors, 1L)
  expect_equal(s$error_rate, 1)
})

test_that("metrics report cache hit/miss", {
  testthat::skip_if_not(python_available())
  before <- agentgraph::metrics_snapshot()

  m <- start_mock_llm(list(list(content = "ok")))
  on.exit(stop_py_mock(m), add = TRUE)

  p <- agentgraph::provider_cache(mk_provider(m), ttl_seconds = 60)
  agentgraph::chat("hello", provider = p)
  agentgraph::chat("hello", provider = p)  # cache hit

  s <- agentgraph::metrics_snapshot()
  expect_equal(s$cache_misses - before$cache_misses, 1)
  expect_equal(s$cache_hits - before$cache_hits, 1)
})

test_that("start_metrics_server serves /metrics in Prometheus format", {
  testthat::skip_if_not(python_available())
  testthat::skip_if_not_installed("httpuv")
  testthat::skip_if_not_installed("curl")
  agentgraph::metrics_reset()

  m <- start_mock_llm(list(list(content = "ok")))
  on.exit(stop_py_mock(m), add = TRUE)
  g <- agentgraph::state_graph(entry = "n") |>
    agentgraph::add_node("n", agentgraph::llm_node(provider = mk_provider(m))) |>
    agentgraph::add_edge("n", "__end__")
  agentgraph::run(g, state = list(messages = list(agentgraph::user_msg("hi"))))

  srv <- agentgraph::start_metrics_server(port = 0)
  on.exit(agentgraph::metrics_stop(srv), add = TRUE)

  r <- curl::curl_fetch_memory(paste0(srv$url, "metrics"),
                               handle = curl::new_handle(useragent = "agentgraph"))
  expect_identical(r$status_code, 200L)
  body <- rawToChar(r$content)
  expect_true(grepl("agentgraph_llm_calls_total 1", body, fixed = TRUE))
  expect_true(grepl("agentgraph_llm_latency_ms{quantile=\"0.5\"}", body, fixed = TRUE))
  expect_true(grepl("agentgraph_total_tokens", body, fixed = TRUE))

  out <- capture.output(print(srv))
  expect_true(any(grepl("metrics server", out, fixed = TRUE)))
})

test_that("metrics_reset zeroes the accumulator and stop is a no-op", {
  agentgraph::metrics_reset()
  s <- agentgraph::metrics_snapshot()
  expect_equal(s$llm_calls, 0L)
  expect_equal(s$total_tokens, 0)
  expect_null(agentgraph::metrics_stop(NULL))
})
