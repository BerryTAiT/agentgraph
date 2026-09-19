# PII scrubbing: standalone pii_scrub() (R/pii.R) and the transparent
# provider_pii() filter (C++ engine). The transparent test uses the mock.

mk_provider <- function(m) {
  agentgraph::provider_openai(
    api_key = "test", model = "mock-model",
    base_url = paste0("http://127.0.0.1:", m$port),
    max_retries = 0L
  )
}

test_that("pii_scrub redacts each entity type", {
  expect_identical(
    agentgraph::pii_scrub("email me at alice@example.com please"),
    "email me at [REDACTED] please"
  )
  expect_identical(
    agentgraph::pii_scrub("call 555-123-4567 now"),
    "call [REDACTED] now"
  )
  expect_identical(
    agentgraph::pii_scrub("SSN is 123-45-6789"),
    "SSN is [REDACTED]"
  )
  expect_identical(
    agentgraph::pii_scrub("card 4111 1111 1111 1111 ok"),
    "card [REDACTED] ok"
  )
  expect_identical(
    agentgraph::pii_scrub("key sk-abcdefghijklmnopqrst ok"),
    "key [REDACTED] ok"
  )
  expect_identical(
    agentgraph::pii_scrub("ip 192.168.1.1 ok"),
    "ip [REDACTED] ok"
  )
})

test_that("pii_scrub leaves ordinary text untouched", {
  txt <- "The cat sat on the mat. It cost $12.50. Version 2.0."
  expect_identical(agentgraph::pii_scrub(txt), txt)
})

test_that("pii_scrub honors custom redact and entity subset", {
  expect_identical(
    agentgraph::pii_scrub("mail bob@x.com", redact = "X"),
    "mail X"
  )
  # phone only: a phone is redacted, an email is untouched
  expect_identical(
    agentgraph::pii_scrub("call 555-123-4567", entities = "phone"),
    "call [REDACTED]"
  )
  # email not in subset -> untouched
  expect_identical(
    agentgraph::pii_scrub("mail alice@example.com", entities = "phone"),
    "mail alice@example.com"
  )
  # email-only subset still scrubs an email and leaves a phone untouched
  expect_identical(
    agentgraph::pii_scrub("mail a@b.co", entities = "email"),
    "mail [REDACTED]"
  )
  expect_identical(
    agentgraph::pii_scrub("call 555-123-4567", entities = "email"),
    "call 555-123-4567"
  )
})

test_that("pii_scrub is vectorized and validates", {
  expect_identical(
    agentgraph::pii_scrub(c("a@b.com", "plain", "555-123-4567")),
    c("[REDACTED]", "plain", "[REDACTED]")
  )
  e <- err_msg(agentgraph::pii_scrub(42))
  expect_true(grepl("character vector", e, fixed = TRUE))
  e2 <- err_msg(agentgraph::pii_scrub("x", entities = "nope"))
  expect_false(is.null(e2))
})

test_that("pii_scrub redacts a full 16-digit card as one unit", {
  # If the phone pattern ran first it would leave a "1111" tail; canonical
  # order (credit_card before phone) must prevent that.
  out <- agentgraph::pii_scrub("card 4111111111111111 done")
  expect_identical(out, "card [REDACTED] done")
})

test_that("provider_pii validates and wraps", {
  p <- agentgraph::provider_openai()
  wrapped <- agentgraph::provider_pii(p)
  expect_true(wrapped$pii_filter)
  expect_identical(wrapped$pii_redact, "[REDACTED]")
  expect_identical(wrapped$name, "openai")

  custom <- agentgraph::provider_pii(p, redact = "<redacted>")
  expect_identical(custom$pii_redact, "<redacted>")

  e <- err_msg(agentgraph::provider_pii("not a provider"))
  expect_true(grepl("provider configuration", e, fixed = TRUE))
  e2 <- err_msg(agentgraph::provider_pii(p, redact = NA))
  expect_true(grepl("single non-NA", e2, fixed = TRUE))
})

test_that("provider_pii redacts content sent to the mock LLM", {
  testthat::skip_if_not(python_available())
  m <- start_mock_llm(list(list(content = "ok")))
  on.exit(stop_py_mock(m), add = TRUE)

  p <- agentgraph::provider_pii(mk_provider(m), redact = "REDACTED")
  ans <- agentgraph::chat("my email is alice@example.com and card 4111 1111 1111 1111",
                          provider = p)
  expect_identical(ans$content, "ok")

  Sys.sleep(0.3)
  log <- readLines(m$log, warn = FALSE)
  body <- jsonlite::fromJSON(log[1], simplifyVector = FALSE)
  user_content <- body$messages[[length(body$messages)]]$content
  expect_false(grepl("alice@example.com", user_content, fixed = TRUE))
  expect_false(grepl("4111", user_content, fixed = TRUE))
  expect_true(grepl("REDACTED", user_content, fixed = TRUE))
})

test_that("provider_pii redacts the system prompt too", {
  testthat::skip_if_not(python_available())
  m <- start_mock_llm(list(list(content = "ok")))
  on.exit(stop_py_mock(m), add = TRUE)

  p <- agentgraph::provider_pii(mk_provider(m), redact = "REDACTED")
  agentgraph::chat("hi", provider = p, system_prompt = "reply to bob@x.com")

  Sys.sleep(0.3)
  log <- readLines(m$log, warn = FALSE)
  body <- jsonlite::fromJSON(log[1], simplifyVector = FALSE)
  sys <- body$messages[[1]]$content
  expect_false(grepl("bob@x.com", sys, fixed = TRUE))
  expect_true(grepl("REDACTED", sys, fixed = TRUE))
})

test_that("pii_filter default is off (no redaction without the wrapper)", {
  testthat::skip_if_not(python_available())
  m <- start_mock_llm(list(list(content = "ok")))
  on.exit(stop_py_mock(m), add = TRUE)

  agentgraph::chat("email alice@example.com", provider = mk_provider(m))

  Sys.sleep(0.3)
  log <- readLines(m$log, warn = FALSE)
  body <- jsonlite::fromJSON(log[1], simplifyVector = FALSE)
  user_content <- body$messages[[length(body$messages)]]$content
  expect_true(grepl("alice@example.com", user_content, fixed = TRUE))
})
