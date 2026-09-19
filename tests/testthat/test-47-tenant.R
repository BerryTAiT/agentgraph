# Multi-tenancy (R/tenant.R).

mk_provider <- function(m) {
  agentgraph::provider_openai(
    api_key = "test", model = "mock-model",
    base_url = paste0("http://127.0.0.1:", m$port), max_retries = 0L
  )
}

mk_graph <- function(m) {
  agentgraph::state_graph(entry = "n") |>
    agentgraph::add_node("n", agentgraph::llm_node(provider = mk_provider(m))) |>
    agentgraph::add_edge("n", "__end__")
}

test_that("tenant validates and reports usage and limits", {
  t <- agentgraph::tenant("cust_a", requests_per_minute = 10, max_requests = 5,
                          max_total_tokens = 1000, max_cost_usd = 0.5)
  expect_s3_class(t, "agentgraph_tenant")
  expect_identical(t$tenant_id, "cust_a")

  u <- agentgraph::tenant_usage("cust_a")
  expect_identical(u$requests, 0L)
  expect_identical(u$requests_per_minute, 10L)
  expect_identical(u$max_requests, 5L)
  expect_identical(u$max_total_tokens, 1000)
  expect_identical(u$max_cost_usd, 0.5)

  out <- capture.output(print(t))
  expect_true(any(grepl("cust_a", out, fixed = TRUE)))

  e <- err_msg(agentgraph::tenant(""))
  expect_true(grepl("non-empty", e, fixed = TRUE))

  agentgraph::tenant_reset("cust_a")
})

test_that("run(tenant=) records per-tenant usage", {
  testthat::skip_if_not(python_available())
  m <- start_mock_llm(list(list(content = "ok")))
  on.exit(stop_py_mock(m), add = TRUE)

  t <- agentgraph::tenant("cust_b")
  agentgraph::tenant_reset("cust_b")
  g <- mk_graph(m)

  agentgraph::run(g, state = list(messages = list(agentgraph::user_msg("hi"))), tenant = t)

  u <- agentgraph::tenant_usage("cust_b")
  expect_identical(u$requests, 1L)
  expect_equal(u$total_tokens, 15)  # mock default usage
})

test_that("tenant max_requests cap blocks further runs", {
  testthat::skip_if_not(python_available())
  m <- start_mock_llm(list(list(content = "ok")))
  on.exit(stop_py_mock(m), add = TRUE)

  t <- agentgraph::tenant("cust_c", max_requests = 1)
  agentgraph::tenant_reset("cust_c")
  g <- mk_graph(m)

  agentgraph::run(g, state = list(messages = list(agentgraph::user_msg("hi"))), tenant = t)
  e <- err_msg(agentgraph::run(g, state = list(messages = list(agentgraph::user_msg("hi"))), tenant = t))
  expect_true(grepl("max_requests exceeded", e, fixed = TRUE))
})

test_that("tenant rate limit blocks a burst", {
  testthat::skip_if_not(python_available())
  m <- start_mock_llm(list(list(content = "ok")))
  on.exit(stop_py_mock(m), add = TRUE)

  t <- agentgraph::tenant("cust_d", requests_per_minute = 1)
  agentgraph::tenant_reset("cust_d")
  g <- mk_graph(m)

  agentgraph::run(g, state = list(messages = list(agentgraph::user_msg("hi"))), tenant = t)
  e <- err_msg(agentgraph::run(g, state = list(messages = list(agentgraph::user_msg("hi"))), tenant = t))
  expect_true(grepl("rate limit exceeded", e, fixed = TRUE))
})

test_that("tenant writes an audit log and tenant_audit reads it", {
  testthat::skip_if_not(python_available())
  m <- start_mock_llm(list(list(content = "ok")))
  on.exit(stop_py_mock(m), add = TRUE)

  ap <- tempfile(fileext = ".jsonl")
  t <- agentgraph::tenant("cust_e", audit_path = ap)
  agentgraph::tenant_reset("cust_e")
  g <- mk_graph(m)

  agentgraph::run(g, state = list(messages = list(agentgraph::user_msg("hi"))), tenant = t)

  aud <- agentgraph::tenant_audit("cust_e")
  expect_equal(nrow(aud), 1L)
  expect_identical(aud$tenant_id, "cust_e")
  expect_equal(aud$tokens, 15)
})

test_that("tenant_namespace prefixes names and run validates tenant", {
  expect_identical(agentgraph::tenant_namespace("abc", "docs"), "abc::docs")

  e <- err_msg(agentgraph::run(
    agentgraph::state_graph(entry = "n"),
    state = list(messages = list(agentgraph::user_msg("hi"))),
    tenant = "not-a-tenant"))
  expect_true(grepl("tenant()", e, fixed = TRUE))

  e2 <- err_msg(agentgraph::tenant_usage("no-such-tenant"))
  expect_true(grepl("tenant not found", e2, fixed = TRUE))

  agentgraph::tenant_reset()  # reset all
})
