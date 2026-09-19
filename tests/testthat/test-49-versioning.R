# Agent versioning & A/B (R/versioning.R).

test_that("save_agent / load_agent / agent_versions round-trip a graph", {
  d <- tempfile()
  g <- agentgraph::state_graph(entry = "n") |>
    agentgraph::add_node("n", agentgraph::llm_node(provider = agentgraph::provider_openai()))

  agentgraph::save_agent(g, "my_agent", "1.0.0", dir = d)
  agentgraph::save_agent(g, "my_agent", "2.0.0", dir = d)

  expect_identical(agentgraph::agent_versions("my_agent", dir = d), c("1.0.0", "2.0.0"))

  # latest
  loaded <- agentgraph::load_agent("my_agent", dir = d)
  expect_identical(loaded$entry_point, "n")
  # explicit version
  v1 <- agentgraph::load_agent("my_agent", "1.0.0", dir = d)
  expect_identical(v1$entry_point, "n")

  e <- err_msg(agentgraph::load_agent("my_agent", "9.9.9", dir = d))
  expect_true(grepl("not found", e, fixed = TRUE))
})

test_that("save_agent / load_agent round-trip an agent", {
  d <- tempfile()
  a <- agentgraph::chat_agent(agentgraph::provider_openai(), system_prompt = "be nice")
  agentgraph::save_agent(a, "chatbot", "1.0.0", dir = d)
  loaded <- agentgraph::load_agent("chatbot", dir = d)
  expect_s3_class(loaded, "agentgraph_agent")
})

test_that("save_agent validates its inputs", {
  d <- tempfile()
  e <- err_msg(agentgraph::save_agent("nope", "x", dir = d))
  expect_true(grepl("agent or a graph", e, fixed = TRUE))

  p <- agentgraph::provider_openai()
  router <- agentgraph::router_agent(p, list(a = agentgraph::chat_agent(p), b = agentgraph::chat_agent(p)))
  e2 <- err_msg(agentgraph::save_agent(router, "r", dir = d))
  expect_true(grepl("router_agent", e2, fixed = TRUE))

  e3 <- err_msg(agentgraph::save_agent(agentgraph::state_graph(entry = "n"), "", dir = d))
  expect_true(grepl("non-empty", e3, fixed = TRUE))
})

test_that("agent_versions returns empty for an unknown name", {
  d <- tempfile()
  expect_identical(agentgraph::agent_versions("no_such", dir = d), character(0))
  e <- err_msg(agentgraph::load_agent("no_such", dir = d))
  expect_true(grepl("no agent named", e, fixed = TRUE))
})

test_that("ab_evaluate compares two function targets", {
  a <- function(x) if (identical(x, "2+2")) "4" else "wrong"
  b <- function(x) if (identical(x, "2+2")) "5" else "wrong"
  ds <- agentgraph::eval_dataset(c("2+2", "3+3"), c("4", "6"))

  ab <- agentgraph::ab_evaluate(a, b, ds, list(agentgraph::eval_exact_match()))
  expect_s3_class(ab, "agentgraph_ab")
  expect_equal(ab$score_a, 0.5)  # a correct on "2+2", wrong on "3+3"
  expect_equal(ab$score_b, 0)
  expect_identical(ab$winner, "a")

  out <- capture.output(print(ab))
  expect_true(any(grepl("winner: a", out, fixed = TRUE)))
})

test_that("ab_evaluate compares two graphs (mock LLM)", {
  testthat::skip_if_not(python_available())
  m <- start_mock_llm(list(list(content = "Paris"), list(content = "Paris"),
                           list(content = "London"), list(content = "London")))
  on.exit(stop_py_mock(m), add = TRUE)

  p <- agentgraph::provider_openai(
    api_key = "test", model = "mock-model",
    base_url = paste0("http://127.0.0.1:", m$port), max_retries = 0L
  )
  mk <- function() {
    agentgraph::state_graph(entry = "n") |>
      agentgraph::add_node("n", agentgraph::llm_node(provider = p)) |>
      agentgraph::add_edge("n", "__end__")
  }
  ds <- agentgraph::eval_dataset(c("capital of France", "capital of France"), c("Paris", "Paris"))
  ab <- agentgraph::ab_evaluate(mk(), mk(), ds, list(agentgraph::eval_exact_match()))
  expect_true(ab$score_a %in% c(0, 0.5, 1))
  expect_true(ab$score_b %in% c(0, 0.5, 1))
})
