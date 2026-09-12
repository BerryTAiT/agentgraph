# interrupt-only graph: pauses immediately.
state_graph_gate <- function() {
  state_graph(entry = "gate") |>
    add_node("gate", interrupt_node()) |>
    add_edge("gate", "__end__")
}

test_that("empty-state variants run cleanly", {
  graph <- state_graph_gate()

  res_empty <- run(graph, state = list())
  expect_length(res_empty$messages, 0L)
  expect_identical(res_empty$data[["__interrupted__"]], "true")

  res_msgs_only <- run(graph, state = list(messages = list()))
  expect_length(res_msgs_only$messages, 0L)
  expect_identical(res_msgs_only$data[["__interrupted__"]], "true")

  res_unnamed <- run(graph, state = list(user_msg("hello")))
  expect_length(res_unnamed$messages, 1L)
  expect_identical(res_unnamed$messages[[1]]$role, "user")
  expect_identical(res_unnamed$messages[[1]]$content, "hello")
})

test_that("JSON edge values round-trip through state_data", {
  special_text <- "he said \"hi\"\nline2\t tab & \u4e2d\u6587 \U0001F30D"
  state_data <- list(
    empty_str = '""',
    empty_arr = '[]',
    empty_obj = '{}',
    nullv     = 'null',
    esc       = jsonlite::toJSON(special_text, auto_unbox = TRUE),
    deep      = jsonlite::toJSON(
      list(a = list(b = list(c = list(d = list(e = list(f = "bottom")))))),
      auto_unbox = TRUE
    ),
    sci       = '1.5e-7',
    neg_sci   = '-3.25e+4',
    big_int   = '123456789'
  )

  res <- run(state_graph_gate(), state = list(), state_data = state_data)

  expect_identical(jsonlite::fromJSON(res$data[["empty_str"]]), "")
  expect_length(
    jsonlite::fromJSON(res$data[["empty_arr"]], simplifyVector = FALSE), 0L
  )
  expect_length(
    jsonlite::fromJSON(res$data[["empty_obj"]], simplifyVector = FALSE), 0L
  )
  expect_null(jsonlite::fromJSON(res$data[["nullv"]], simplifyVector = FALSE))
  expect_identical(jsonlite::fromJSON(res$data[["esc"]]), special_text)
  expect_identical(
    jsonlite::fromJSON(res$data[["deep"]], simplifyVector = FALSE),
    list(a = list(b = list(c = list(d = list(e = list(f = "bottom"))))))
  )
  expect_equal(jsonlite::fromJSON(res$data[["sci"]]), 1.5e-7)
  expect_equal(jsonlite::fromJSON(res$data[["neg_sci"]]), -3.25e4)
  expect_equal(jsonlite::fromJSON(res$data[["big_int"]]), 123456789)
})

test_that("reserved engine keys are overwritten", {
  res <- run(state_graph_gate(), state = list(), state_data = list(
    `__interrupted__` = 'false',
    `__resume_node__` = '"hacked"'
  ))
  expect_identical(res$data[["__interrupted__"]], "true")
  expect_identical(jsonlite::fromJSON(res$data[["__resume_node__"]]), "__end__")
})

test_that("resume edge cases clear markers and reject non-interrupted state", {
  graph <- state_graph_gate()
  res <- run(graph, state = list(), state_data = list(big_int = '123456789'))

  res2 <- resume(graph, res, inject = list())
  expect_null(res2$data[["__interrupted__"]])
  expect_null(res2$data[["__resume_node__"]])
  expect_equal(jsonlite::fromJSON(res2$data[["big_int"]]), 123456789)

  err <- tryCatch(
    resume(graph, list(data = list()), inject = list()),
    error = function(e) conditionMessage(e)
  )
  expect_true(grepl("not an interrupted state", err, fixed = TRUE))
})
