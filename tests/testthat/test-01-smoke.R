test_that("package loads and built-in smoke hooks respond", {
  expect_true(nzchar(agentgraph:::hello_cpp()))

  r <- agentgraph:::test_tool_cpp("calculator", '{"expression":"2+3"}')
  expect_true(r$success)
  expect_equal(jsonlite::fromJSON(r$result, simplifyVector = FALSE)$result, 5)
})
