# Compliance & audit (R/audit.R).

test_that("audit_log records, reads, and verifies entries", {
  f <- tempfile(fileext = ".jsonl")
  log <- agentgraph::audit_log(f)
  expect_s3_class(log, "agentgraph_audit")

  agentgraph::audit_record(log, "llm_call", data = list(model = "gpt-4o"))
  agentgraph::audit_record(log, "pii_redacted", pii = list(emails = 1))

  d <- agentgraph::audit_read(log)
  expect_equal(nrow(d), 2L)
  expect_identical(d$event, c("llm_call", "pii_redacted"))
  expect_identical(d$seq, 1:2)

  expect_true(agentgraph::audit_verify(log))

  out <- capture.output(print(log))
  expect_true(any(grepl("2 entries", out, fixed = TRUE)))
})

test_that("audit_verify detects tampering", {
  f <- tempfile(fileext = ".jsonl")
  log <- agentgraph::audit_log(f)
  agentgraph::audit_record(log, "a", data = list(x = 1))
  agentgraph::audit_record(log, "b", data = list(y = 2))

  # modify the first line's event
  lines <- readLines(f, warn = FALSE)
  j <- jsonlite::fromJSON(lines[1], simplifyVector = FALSE)
  j$event <- "tampered"
  lines[1] <- jsonlite::toJSON(j, auto_unbox = TRUE)
  writeLines(lines, f)

  expect_false(agentgraph::audit_verify(log))
})

test_that("audit_verify detects deletion (broken chain)", {
  f <- tempfile(fileext = ".jsonl")
  log <- agentgraph::audit_log(f)
  agentgraph::audit_record(log, "a")
  agentgraph::audit_record(log, "b")

  # delete the first line -> the second's prev no longer matches genesis
  lines <- readLines(f, warn = FALSE)
  writeLines(lines[-1], f)

  expect_false(agentgraph::audit_verify(log))
})

test_that("audit_verify on an empty log is TRUE", {
  f <- tempfile(fileext = ".jsonl")
  log <- agentgraph::audit_log(f)
  expect_true(agentgraph::audit_verify(log))
  expect_equal(nrow(agentgraph::audit_read(log)), 0L)
})

test_that("pii_report counts each entity type", {
  r <- agentgraph::pii_report(c("mail a@b.co and 555-123-4567", "ip 192.168.1.1"))
  expect_identical(r$entity, c("email", "api_key", "ssn", "credit_card", "phone", "ipv4"))
  expect_equal(r$count[r$entity == "email"], 1)
  expect_equal(r$count[r$entity == "phone"], 1)
  expect_equal(r$count[r$entity == "ipv4"], 1)
  expect_equal(r$count[r$entity == "ssn"], 0)

  r2 <- agentgraph::pii_report("nothing here")
  expect_equal(sum(r2$count), 0)
})

test_that("audit functions validate their input", {
  e <- err_msg(agentgraph::audit_log(NA_character_))
  expect_true(grepl("non-empty", e, fixed = TRUE))

  log <- agentgraph::audit_log(tempfile(fileext = ".jsonl"))
  e2 <- err_msg(agentgraph::audit_record(log, 42))
  expect_true(grepl("non-NA string", e2, fixed = TRUE))

  e3 <- err_msg(agentgraph::audit_verify("nope"))
  expect_true(grepl("audit_log()", e3, fixed = TRUE))
})
