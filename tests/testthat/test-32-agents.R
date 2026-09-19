# Pre-built agent patterns (R/agents.R) using the Python mock LLM server.

mk_provider <- function(m) {
  agentgraph::provider_openai(
    api_key = "test", model = "mock-model",
    base_url = paste0("http://127.0.0.1:", m$port),
    max_retries = 0L
  )
}

count_requests <- function(m) {
  f <- m$log
  if (!file.exists(f)) return(0L)
  length(readLines(f, warn = FALSE))
}

run_ag <- function(agent, input, ...) {
  agentgraph::run_agent(agent, input, ...)
}

test_that("chat_agent returns the model's answer", {
  testthat::skip_if_not(python_available())
  m <- start_mock_llm(list(list(content = "hello there")))
  on.exit(stop_py_mock(m), add = TRUE)

  agent <- agentgraph::chat_agent(mk_provider(m), system_prompt = "be nice")
  r <- run_ag(agent, "hi")

  expect_identical(r$answer, "hello there")
  expect_identical(tail(r$state$messages, 1)[[1]]$role, "assistant")
  Sys.sleep(0.1)
  expect_identical(count_requests(m), 1L)
})

test_that("react_agent runs the tool loop and returns the final answer", {
  testthat::skip_if_not(python_available())
  m <- start_mock_llm(list(
    list(finish_reason = "tool_calls",
         tool_calls = list(list(id = "call_1", name = "shout",
                                arguments = '{"text":"hi"}'))),
    list(finish_reason = "stop", content = "The result is HI!!")
  ))
  on.exit(stop_py_mock(m), add = TRUE)

  shout_tool <- agentgraph::tool(
    name = "shout",
    description = "Uppercase text and add emphasis",
    parameters = list(text = agentgraph::param_string("Text")),
    handler = function(args_json) {
      args <- jsonlite::fromJSON(args_json, simplifyVector = FALSE)
      jsonlite::toJSON(list(result = paste0(toupper(args$text), "!!")),
                       auto_unbox = TRUE)
    }
  )

  agent <- agentgraph::react_agent(mk_provider(m), tools = list(shout_tool))
  r <- run_ag(agent, "shout hi")

  expect_identical(r$answer, "The result is HI!!")

  tool_msgs <- Filter(function(x) identical(x$role, "tool"), r$state$messages)
  expect_length(tool_msgs, 1L)
  expect_identical(jsonlite::fromJSON(tool_msgs[[1]]$content)$result, "HI!!")

  Sys.sleep(0.1)
  expect_identical(count_requests(m), 2L)
})

test_that("react_agent validates its tools", {
  p <- agentgraph::provider_openai()
  e <- err_msg(agentgraph::react_agent(p, tools = list("not a tool")))
  expect_false(is.null(e))
  expect_true(grepl("tool definition", e, fixed = TRUE))
})

test_that("plan_execute_agent chains planner then executor", {
  testthat::skip_if_not(python_available())
  m <- start_mock_llm(list(
    list(content = "PLAN: 1. think 2. answer"),
    list(content = "final answer from executor")
  ))
  on.exit(stop_py_mock(m), add = TRUE)

  agent <- agentgraph::plan_execute_agent(mk_provider(m))
  r <- run_ag(agent, "do the thing")

  expect_identical(r$answer, "final answer from executor")

  msgs <- r$state$messages
  assistant <- Filter(function(x) identical(x$role, "assistant"), msgs)
  expect_length(assistant, 2L)
  expect_identical(assistant[[1]]$content, "PLAN: 1. think 2. answer")

  Sys.sleep(0.1)
  expect_identical(count_requests(m), 2L)
})

test_that("reflection_agent runs draft -> critic -> revise", {
  testthat::skip_if_not(python_available())
  m <- start_mock_llm(list(
    list(content = "draft answer"),
    list(content = "critique: too short"),
    list(content = "revised final answer")
  ))
  on.exit(stop_py_mock(m), add = TRUE)

  agent <- agentgraph::reflection_agent(mk_provider(m), rounds = 1L)
  r <- run_ag(agent, "write something")

  expect_identical(r$answer, "revised final answer")

  assistant <- Filter(function(x) identical(x$role, "assistant"), r$state$messages)
  expect_length(assistant, 3L)

  Sys.sleep(0.1)
  expect_identical(count_requests(m), 3L)
})

test_that("reflection_agent honors multiple rounds", {
  testthat::skip_if_not(python_available())
  m <- start_mock_llm(list(
    list(content = "draft"),
    list(content = "critique 1"),
    list(content = "revise 1"),
    list(content = "critique 2"),
    list(content = "revise 2 final")
  ))
  on.exit(stop_py_mock(m), add = TRUE)

  agent <- agentgraph::reflection_agent(mk_provider(m), rounds = 2L)
  r <- run_ag(agent, "write something")

  expect_identical(r$answer, "revise 2 final")

  Sys.sleep(0.1)
  expect_identical(count_requests(m), 5L)
})

test_that("router_agent classifies and dispatches to the matching sub-agent", {
  testthat::skip_if_not(python_available())
  m <- start_mock_llm(list(
    list(content = "math"),
    list(content = "the answer is 42")
  ))
  on.exit(stop_py_mock(m), add = TRUE)

  p <- mk_provider(m)
  routes <- list(
    math = agentgraph::chat_agent(p, system_prompt = "MATH"),
    code = agentgraph::chat_agent(p, system_prompt = "CODE")
  )
  agent <- agentgraph::router_agent(p, routes)
  r <- run_ag(agent, "what is 6 times 7")

  expect_identical(r$answer, "the answer is 42")

  Sys.sleep(0.1)
  expect_identical(count_requests(m), 2L)
})

test_that("router_agent falls back to default on unknown route", {
  testthat::skip_if_not(python_available())
  m <- start_mock_llm(list(
    list(content = "whatever"),
    list(content = "default handled it")
  ))
  on.exit(stop_py_mock(m), add = TRUE)

  p <- mk_provider(m)
  routes <- list(a = agentgraph::chat_agent(p), b = agentgraph::chat_agent(p))
  agent <- agentgraph::router_agent(p, routes, default = "b")
  r <- run_ag(agent, "anything")

  expect_identical(r$answer, "default handled it")
})

test_that("router_agent errors on unknown route without default", {
  testthat::skip_if_not(python_available())
  m <- start_mock_llm(list(list(content = "nonsense")))
  on.exit(stop_py_mock(m), add = TRUE)

  p <- mk_provider(m)
  routes <- list(a = agentgraph::chat_agent(p))
  agent <- agentgraph::router_agent(p, routes)
  e <- err_msg(run_ag(agent, "anything"))
  expect_false(is.null(e))
  expect_true(grepl("unknown route", e, fixed = TRUE))
})

test_that("run_agent validates its agent argument", {
  e <- err_msg(agentgraph::run_agent("not an agent", "hi"))
  expect_false(is.null(e))
  expect_true(grepl("*_agent()", e, fixed = TRUE))
})
