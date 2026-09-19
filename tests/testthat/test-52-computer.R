# Computer use (R/computer.R). Dry-run mode is tested; real OS control is not.

test_that("computer_use validates and echoes in dry-run mode", {
  out <- agentgraph::computer_use("screenshot", path = "C:/tmp/s.png")
  j <- jsonlite::fromJSON(out, simplifyVector = FALSE)
  expect_identical(j$action, "screenshot")
  expect_true(j$dry_run)

  out2 <- agentgraph::computer_use("move", x = 10, y = 20)
  j2 <- jsonlite::fromJSON(out2, simplifyVector = FALSE)
  expect_equal(j2$x, 10)
})

test_that("computer_use validates unknown action and missing args", {
  e <- err_msg(agentgraph::computer_use("explode", x = 1))
  expect_true(grepl("must be one of", e, fixed = TRUE))

  e2 <- err_msg(agentgraph::computer_use("screenshot"))
  expect_true(grepl("requires: path", e2, fixed = TRUE))

  e3 <- err_msg(agentgraph::computer_use("move", x = 1))  # missing y
  expect_true(grepl("requires: y", e3, fixed = TRUE))
})

test_that("tool_computer_use handler echoes in dry-run mode", {
  t <- agentgraph::tool_computer_use(dry_run = TRUE)
  out <- t$handler('{"action":"click","x":5,"y":6}')
  j <- jsonlite::fromJSON(out, simplifyVector = FALSE)
  expect_identical(j$action, "click")
  expect_true(j$dry_run)
  expect_equal(j$x, 5)
})

test_that("tool_computer_use handler validates (self-contained)", {
  t <- agentgraph::tool_computer_use(dry_run = TRUE)
  e <- err_msg(t$handler('{"action":"nope"}'))
  expect_true(grepl("must be one of", e, fixed = TRUE))
})
