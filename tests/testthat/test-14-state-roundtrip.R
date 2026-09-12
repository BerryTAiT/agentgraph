# interrupt-only graph: pauses immediately, returns state untouched.
state_graph_gate <- function() {
  state_graph(entry = "gate") |>
    add_node("gate", interrupt_node()) |>
    add_edge("gate", "__end__")
}

test_that("explicit state_data round-trips complex JSON types", {
  state_data <- list(
    nested    = '{"a":{"b":[1,2,3]},"c":true,"d":null}',
    number    = '42.5',
    text      = '"hello world"',
    arr       = '[1,2,3]',
    flag      = 'false',
    neg       = '-7',
    unordered = '{"z":1,"a":2,"m":3}'
  )

  res <- run(state_graph_gate(), state = list(), state_data = state_data)

  expect_identical(res$data[["__interrupted__"]], "true")
  expect_identical(jsonlite::fromJSON(res$data[["__resume_node__"]]), "__end__")

  rt_ok <- function(key) {
    identical(
      jsonlite::fromJSON(state_data[[key]], simplifyVector = FALSE),
      jsonlite::fromJSON(res$data[[key]], simplifyVector = FALSE)
    )
  }
  expect_true(rt_ok("nested"))
  expect_true(rt_ok("number"))
  expect_true(rt_ok("text"))
  expect_true(rt_ok("arr"))
  expect_true(rt_ok("flag"))
  expect_true(rt_ok("neg"))

  u_in  <- jsonlite::fromJSON(state_data[["unordered"]], simplifyVector = FALSE)
  u_out <- jsonlite::fromJSON(res$data[["unordered"]], simplifyVector = FALSE)
  expect_identical(u_out[order(names(u_out))], u_in[order(names(u_in))])
})

test_that("state as named list round-trips messages and extra keys", {
  res <- run(state_graph_gate(), state = list(
    messages = list(user_msg("hi there")),
    extra = '{"bar":1}'
  ))

  expect_identical(res$messages[[1]]$role, "user")
  expect_identical(res$messages[[1]]$content, "hi there")
  expect_identical(
    jsonlite::fromJSON(res$data[["extra"]], simplifyVector = FALSE),
    list(bar = 1L)
  )
})

test_that("resume inject serializes complex R values and clears markers", {
  graph <- state_graph_gate()
  res <- run(graph, state = list(), state_data = list(number = '42.5'))

  res2 <- resume(graph, res, inject = list(
    nested = list(x = 1, y = list(z = "abc")),
    count  = 5L,
    tags   = c("a", "b")
  ))

  expect_identical(res2$data[["count"]], "5")
  expect_identical(res2$data[["tags"]], '["a","b"]')
  expect_identical(
    jsonlite::fromJSON(res2$data[["nested"]], simplifyVector = FALSE),
    list(x = 1L, y = list(z = "abc"))
  )
  expect_identical(res2$data[["number"]], "42.5")
  expect_null(res2$data[["__interrupted__"]])
})
