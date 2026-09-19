# Cost tracking (R/cost.R + C++ usage registry). Uses the mock LLM for token
# counts; the mock returns usage {prompt_tokens:10, completion_tokens:5,
# total_tokens:15} per response by default.

mk_provider <- function(m, model = "mock-model", ...) {
  agentgraph::provider_openai(
    api_key = "test", model = model,
    base_url = paste0("http://127.0.0.1:", m$port),
    max_retries = 0L, ...
  )
}

test_that("estimate_cost computes from the pricing table", {
  # gpt-4o: $2.50 in, $10.00 out per 1M
  expect_equal(agentgraph::estimate_cost(1000, 2000, "gpt-4o"),
               (1000 * 2.50 + 2000 * 10.00) / 1e6)
  # custom table
  custom <- list(m = c(input = 1, output = 2))
  expect_equal(agentgraph::estimate_cost(500, 500, "m", prices = custom),
               (500 * 1 + 500 * 2) / 1e6)

  e <- err_msg(agentgraph::estimate_cost(1, 1, "no-such-model"))
  expect_true(grepl("no price", e, fixed = TRUE))
})

test_that("agentgraph_prices is a named list of input/output pairs", {
  expect_true(is.list(agentgraph::agentgraph_prices))
  expect_true(all(vapply(agentgraph::agentgraph_prices,
                         function(x) all(c("input", "output") %in% names(x)),
                         logical(1))))
  expect_true("gpt-4o" %in% names(agentgraph::agentgraph_prices))
})

test_that("provider_pricing attaches prices and validates", {
  p <- agentgraph::provider_openai()
  pp <- agentgraph::provider_pricing(p, input_per_1m = 1.5, output_per_1m = 7)
  expect_equal(pp$input_price_per_1m, 1.5)
  expect_equal(pp$output_price_per_1m, 7)
  expect_identical(pp$name, "openai")

  e <- err_msg(agentgraph::provider_pricing("nope", 1, 2))
  expect_true(grepl("provider configuration", e, fixed = TRUE))
})

test_that("agentgraph_usage accumulates tokens and cost across runs", {
  testthat::skip_if_not(python_available())
  agentgraph::usage_reset()

  m <- start_mock_llm(list(list(content = "ok")))
  on.exit(stop_py_mock(m), add = TRUE)

  p <- agentgraph::provider_pricing(mk_provider(m), input_per_1m = 1, output_per_1m = 2)
  agentgraph::chat("hello", provider = p)

  u <- agentgraph::agentgraph_usage()
  expect_equal(u$prompt_tokens, 10)
  expect_equal(u$completion_tokens, 5)
  expect_equal(u$total_tokens, 15)
  # (10 * 1 + 5 * 2) / 1e6 = 20 / 1e6
  expect_equal(u$cost_usd, 20 / 1e6)

  # a second call doubles it
  agentgraph::chat("again", provider = p)
  u2 <- agentgraph::agentgraph_usage()
  expect_equal(u2$total_tokens, 30)
  expect_equal(u2$cost_usd, 40 / 1e6)

  # reset clears it
  agentgraph::usage_reset()
  u3 <- agentgraph::agentgraph_usage()
  expect_equal(u3$total_tokens, 0)
  expect_equal(u3$cost_usd, 0)
})

test_that("agentgraph_usage ignores cost for unpriced providers", {
  testthat::skip_if_not(python_available())
  agentgraph::usage_reset()

  m <- start_mock_llm(list(list(content = "ok")))
  on.exit(stop_py_mock(m), add = TRUE)

  agentgraph::chat("hello", provider = mk_provider(m))  # no pricing

  u <- agentgraph::agentgraph_usage()
  expect_equal(u$total_tokens, 15)
  expect_equal(u$cost_usd, 0)
})

test_that("max_cost_usd aborts a run when the estimated cost is exceeded", {
  testthat::skip_if_not(python_available())
  m <- start_mock_llm(list(list(content = "a"), list(content = "b"), list(content = "c")))
  on.exit(stop_py_mock(m), add = TRUE)

  # price $1000 in / $1000 out per 1M => each 15-token call costs 0.015 USD
  p <- agentgraph::provider_pricing(mk_provider(m), input_per_1m = 1000, output_per_1m = 1000)

  g <- agentgraph::state_graph(entry = "a") |>
    agentgraph::add_node("a", agentgraph::llm_node(provider = p)) |>
    agentgraph::add_node("b", agentgraph::llm_node(provider = p)) |>
    agentgraph::add_node("c", agentgraph::llm_node(provider = p)) |>
    agentgraph::add_edge("a", "b") |>
    agentgraph::add_edge("b", "c") |>
    agentgraph::add_edge("c", "__end__")

  # 3 calls * 0.015 = 0.045; cap at 0.02 triggers after the 2nd call (0.03)
  e <- err_msg(agentgraph::run(g, state = list(messages = list(agentgraph::user_msg("hi"))),
                               max_cost_usd = 0.02))
  expect_true(grepl("max_cost_usd", e, fixed = TRUE))

  # under the cap -> completes
  r <- agentgraph::run(g, state = list(messages = list(agentgraph::user_msg("hi"))),
                       max_cost_usd = 1)
  expect_identical(tail(r$messages, 1)[[1]]$content, "c")
})
