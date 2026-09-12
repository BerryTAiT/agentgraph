test_that("plain content response parses into fields", {
  r <- agentgraph:::parse_llm_response_cpp(
    '{"model":"m1","choices":[{"message":{"content":"hello"},"finish_reason":"stop"}],"usage":{"prompt_tokens":5,"completion_tokens":2,"total_tokens":7}}'
  )
  expect_identical(r$content, "hello")
  expect_identical(r$finish_reason, "stop")
  expect_identical(r$model, "m1")
  expect_equal(r$prompt_tokens, 5)
  expect_equal(r$completion_tokens, 2)
  expect_equal(r$total_tokens, 7)
  expect_null(r$tool_calls)
})

test_that("tool_calls with null content parse correctly", {
  r <- agentgraph:::parse_llm_response_cpp(
    '{"model":"m2","choices":[{"message":{"content":null,"tool_calls":[{"id":"call_1","function":{"name":"calculator","arguments":"{\\"expression\\":\\"2+3\\"}"}}]},"finish_reason":"tool_calls"}]}'
  )
  expect_identical(r$content, "")
  expect_identical(r$finish_reason, "tool_calls")
  tc <- r$tool_calls[[1]]
  expect_identical(tc$id, "call_1")
  expect_identical(tc$name, "calculator")
  expect_identical(tc$arguments, '{"expression":"2+3"}')
})

test_that("tool_calls with empty (not null) content parse correctly", {
  r <- agentgraph:::parse_llm_response_cpp(
    '{"choices":[{"message":{"content":"","tool_calls":[{"id":"c2","function":{"name":"read_file","arguments":"{\\"path\\":\\"a.txt\\"}"}}]},"finish_reason":"tool_calls"}]}'
  )
  expect_identical(r$content, "")
  expect_length(r$tool_calls, 1L)
  expect_identical(r$tool_calls[[1]]$name, "read_file")
})

test_that("error object maps to error message and finish_reason", {
  r <- agentgraph:::parse_llm_response_cpp(
    '{"error":{"message":"rate limited","type":"rate_limit_error"}}'
  )
  expect_identical(r$finish_reason, "error")
  expect_identical(r$error, "rate limited")
})

test_that("finish_reason length and unknown are surfaced", {
  r <- agentgraph:::parse_llm_response_cpp(
    '{"choices":[{"message":{"content":"cut"},"finish_reason":"length"}]}'
  )
  expect_identical(r$finish_reason, "length")
  expect_identical(r$content, "cut")

  r <- agentgraph:::parse_llm_response_cpp(
    '{"choices":[{"message":{"content":"x"},"finish_reason":"weird"}]}'
  )
  expect_identical(r$finish_reason, "unknown")
})

test_that("malformed JSON throws an error", {
  expect_error(agentgraph:::parse_llm_response_cpp("not json"))
})

test_that("missing choices yields a lenient empty response", {
  r <- agentgraph:::parse_llm_response_cpp('{"model":"x"}')
  expect_identical(r$content, "")
  expect_identical(r$finish_reason, "unknown")
  expect_identical(r$model, "x")
})
