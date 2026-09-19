# A2A protocol (R/a2a.R + inst/tools/a2a_server.R). The round-trip tests use
# a Python mock LLM and the httpuv/curl packages (all Suggests).

mk_provider <- function(m) {
  agentgraph::provider_openai(
    api_key = "test", model = "mock-model",
    base_url = paste0("http://127.0.0.1:", m$port),
    max_retries = 0L
  )
}

skip_a2a <- function() {
  testthat::skip_if_not(python_available(), "python not available on PATH")
  testthat::skip_if_not_installed("httpuv")
  testthat::skip_if_not_installed("curl")
}

test_that("agent_card builds a well-formed card", {
  card <- agentgraph::agent_card("translator", description = "translates text",
                                 skills = list(list(id = "s1", name = "translate",
                                                    description = "translate")))
  expect_identical(card$name, "translator")
  expect_identical(card$description, "translates text")
  expect_identical(card$version, "0.0.1")
  expect_identical(card$protocolVersion, "0.3.0")
  expect_identical(card$defaultInputModes, list("text/plain"))
  expect_identical(card$defaultOutputModes, list("text/plain"))
  expect_identical(card$skills[[1]]$id, "s1")
  expect_false(card$capabilities$streaming)

  e <- err_msg(agentgraph::agent_card(""))
  expect_true(grepl("non-empty", e, fixed = TRUE))
})

test_that("a2a_server validates its agent", {
  testthat::skip_if_not_installed("httpuv")
  p <- agentgraph::provider_openai()

  e <- err_msg(agentgraph::a2a_server("not an agent"))
  expect_true(grepl("*_agent()", e, fixed = TRUE))

  # router_agent() carries an R closure and cannot be served
  router <- agentgraph::router_agent(p, list(
    a = agentgraph::chat_agent(p), b = agentgraph::chat_agent(p)))
  e2 <- err_msg(agentgraph::a2a_server(router))
  expect_true(grepl("router_agent", e2, fixed = TRUE))
})

test_that("a2a_server round-trips a chat agent (mock LLM)", {
  skip_a2a()
  m <- start_mock_llm(list(list(content = "hello from a2a")))
  on.exit(stop_py_mock(m), add = TRUE)

  agent <- agentgraph::chat_agent(mk_provider(m), system_prompt = "be brief")
  srv <- agentgraph::a2a_server(agent, name = "echo")
  on.exit(agentgraph::a2a_stop(srv), add = TRUE)

  expect_s3_class(srv, "agentgraph_a2a_server")
  expect_true(nzchar(srv$url))
  expect_identical(srv$card$name, "echo")
  expect_identical(srv$card$url, srv$url)

  # card fetch
  card <- agentgraph::a2a_agent_card(srv$url)
  expect_identical(card$name, "echo")
  expect_identical(card$url, srv$url)

  # tasks/send
  ans <- agentgraph::a2a_send(srv$url, "hi there")
  expect_identical(ans, "hello from a2a")

  # wrap as a local agent and run it
  remote <- agentgraph::a2a_agent(srv$url)
  expect_true(agentgraph::run_agent(remote, "again")$answer == "hello from a2a")

  out <- capture.output(print(srv))
  expect_true(any(grepl("A2A server", out, fixed = TRUE)))
})

test_that("a2a server implements message/send and JSON-RPC errors", {
  skip_a2a()
  m <- start_mock_llm(list(list(content = "stateless reply")))
  on.exit(stop_py_mock(m), add = TRUE)

  agent <- agentgraph::chat_agent(mk_provider(m))
  srv <- agentgraph::a2a_server(agent, name = "msg")
  on.exit(agentgraph::a2a_stop(srv), add = TRUE)

  # message/send (stateless) via a raw JSON-RPC request
  req <- jsonlite::toJSON(
    list(jsonrpc = "2.0", id = "m1", method = "message/send",
         params = list(message = list(role = "user",
                                      parts = list(list(type = "text",
                                                        text = "ping"))))),
    auto_unbox = TRUE
  )
  h <- curl::new_handle(useragent = "agentgraph")
  curl::handle_setopt(h, post = TRUE, postfields = req,
                      httpheader = "Content-Type: application/json")
  r <- curl::curl_fetch_memory(srv$url, handle = h)
  resp <- jsonlite::fromJSON(rawToChar(r$content), simplifyVector = FALSE)
  expect_identical(resp$id, "m1")
  expect_identical(resp$result$role, "agent")
  expect_identical(resp$result$parts[[1]]$text, "stateless reply")

  # unknown method -> JSON-RPC -32601 error
  req2 <- jsonlite::toJSON(
    list(jsonrpc = "2.0", id = "m2", method = "tasks/cancel", params = list()),
    auto_unbox = TRUE
  )
  curl::handle_setopt(h, postfields = req2)
  r2 <- curl::curl_fetch_memory(srv$url, handle = h)
  resp2 <- jsonlite::fromJSON(rawToChar(r2$content), simplifyVector = FALSE)
  expect_equal(resp2$error$code, -32601)
  expect_true(grepl("not supported", resp2$error$message, fixed = TRUE))
})

test_that("a2a clients error cleanly against a dead endpoint", {
  testthat::skip_if_not_installed("curl")
  dead <- "http://127.0.0.1:1/"

  e <- err_msg(agentgraph::a2a_send(dead, "hi"))
  expect_false(is.null(e))

  e2 <- err_msg(agentgraph::a2a_agent_card(dead))
  expect_false(is.null(e2))
})

test_that("a2a_agent validates its URL", {
  e <- err_msg(agentgraph::a2a_agent(42))
  expect_true(grepl("non-empty", e, fixed = TRUE))

  e2 <- err_msg(agentgraph::a2a_send(42, "hi"))
  expect_true(grepl("non-empty", e2, fixed = TRUE))

  # a2a_stop(NULL) is a safe no-op
  expect_null(agentgraph::a2a_stop(NULL))
})
