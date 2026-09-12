call_tool <- function(name, args) {
  agentgraph:::test_tool_cpp(name, jsonlite::toJSON(args, auto_unbox = TRUE))
}
res_val <- function(out) {
  jsonlite::fromJSON(out$result, simplifyVector = FALSE)$result
}

test_that("calculator tool evaluates expressions and reports errors", {
  r <- call_tool("calculator", list(expression = "2+3"))
  expect_true(r$success)
  expect_equal(res_val(r), 5)

  r <- call_tool("calculator", list(expression = "6*7"))
  expect_equal(res_val(r), 42)

  r <- call_tool("calculator", list(expression = "10/4"))
  expect_equal(res_val(r), 2.5)

  r <- call_tool("calculator", list(expression = "42"))
  expect_equal(res_val(r), 42)

  r <- call_tool("calculator", list(expression = "10/0"))
  expect_false(r$success)
  expect_true(grepl("Division by zero", r$error, fixed = TRUE))

  r <- call_tool("calculator", list())
  expect_false(r$success)
  expect_true(grepl("Missing 'expression'", r$error, fixed = TRUE))

  r <- call_tool("calculator", list(expression = "abc"))
  expect_false(r$success)
  expect_true(grepl("Failed to evaluate", r$error, fixed = TRUE))
})

test_that("read_file tool reads content and reports missing files", {
  tmp_read <- tempfile()
  writeBin(charToRaw("hello world"), tmp_read)
  on.exit(unlink(tmp_read), add = TRUE)

  r <- call_tool("read_file", list(path = tmp_read))
  expect_true(r$success)
  expect_identical(
    jsonlite::fromJSON(r$result, simplifyVector = FALSE)$content,
    "hello world"
  )

  r <- call_tool("read_file", list())
  expect_false(r$success)
  expect_true(grepl("Missing 'path'", r$error, fixed = TRUE))

  r <- call_tool("read_file", list(path = file.path(tempdir(), "agentgraph_nope_xyz.txt")))
  expect_false(r$success)
  expect_true(grepl("Cannot open file", r$error, fixed = TRUE))
})

test_that("write_file tool writes content and validates parameters", {
  tmp_write <- tempfile()
  on.exit(unlink(tmp_write), add = TRUE)

  r <- call_tool("write_file", list(path = tmp_write, content = "payload 123"))
  expect_true(r$success)
  expect_identical(readLines(tmp_write, warn = FALSE), "payload 123")

  r <- call_tool("write_file", list(path = tmp_write))
  expect_false(r$success)
  expect_true(grepl("Missing 'path' or 'content'", r$error, fixed = TRUE))
})

test_that("unknown tool is rejected", {
  r <- call_tool("nonexistent_tool", list())
  expect_false(r$success)
  expect_true(grepl("Tool not found", r$error, fixed = TRUE))
})
