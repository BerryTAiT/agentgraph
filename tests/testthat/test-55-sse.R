# SSE server (R/sse.R + inst/tools/sse_server.R).

mk_provider <- function(m) {
  agentgraph::provider_openai(
    api_key = "test", model = "mock-model",
    base_url = paste0("http://127.0.0.1:", m$port), max_retries = 0L
  )
}

test_that("start_sse_server validates its target", {
  testthat::skip_if_not_installed("httpuv")
  p <- agentgraph::provider_openai()
  e <- err_msg(agentgraph::start_sse_server("nope"))
  expect_true(grepl("agent or a graph", e, fixed = TRUE))

  router <- agentgraph::router_agent(p, list(a = agentgraph::chat_agent(p), b = agentgraph::chat_agent(p)))
  e2 <- err_msg(agentgraph::start_sse_server(router))
  expect_true(grepl("router_agent", e2, fixed = TRUE))
})

test_that("start_sse_server streams tokens as SSE (POST)", {
  testthat::skip_if_not(python_available())
  testthat::skip_if_not_installed("httpuv")
  testthat::skip_if_not_installed("curl")
  s <- start_stream_mock(c("Hel", "lo", " ", "wor", "ld"))
  on.exit(stop_py_mock(s), add = TRUE)

  srv <- agentgraph::start_sse_server(agentgraph::chat_agent(mk_provider(s)))
  on.exit(agentgraph::sse_stop(srv), add = TRUE)

  h <- curl::new_handle(useragent = "agentgraph")
  curl::handle_setopt(h, post = TRUE, postfields = '{"input":"write hello"}',
                      httpheader = "Content-Type: application/json")
  r <- curl::curl_fetch_memory(paste0(srv$url, "stream"), handle = h)
  expect_identical(r$status_code, 200L)
  expect_true(grepl("text/event-stream", r$type, fixed = TRUE))

  body <- rawToChar(r$content)
  expect_true(grepl("data: Hel", body, fixed = TRUE))
  expect_true(grepl("data: ld", body, fixed = TRUE))
  expect_true(grepl("data: [DONE]", body, fixed = TRUE))

  out <- capture.output(print(srv))
  expect_true(any(grepl("SSE server", out, fixed = TRUE)))
})

test_that("start_sse_server streams via GET query string", {
  testthat::skip_if_not(python_available())
  testthat::skip_if_not_installed("httpuv")
  testthat::skip_if_not_installed("curl")
  s <- start_stream_mock(c("ab", "c"))
  on.exit(stop_py_mock(s), add = TRUE)

  srv <- agentgraph::start_sse_server(agentgraph::chat_agent(mk_provider(s)))
  on.exit(agentgraph::sse_stop(srv), add = TRUE)

  r <- curl::curl_fetch_memory(paste0(srv$url, "stream?input=hi%20there"),
                               handle = curl::new_handle(useragent = "agentgraph"))
  expect_identical(r$status_code, 200L)
  expect_true(grepl("data: ab", rawToChar(r$content), fixed = TRUE))
})

test_that("start_sse_server enforces auth on /stream", {
  testthat::skip_if_not(python_available())
  testthat::skip_if_not_installed("httpuv")
  testthat::skip_if_not_installed("curl")
  s <- start_stream_mock(c("x", "y"))
  on.exit(stop_py_mock(s), add = TRUE)

  srv <- agentgraph::start_sse_server(agentgraph::chat_agent(mk_provider(s)), auth_token = "tok")
  on.exit(agentgraph::sse_stop(srv), add = TRUE)

  # without token -> 401
  h <- curl::new_handle(useragent = "agentgraph")
  curl::handle_setopt(h, post = TRUE, postfields = '{"input":"x"}',
                      httpheader = "Content-Type: application/json")
  r <- curl::curl_fetch_memory(paste0(srv$url, "stream"), handle = h)
  expect_identical(r$status_code, 401L)

  # with token -> 200
  h2 <- curl::new_handle(useragent = "agentgraph")
  curl::handle_setopt(h2, post = TRUE, postfields = '{"input":"x"}',
                      httpheader = c("Content-Type: application/json",
                                     "Authorization: Bearer tok"))
  r2 <- curl::curl_fetch_memory(paste0(srv$url, "stream"), handle = h2)
  expect_identical(r2$status_code, 200L)

  expect_null(agentgraph::sse_stop(NULL))
})
