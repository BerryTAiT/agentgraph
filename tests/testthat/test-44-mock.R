# Built-in mock LLM + replay (R/mock.R + inst/tools/mock_server.R).

test_that("provider_mock keyed map matches input and falls back to *", {
  testthat::skip_if_not_installed("httpuv")
  p <- agentgraph::provider_mock(list("What is 2+2?" = "4", "*" = "I don't know"))

  r1 <- agentgraph::chat("What is 2+2?", provider = p)
  expect_identical(r1$content, "4")

  r2 <- agentgraph::chat("something else entirely", provider = p)
  expect_identical(r2$content, "I don't know")
})

test_that("provider_mock sequence serves in order and repeats the last", {
  testthat::skip_if_not_installed("httpuv")
  p <- agentgraph::provider_mock(list("first", "second"))

  expect_identical(agentgraph::chat("a", provider = p)$content, "first")
  expect_identical(agentgraph::chat("b", provider = p)$content, "second")
  expect_identical(agentgraph::chat("c", provider = p)$content, "second")
})

test_that("provider_mock serves tool_calls for a ReAct loop", {
  testthat::skip_if_not_installed("httpuv")
  p <- agentgraph::provider_mock(list(
    list(finish_reason = "tool_calls",
         tool_calls = list(list(id = "c1", name = "shout",
                                arguments = '{"text":"hi"}'))),
    list(content = "done")
  ))

  shout <- agentgraph::tool(
    name = "shout", description = "uppercase", 
    parameters = list(text = agentgraph::param_string("text")),
    handler = function(args_json) {
      args <- jsonlite::fromJSON(args_json, simplifyVector = FALSE)
      jsonlite::toJSON(list(result = paste0(toupper(args$text), "!!")), auto_unbox = TRUE)
    }
  )

  agent <- agentgraph::react_agent(p, tools = list(shout))
  r <- agentgraph::run_agent(agent, "shout hi")
  expect_identical(r$answer, "done")

  tool_msgs <- Filter(function(x) identical(x$role, "tool"), r$state$messages)
  expect_length(tool_msgs, 1L)
  expect_identical(jsonlite::fromJSON(tool_msgs[[1]]$content)$result, "HI!!")
})

test_that("provider_mock validates responses", {
  testthat::skip_if_not_installed("httpuv")
  e <- err_msg(agentgraph::provider_mock(42))
  expect_true(grepl("list or character vector", e, fixed = TRUE))
  e2 <- err_msg(agentgraph::provider_mock(list(42)))
  expect_true(grepl("string or a list", e2, fixed = TRUE))
})

test_that("provider_replay re-serves a recorded session", {
  testthat::skip_if_not_installed("httpuv")
  # record a session through a mock provider
  p <- agentgraph::provider_mock(list("one", "two"))
  g1 <- agentgraph::state_graph(entry = "a") |>
    agentgraph::add_node("a", agentgraph::llm_node(provider = p)) |>
    agentgraph::add_node("b", agentgraph::llm_node(provider = p)) |>
    agentgraph::add_edge("a", "b") |>
    agentgraph::add_edge("b", "__end__")

  log <- tempfile(fileext = ".jsonl")
  r1 <- agentgraph::run(g1, state = list(messages = list(agentgraph::user_msg("hi"))),
                        log_path = log)
  expect_identical(tail(r1$messages, 1)[[1]]$content, "two")

  # replay from the trace with a fresh graph
  p2 <- agentgraph::provider_replay(log)
  g2 <- agentgraph::state_graph(entry = "a") |>
    agentgraph::add_node("a", agentgraph::llm_node(provider = p2)) |>
    agentgraph::add_node("b", agentgraph::llm_node(provider = p2)) |>
    agentgraph::add_edge("a", "b") |>
    agentgraph::add_edge("b", "__end__")
  r2 <- agentgraph::run(g2, state = list(messages = list(agentgraph::user_msg("hi"))))
  expect_identical(tail(r2$messages, 1)[[1]]$content, "two")
})

test_that("provider_replay validates its input", {
  e <- err_msg(agentgraph::provider_replay("no-such-file.jsonl"))
  expect_true(grepl("existing trace file", e, fixed = TRUE))

  empty <- tempfile(fileext = ".jsonl")
  writeLines("{\"event\":\"other\"}", empty)
  e2 <- err_msg(agentgraph::provider_replay(empty))
  expect_true(grepl("no llm_response events", e2, fixed = TRUE))
})

test_that("mock_stop_all is a safe no-op", {
  expect_null(agentgraph::mock_stop_all())
})
