# Top-level R API contract (chat / chat_parallel / provider) plus the gated
# live DeepSeek smoke test. The live section is skipped unless
# AGENTGRAPH_API_KEY is set in the environment.

test_that("chat() surfaces content, finish_reason, model, and usage", {
  testthat::skip_if_not(python_available())
  m <- start_mock_llm(list(list(
    finish_reason = "stop", content = "Hi", model = "mock-gpt",
    usage = list(prompt_tokens = 7, completion_tokens = 3, total_tokens = 10)
  )))
  on.exit(stop_py_mock(m), add = TRUE)
  p <- mock_provider(m, model = "mock-gpt")

  r <- chat("hello", p, system_prompt = "SYS")
  expect_identical(r$content, "Hi")
  expect_identical(r$finish_reason, "stop")
  expect_identical(r$model, "mock-gpt")
  expect_equal(r$total_tokens, 10L)

  log1 <- read_log(m)
  expect_true(grepl('"role":"system"', log1, fixed = TRUE))
  expect_true(grepl('"content":"SYS"', log1, fixed = TRUE))
  expect_true(grepl('"content":"hello"', log1, fixed = TRUE))
})

test_that("chat() omits the system role when no system prompt is given", {
  testthat::skip_if_not(python_available())
  m <- start_mock_llm(list(list(content = "ok")))
  on.exit(stop_py_mock(m), add = TRUE)
  p <- mock_provider(m, model = "mm")

  invisible(chat("hello", p))
  log1 <- read_log(m)
  expect_false(grepl('"role":"system"', log1, fixed = TRUE))
})

test_that("chat() passes tool_calls through the wrapper", {
  testthat::skip_if_not(python_available())
  m <- start_mock_llm(list(list(
    finish_reason = "tool_calls", content = "",
    tool_calls = list(list(id = "c1", name = "calculator",
                           arguments = '{"expr":"1+1"}')),
    model = "mm"
  )))
  on.exit(stop_py_mock(m), add = TRUE)
  p <- mock_provider(m, model = "mm")

  r <- chat("calc 1+1", p)
  expect_identical(r$finish_reason, "tool_calls")
  expect_identical(r$tool_calls[[1]]$name, "calculator")
  expect_identical(
    jsonlite::fromJSON(r$tool_calls[[1]]$arguments, simplifyVector = FALSE)$expr,
    "1+1"
  )
})

test_that("chat_parallel() returns results in request order", {
  testthat::skip_if_not(python_available())
  m <- start_mock_llm(list(list(content = "par-ok")))
  on.exit(stop_py_mock(m), add = TRUE)
  p <- mock_provider(m, model = "mm")

  msgs <- list(list(user_msg("a")), list(user_msg("b")), list(user_msg("c")))
  out <- chat_parallel(msgs, p, n_threads = 2)
  expect_length(out, 3L)
  expect_identical(out[[1]]$content, "par-ok")
  expect_identical(out[[3]]$content, "par-ok")
})

test_that("gated live DeepSeek smoke test", {
  key <- Sys.getenv("AGENTGRAPH_API_KEY")
  testthat::skip_if_not(nzchar(key), "AGENTGRAPH_API_KEY not set")

  base_live <- Sys.getenv("AGENTGRAPH_BASE_URL", "https://api.mstech.ai/v1")
  model_live <- Sys.getenv("AGENTGRAPH_MODEL", "deepseek-v4-flash")
  p <- provider_openai(api_key = key, model = model_live, base_url = base_live)

  r <- tryCatch(chat("Reply with exactly one word: PONG", p),
                error = function(e) NULL)
  expect_true(!is.null(r) && nzchar(r$content))

  tokens <- 0
  g <- state_graph(entry = "gen") |>
    add_node("gen", llm_node(provider = p, system_prompt = "Say hello.")) |>
    add_edge("gen", "__end__")
  s <- tryCatch(stream(g, state = list(messages = list(user_msg("hi"))),
                       on_token = function(t) tokens <<- tokens + 1),
                error = function(e) NULL)
  expect_true(!is.null(s))
  expect_true(tokens > 0)
})
