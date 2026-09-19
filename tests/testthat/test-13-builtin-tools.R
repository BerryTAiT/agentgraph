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

test_that("calculator evaluates chained, parenthesised and signed expressions", {
  cases <- list(
    list("10-2-3", 5),
    list("3+4*2", 11),
    list("(3+4)*2", 14),
    list("2*(3+4)", 14),
    list("-5+3", -2),
    list(" 7 / 2 ", 3.5),
    list("2*(3+4)/(5-3)", 7),
    list("1/3", 1 / 3)
  )
  for (case in cases) {
    r <- call_tool("calculator", list(expression = case[[1]]))
    expect_true(r$success, info = paste("expression:", case[[1]]))
    expect_equal(res_val(r), case[[2]], info = paste("expression:", case[[1]]))
  }
})

test_that("calculator rejects malformed expressions", {
  r <- call_tool("calculator", list(expression = "2*(3+4"))
  expect_false(r$success)
  expect_true(grepl("Failed to evaluate", r$error, fixed = TRUE))

  r <- call_tool("calculator", list(expression = "2 & 3"))
  expect_false(r$success)

  r <- call_tool("calculator", list(expression = "1/0"))
  expect_false(r$success)
  expect_true(grepl("Division by zero", r$error, fixed = TRUE))
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

# NOTE: this test must run LAST in this file. The C++ filesystem policy is
# latched on first file-tool use (read-once from the environment), so the
# unrestricted read_file/write_file tests above must execute before a policy
# is configured here.
test_that("native file tools respect AGENTGRAPH_FS_ALLOW / AGENTGRAPH_FS_DENY", {
  tmp <- tempfile("fs_policy_test_")
  dir.create(tmp)
  on.exit(unlink(tmp, recursive = TRUE), add = TRUE)

  inside <- file.path(tmp, "ok.txt")
  outside <- tempfile("fs_policy_outside_", fileext = ".txt")
  writeLines("hello", inside)
  writeLines("secret", outside)
  on.exit(unlink(outside), add = TRUE)

  file_tools_policy(allow = tmp)
  on.exit({
    Sys.unsetenv("AGENTGRAPH_FS_ALLOW")
    Sys.unsetenv("AGENTGRAPH_FS_DENY")
  }, add = TRUE)

  # Allowed: inside the permitted directory (read and write).
  r <- call_tool("read_file", list(path = inside))
  expect_true(r$success)
  expect_match(r$result, "hello", fixed = TRUE)

  new_file <- file.path(tmp, "new.txt")
  r <- call_tool("write_file", list(path = new_file, content = "written"))
  expect_true(r$success)
  expect_true(file.exists(new_file))

  # Denied: outside the allowed directory.
  r <- call_tool("read_file", list(path = outside))
  expect_false(r$success)
  expect_match(r$error, "not within an allowed", fixed = TRUE)

  r <- call_tool("write_file", list(path = outside, content = "nope"))
  expect_false(r$success)
  expect_match(r$error, "not within an allowed", fixed = TRUE)

  # Denied: path traversal that lexically starts inside but escapes.
  escape <- file.path(tmp, "..", basename(outside))
  r <- call_tool("read_file", list(path = escape))
  expect_false(r$success)
  expect_match(r$error, "not within an allowed", fixed = TRUE)
})
