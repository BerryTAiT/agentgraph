test_that("hello and http_get C++ hooks respond", {
  expect_identical(agentgraph:::hello_cpp(), "agentgraph C++ engine is alive")

  m <- start_mock_llm(list(list(content = "ignored")))
  on.exit(stop_py_mock(m), add = TRUE)
  base <- paste0("http://127.0.0.1:", m$port)
  h <- agentgraph:::http_get_cpp(paste0(base, "/ping"))
  expect_identical(h$status_code, 200L)
  expect_identical(h$body_length, 2L)
  expect_identical(h$body_preview, "OK")
})

test_that("parse_llm_response_cpp handles all shapes offline", {
  parse <- agentgraph:::parse_llm_response_cpp

  full <- '{"id":"x","model":"gpt-4o","choices":[{"index":0,"message":{"role":"assistant","content":"Hello world"},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}'
  r <- parse(full)
  expect_identical(r$content, "Hello world")
  expect_identical(r$finish_reason, "stop")
  expect_identical(r$model, "gpt-4o")
  expect_identical(r$prompt_tokens, 10L)
  expect_identical(r$completion_tokens, 5L)
  expect_identical(r$total_tokens, 15L)
  expect_null(r$error)
  expect_null(r$tool_calls)

  tc <- '{"model":"gpt-4o","choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_1","type":"function","function":{"name":"calculator","arguments":"{\\"expr\\":\\"2+2\\"}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":1,"completion_tokens":2,"total_tokens":3}}'
  r2 <- parse(tc)
  expect_identical(r2$content, "")
  expect_identical(r2$finish_reason, "tool_calls")
  expect_identical(r2$tool_calls[[1]]$id, "call_1")
  expect_identical(r2$tool_calls[[1]]$name, "calculator")
  expect_identical(
    jsonlite::fromJSON(r2$tool_calls[[1]]$arguments, simplifyVector = FALSE)$expr,
    "2+2"
  )

  nullc <- '{"model":"m","choices":[{"message":{"role":"assistant","content":null},"finish_reason":"stop"}]}'
  expect_identical(parse(nullc)$content, "")

  errjson <- '{"error":{"message":"boom","type":"server_error"}}'
  r4 <- parse(errjson)
  expect_identical(r4$error, "boom")
  expect_identical(r4$finish_reason, "error")

  nodefault <- '{"choices":[{"message":{"role":"assistant","content":"hi"},"finish_reason":"length"}]}'
  r5 <- parse(nodefault)
  expect_identical(r5$model, "")
  expect_identical(r5$total_tokens, 0L)
  expect_identical(r5$finish_reason, "length")

  bad <- err_msg(parse("{not json"))
  expect_true(grepl("Failed to parse LLM response", bad, fixed = TRUE))
})

test_that("chat_native_cpp hits the mock and propagates errors", {
  chat <- agentgraph:::chat_native_cpp
  prov <- function(key, model, base) {
    list(name = "openai", api_key = key, model = model, base_url = base)
  }
  msg1 <- list(list(role = "user", content = "hello"))

  m <- start_mock_llm(list(list(
    finish_reason = "stop", content = "Hi from mock", model = "mock-gpt",
    usage = list(prompt_tokens = 7, completion_tokens = 3, total_tokens = 10)
  )))
  on.exit(stop_py_mock(m), add = TRUE)
  base <- paste0("http://127.0.0.1:", m$port)
  r <- chat(prov("test-key", "mock-gpt", base), msg1, "SYS")
  expect_identical(r$content, "Hi from mock")
  expect_identical(r$finish_reason, "stop")
  expect_identical(r$model, "mock-gpt")
  expect_identical(r$prompt_tokens, 7L)
  expect_identical(r$total_tokens, 10L)
  stop_py_mock(m)

  m <- start_mock_llm(list(list(content = "hi")))
  base <- paste0("http://127.0.0.1:", m$port)
  invisible(chat(prov("k", "mm", base), msg1, "SYS"))
  Sys.sleep(0.3)
  log1 <- paste(readLines(m$log, warn = FALSE), collapse = "\n")
  expect_true(grepl('"role":"system"', log1, fixed = TRUE))
  expect_true(grepl('"content":"SYS"', log1, fixed = TRUE))
  expect_true(grepl('"content":"hello"', log1, fixed = TRUE))
  stop_py_mock(m)

  m <- start_mock_llm(list(list(
    finish_reason = "tool_calls", content = "",
    tool_calls = list(list(id = "call_9", name = "calculator",
                           arguments = '{"expr":"3*4"}')),
    model = "mock-gpt"
  )))
  base <- paste0("http://127.0.0.1:", m$port)
  r <- chat(prov("k", "mock-gpt", base), msg1, "")
  expect_identical(r$finish_reason, "tool_calls")
  expect_identical(r$tool_calls[[1]]$name, "calculator")
  expect_identical(
    jsonlite::fromJSON(r$tool_calls[[1]]$arguments, simplifyVector = FALSE)$expr,
    "3*4"
  )
  stop_py_mock(m)

  m <- start_mock_llm(list(list(status = 500, content = "x")))
  base <- paste0("http://127.0.0.1:", m$port)
  e <- err_msg(chat(prov("k", "mm", base), msg1, ""))
  expect_true(grepl("API error (500)", e, fixed = TRUE))
  stop_py_mock(m)

  e <- err_msg(chat(prov("k", "mm", "http://127.0.0.1:1"), msg1, ""))
  expect_true(!is.null(e) && grepl("failed", e, fixed = TRUE))
})

test_that("chat_parallel_cpp fans out and reports per-call errors", {
  par <- agentgraph:::chat_parallel_cpp
  prov <- function(key, model, base) {
    list(name = "openai", api_key = key, model = model, base_url = base)
  }
  msgs <- list(
    list(list(role = "user", content = "q1")),
    list(list(role = "user", content = "q2")),
    list(list(role = "user", content = "q3"))
  )

  m <- start_mock_llm(list(list(content = "parallel-ok")))
  on.exit(stop_py_mock(m), add = TRUE)
  base <- paste0("http://127.0.0.1:", m$port)
  out <- par(prov("k", "mm", base), msgs, "", 4)
  expect_length(out, 3L)
  expect_identical(out[[1]]$content, "parallel-ok")
  expect_identical(out[[2]]$content, "parallel-ok")
  expect_identical(out[[3]]$content, "parallel-ok")
  Sys.sleep(0.3)
  log1 <- paste(readLines(m$log, warn = FALSE), collapse = "\n")
  expect_true(grepl('"content":"q1"', log1, fixed = TRUE))
  expect_true(grepl('"content":"q2"', log1, fixed = TRUE))
  expect_true(grepl('"content":"q3"', log1, fixed = TRUE))
  stop_py_mock(m)

  m <- start_mock_llm(list(list(content = "seq-ok")))
  base <- paste0("http://127.0.0.1:", m$port)
  out <- par(prov("k", "mm", base), msgs, "", 0)
  expect_length(out, 3L)
  expect_identical(out[[1]]$content, "seq-ok")
  expect_identical(out[[3]]$content, "seq-ok")
  stop_py_mock(m)

  m <- start_mock_llm(list(list(status = 500, content = "x")))
  base <- paste0("http://127.0.0.1:", m$port)
  out <- par(prov("k", "mm", base), msgs, "", 4)
  expect_length(out, 3L)
  expect_true(grepl("API error (500)", out[[1]]$error, fixed = TRUE))
  expect_true(grepl("API error (500)", out[[2]]$error, fixed = TRUE))
  expect_true(grepl("API error (500)", out[[3]]$error, fixed = TRUE))
  stop_py_mock(m)

  out <- par(prov("k", "mm", "http://127.0.0.1:1"), list(), "", 4)
  expect_length(out, 0L)
})
