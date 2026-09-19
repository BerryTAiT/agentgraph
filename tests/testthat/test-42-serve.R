# REST API wrapper (R/serve.R + inst/tools/serve_agent.R). Uses the mock LLM
# and the stream mock; requires httpuv + curl.

mk_provider <- function(m) {
  agentgraph::provider_openai(
    api_key = "test", model = "mock-model",
    base_url = paste0("http://127.0.0.1:", m$port), max_retries = 0L
  )
}

skip_serve <- function() {
  testthat::skip_if_not(python_available(), "python not available on PATH")
  testthat::skip_if_not_installed("httpuv")
  testthat::skip_if_not_installed("curl")
}

rest_get <- function(url, path) {
  r <- curl::curl_fetch_memory(paste0(url, path),
                               handle = curl::new_handle(useragent = "agentgraph"))
  list(status = r$status_code,
       body = jsonlite::fromJSON(rawToChar(r$content), simplifyVector = FALSE))
}

rest_post <- function(url, path, input, token = NULL) {
  h <- curl::new_handle(useragent = "agentgraph")
  body <- jsonlite::toJSON(list(input = input), auto_unbox = TRUE)
  headers <- "Content-Type: application/json"
  if (!is.null(token)) headers <- c(headers, paste0("Authorization: Bearer ", token))
  curl::handle_setopt(h, post = TRUE, postfields = body, httpheader = headers)
  r <- curl::curl_fetch_memory(paste0(url, path), handle = h)
  list(status = r$status_code,
       body = jsonlite::fromJSON(rawToChar(r$content), simplifyVector = FALSE))
}

test_that("serve_agent validates its target", {
  testthat::skip_if_not_installed("httpuv")
  p <- agentgraph::provider_openai()

  e <- err_msg(agentgraph::serve_agent("nope"))
  expect_true(grepl("agent or a graph", e, fixed = TRUE))

  router <- agentgraph::router_agent(p, list(
    a = agentgraph::chat_agent(p), b = agentgraph::chat_agent(p)))
  e2 <- err_msg(agentgraph::serve_agent(router))
  expect_true(grepl("router_agent", e2, fixed = TRUE))

  e3 <- err_msg(agentgraph::serve_agent(agentgraph::chat_agent(p), auth_token = 42))
  expect_true(grepl("single string", e3, fixed = TRUE))
})

test_that("serve_agent exposes /health and /run (agent target)", {
  skip_serve()
  m <- start_mock_llm(list(list(content = "hi there")))
  on.exit(stop_py_mock(m), add = TRUE)

  srv <- agentgraph::serve_agent(agentgraph::chat_agent(mk_provider(m)), name = "echo")
  on.exit(agentgraph::serve_stop(srv), add = TRUE)

  expect_s3_class(srv, "agentgraph_serve")

  h <- rest_get(srv$url, "health")
  expect_identical(h$status, 200L)
  expect_identical(h$body$status, "ok")

  r <- rest_post(srv$url, "run", "hello")
  expect_identical(r$status, 200L)
  expect_identical(r$body$answer, "hi there")
  expect_false(is.null(r$body$state$messages))

  out <- capture.output(print(srv))
  expect_true(any(grepl("REST server", out, fixed = TRUE)))
})

test_that("serve_agent serves a graph target", {
  skip_serve()
  m <- start_mock_llm(list(list(content = "graph answer")))
  on.exit(stop_py_mock(m), add = TRUE)

  g <- agentgraph::state_graph(entry = "n") |>
    agentgraph::add_node("n", agentgraph::llm_node(provider = mk_provider(m))) |>
    agentgraph::add_edge("n", "__end__")

  srv <- agentgraph::serve_agent(g)
  on.exit(agentgraph::serve_stop(srv), add = TRUE)

  r <- rest_post(srv$url, "run", "do it")
  expect_identical(r$status, 200L)
  expect_identical(r$body$answer, "graph answer")
})

test_that("serve_agent enforces auth on /run but keeps /health open", {
  skip_serve()
  m <- start_mock_llm(list(list(content = "secret answer")))
  on.exit(stop_py_mock(m), add = TRUE)

  srv <- agentgraph::serve_agent(agentgraph::chat_agent(mk_provider(m)),
                                 auth_token = "s3cret")
  on.exit(agentgraph::serve_stop(srv), add = TRUE)

  # health is open
  h <- rest_get(srv$url, "health")
  expect_identical(h$status, 200L)

  # /run without token -> 401
  r <- rest_post(srv$url, "run", "hi")
  expect_identical(r$status, 401L)
  expect_identical(r$body$error, "unauthorized")

  # /run with the token -> 200
  r2 <- rest_post(srv$url, "run", "hi", token = "s3cret")
  expect_identical(r2$status, 200L)
  expect_identical(r2$body$answer, "secret answer")

  # wrong token -> 401
  r3 <- rest_post(srv$url, "run", "hi", token = "wrong")
  expect_identical(r3$status, 401L)
})

test_that("serve_agent /stream returns the captured token sequence", {
  skip_serve()
  s <- start_stream_mock(c("Hel", "lo", " ", "wor", "ld"))
  on.exit(stop_py_mock(s), add = TRUE)

  srv <- agentgraph::serve_agent(agentgraph::chat_agent(mk_provider(s)))
  on.exit(agentgraph::serve_stop(srv), add = TRUE)

  r <- rest_post(srv$url, "stream", "write hello")
  expect_identical(r$status, 200L)
  expect_identical(r$body$answer, "Hello world")
  expect_identical(unlist(r$body$tokens), c("Hel", "lo", " ", "wor", "ld"))
})

test_that("serve_agent returns 400 on missing input and 404 on unknown path", {
  skip_serve()
  m <- start_mock_llm(list(list(content = "ok")))
  on.exit(stop_py_mock(m), add = TRUE)

  srv <- agentgraph::serve_agent(agentgraph::chat_agent(mk_provider(m)))
  on.exit(agentgraph::serve_stop(srv), add = TRUE)

  # empty input -> 400
  h <- curl::new_handle(useragent = "agentgraph")
  curl::handle_setopt(h, post = TRUE, postfields = '{"input":""}',
                      httpheader = "Content-Type: application/json")
  r <- curl::curl_fetch_memory(paste0(srv$url, "run"), handle = h)
  expect_identical(r$status_code, 400L)

  # unknown path -> 404
  r2 <- rest_get(srv$url, "nope")
  expect_identical(r2$status, 404L)

  # serve_stop(NULL) is a safe no-op
  expect_null(agentgraph::serve_stop(NULL))
})
