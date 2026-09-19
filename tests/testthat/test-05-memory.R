# Memory management: window buffer, summary memory, and entity memory.
#
# These tests assert what the engine sends to the LLM (by parsing the mock
# server's request log) and what it persists into graph state. The request log
# holds one compact JSON body per line, so each line can be decoded and its
# `messages` array inspected directly.

request_json <- function(m, i = 1L) {
  lines <- readLines(m$log, warn = FALSE)
  jsonlite::fromJSON(lines[[i]], simplifyVector = FALSE)
}

request_messages <- function(m, i = 1L) {
  request_json(m, i)$messages
}

test_that("window buffer sends only the last N messages", {
  testthat::skip_if_not(python_available())

  m <- start_mock_llm(list(list(finish_reason = "stop", content = "ok")))
  on.exit(stop_py_mock(m), add = TRUE)

  provider <- mock_provider(m)

  graph <- state_graph(entry = "llm") |>
    add_node("llm", llm_node(provider = provider, window_size = 2L))

  result <- run(
    graph,
    state = list(messages = list(
      user_msg("m1"), user_msg("m2"), user_msg("m3"), user_msg("m4")
    ))
  )

  msgs <- request_messages(m, 1L)
  roles <- vapply(msgs, function(x) x$role, character(1))
  contents <- vapply(msgs, function(x) x$content, character(1))

  expect_equal(roles, c("user", "user"))
  expect_equal(contents, c("m3", "m4"))
  expect_identical(tail(result$messages, 1)[[1]]$content, "ok")
})

test_that("summary memory compresses evicted messages into state", {
  testthat::skip_if_not(python_available())

  m <- start_mock_llm(list(
    list(finish_reason = "stop", content = "User discussed the weather."),
    list(finish_reason = "stop", content = "final")
  ))
  on.exit(stop_py_mock(m), add = TRUE)

  provider <- mock_provider(m)

  graph <- state_graph(entry = "llm") |>
    add_node("llm", llm_node(provider = provider, window_size = 2L,
                             summarize = TRUE))

  result <- run(
    graph,
    state = list(messages = list(
      user_msg("m1"), user_msg("m2"), user_msg("m3"), user_msg("m4")
    ))
  )

  lines <- readLines(m$log, warn = FALSE)
  expect_length(lines, 2L)

  # The second request is the main LLM call: the summary is injected as the
  # leading system message, followed by the two retained messages.
  msgs <- request_messages(m, 2L)
  expect_identical(msgs[[1]]$role, "system")
  expect_identical(msgs[[1]]$content, "User discussed the weather.")
  expect_equal(vapply(msgs[-1], function(x) x$content, character(1)),
               c("m3", "m4"))

  summary <- jsonlite::fromJSON(result$data$conversation_summary)
  expect_identical(summary, "User discussed the weather.")
})

test_that("entity memory extracts facts into state", {
  testthat::skip_if_not(python_available())

  m <- start_mock_llm(list(
    list(finish_reason = "stop", content = "Nice to meet you Alice!"),
    list(finish_reason = "stop", content = '{"name":"Alice","likes":"coffee"}')
  ))
  on.exit(stop_py_mock(m), add = TRUE)

  provider <- mock_provider(m)

  graph <- state_graph(entry = "llm") |>
    add_node("llm", llm_node(provider = provider, entity_memory = TRUE))

  result <- run(
    graph,
    state = list(messages = list(user_msg("My name is Alice and I love coffee.")))
  )

  entities <- jsonlite::fromJSON(result$data$entities)
  expect_equal(entities$name, "Alice")
  expect_equal(entities$likes, "coffee")
})

test_that("entity memory injects known facts on subsequent turns", {
  testthat::skip_if_not(python_available())

  m <- start_mock_llm(list(list(finish_reason = "stop", content = "ok")))
  on.exit(stop_py_mock(m), add = TRUE)

  provider <- mock_provider(m)

  graph <- state_graph(entry = "llm") |>
    add_node("llm", llm_node(provider = provider, entity_memory = TRUE))

  run(
    graph,
    state = list(
      messages = list(user_msg("hello")),
      entities = jsonlite::toJSON(list(name = "Alice", likes = "coffee"),
                                  auto_unbox = TRUE)
    )
  )

  # The injected facts are the first (system) message of the main LLM call.
  msgs <- request_messages(m, 1L)
  expect_identical(msgs[[1]]$role, "system")
  expect_match(msgs[[1]]$content, "Known user facts")
  expect_match(msgs[[1]]$content, "Alice")
  expect_match(msgs[[1]]$content, "coffee")
})
