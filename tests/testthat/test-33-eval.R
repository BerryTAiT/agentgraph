# Evaluation framework (R/eval.R). LLM-backed evaluators use the Python mock.

mk_provider <- function(m) {
  agentgraph::provider_openai(
    api_key = "test", model = "mock-model",
    base_url = paste0("http://127.0.0.1:", m$port),
    max_retries = 0L
  )
}

test_that("eval_dataset builds and validates", {
  ds <- agentgraph::eval_dataset(c("q1", "q2"), c("a1", "a2"))
  expect_identical(ds$input, c("q1", "q2"))
  expect_identical(ds$expected, c("a1", "a2"))

  ds2 <- agentgraph::eval_dataset(c("q1", "q2"))
  expect_identical(ds2$expected, c("", ""))

  ds3 <- agentgraph::eval_dataset(c("q1", "q2"), c("a1", NA))
  expect_identical(ds3$expected, c("a1", ""))

  e1 <- err_msg(agentgraph::eval_dataset(character(0)))
  expect_true(grepl("at least one example", e1, fixed = TRUE))

  e2 <- err_msg(agentgraph::eval_dataset(c("q1", "q2"), c("a1")))
  expect_true(grepl("same length", e2, fixed = TRUE))
})

test_that("evaluate scores a function target with exact_match", {
  ds <- data.frame(
    input = c("2+2", "capital of France"),
    expected = c("4", "Paris")
  )
  target <- function(input) if (input == "2+2") "4" else "London"

  r <- agentgraph::evaluate(target, ds, list(agentgraph::eval_exact_match()))

  expect_s3_class(r, "agentgraph_eval")
  expect_identical(r$results$answer, c("4", "London"))
  expect_identical(r$results$exact_match, c(1, 0))
  expect_identical(r$results$passed, c(TRUE, FALSE))
  expect_identical(r$passed, FALSE)
  expect_true(all(r$results$elapsed >= 0))

  expect_identical(r$summary$evaluator, "exact_match")
  expect_identical(r$summary$mean_score, 0.5)
  expect_identical(r$summary$pass_rate, 0.5)
})

test_that("evaluate accepts a character-vector dataset and echo target", {
  r <- agentgraph::evaluate(function(x) x, c("a", "b"),
                            list(agentgraph::eval_contains("a")))
  expect_identical(r$results$input, c("a", "b"))
  expect_identical(r$results$expected, c("", ""))
  expect_identical(r$results$contains, c(1, 0))
})

test_that("evaluate scores an agent with eval_contains (mock LLM)", {
  testthat::skip_if_not(python_available())
  m <- start_mock_llm(list(
    list(content = "The capital of France is Paris."),
    list(content = "I have no idea.")
  ))
  on.exit(stop_py_mock(m), add = TRUE)

  agent <- agentgraph::chat_agent(mk_provider(m))
  ds <- agentgraph::eval_dataset(c("q1", "q2"), c("Paris", "Paris"))
  r <- agentgraph::evaluate(agent, ds, list(agentgraph::eval_contains("Paris")))

  expect_identical(r$results$contains, c(1, 0))
  expect_identical(r$results$passed, c(TRUE, FALSE))
  expect_identical(r$passed, FALSE)
})

test_that("eval_numeric extracts numbers and applies tolerance", {
  ds <- agentgraph::eval_dataset("price", "total 42.5 dollars")
  ev <- list(agentgraph::eval_numeric())

  r1 <- agentgraph::evaluate(function(x) "it costs about 42.5", ds, ev)
  expect_identical(r1$results$numeric, 1)
  expect_true(r1$results$passed)

  r2 <- agentgraph::evaluate(function(x) "it costs 40 dollars", ds,
                             list(agentgraph::eval_numeric(tolerance = 3)))
  expect_identical(r2$results$numeric, 1)

  r3 <- agentgraph::evaluate(function(x) "no numbers here", ds, ev)
  expect_identical(r3$results$numeric, 0)
  expect_match(r3$details[[1]]$numeric, "no numbers")

  r4 <- agentgraph::evaluate(function(x) "42.5", agentgraph::eval_dataset("q"), ev)
  expect_false(r4$results$passed)
})

test_that("eval_regex matches the prediction", {
  ev <- list(agentgraph::eval_regex("^[A-Z][a-z]+$"))
  r <- agentgraph::evaluate(function(x) "Hello", agentgraph::eval_dataset("q"), ev)
  expect_identical(r$results$regex, 1)
  expect_true(r$passed)

  r2 <- agentgraph::evaluate(function(x) "hello", agentgraph::eval_dataset("q"), ev)
  expect_identical(r2$results$regex, 0)
  expect_false(r2$passed)
})

test_that("eval_llm_judge parses PASS, FAIL, numeric, and junk replies", {
  testthat::skip_if_not(python_available())
  mk <- function(content) {
    m <- start_mock_llm(list(list(content = content)))
    list(m = m, p = mk_provider(m))
  }

  pass <- mk("PASS")
  on.exit(stop_py_mock(pass$m), add = TRUE)
  r <- agentgraph::evaluate(function(x) "ans", agentgraph::eval_dataset("q", "ref"),
                            list(agentgraph::eval_llm_judge(pass$p)))
  expect_identical(r$results$llm_judge, 1)
  expect_true(r$passed)

  fail <- mk("FAIL - missing citations")
  on.exit(stop_py_mock(fail$m), add = TRUE)
  r <- agentgraph::evaluate(function(x) "ans", agentgraph::eval_dataset("q", "ref"),
                            list(agentgraph::eval_llm_judge(fail$p)))
  expect_identical(r$results$llm_judge, 0)
  expect_false(r$passed)

  frac <- mk("0.9")
  on.exit(stop_py_mock(frac$m), add = TRUE)
  r <- agentgraph::evaluate(function(x) "ans", agentgraph::eval_dataset("q", "ref"),
                            list(agentgraph::eval_llm_judge(frac$p)))
  expect_identical(r$results$llm_judge, 0.9)
  expect_true(r$passed)

  junk <- mk("maybe?")
  on.exit(stop_py_mock(junk$m), add = TRUE)
  r <- agentgraph::evaluate(function(x) "ans", agentgraph::eval_dataset("q", "ref"),
                            list(agentgraph::eval_llm_judge(junk$p)))
  expect_identical(r$results$llm_judge, 0)
  expect_false(r$passed)
  expect_match(r$details[[1]]$llm_judge, "unrecognized judge reply")
})

test_that("eval_semantic compares embeddings via the mock endpoint", {
  testthat::skip_if_not(python_available())
  m <- start_mock_llm(list(list(content = "unused")))
  on.exit(stop_py_mock(m), add = TRUE)
  ev <- list(agentgraph::eval_semantic(mk_provider(m), threshold = 0.8))

  same <- agentgraph::evaluate(function(x) "the cat sat",
                               agentgraph::eval_dataset("q", "the cat sat"), ev)
  expect_equal(same$results$semantic, 1)
  expect_true(same$passed)

  diff <- agentgraph::evaluate(function(x) "alpha bravo charlie",
                               agentgraph::eval_dataset("q", "delta echo foxtrot"), ev)
  expect_true(diff$results$semantic < 0.8)
  expect_false(diff$passed)
})

test_that("eval_custom accepts numeric, logical, and list returns", {
  evs <- list(
    agentgraph::eval_custom("mynum", function(p, ex) 0.75),
    agentgraph::eval_custom("mylog", function(p, ex) nchar(p) > 3),
    agentgraph::eval_custom("mylist", function(p, ex) list(score = 1, passed = TRUE, reason = "ok"))
  )
  r <- agentgraph::evaluate(function(x) "hello", agentgraph::eval_dataset("q"), evs)
  expect_identical(r$results$mynum, 0.75)
  expect_identical(r$results$mylog, 1)
  expect_identical(r$results$mylist, 1)
  expect_true(r$passed)
})

test_that("evaluator errors are contained per example", {
  ev <- agentgraph::eval_custom("bad", function(p, ex) stop("boom"))
  r <- agentgraph::evaluate(function(x) "a", agentgraph::eval_dataset("q"), list(ev))
  expect_identical(r$results$bad, 0)
  expect_false(r$passed)
  expect_match(r$details[[1]]$bad, "boom")
})

test_that("target errors are contained per example", {
  ds <- agentgraph::eval_dataset(c("ok1", "boom", "ok2"), c("ok1", "b", "ok2"))
  target <- function(input) if (input == "boom") stop("kaboom") else input

  r <- agentgraph::evaluate(target, ds, list(agentgraph::eval_exact_match()))
  expect_identical(r$results$answer, c("ok1", NA, "ok2"))
  expect_identical(r$results$error, c("", "kaboom", ""))
  expect_identical(r$results$passed, c(TRUE, FALSE, TRUE))
  expect_false(r$passed)
})

test_that("evaluate validates its inputs", {
  f <- function(x) "a"
  e1 <- err_msg(agentgraph::evaluate(f, agentgraph::eval_dataset("q"),
                                     list(agentgraph::eval_custom("x", function(p, ex) 1),
                                          agentgraph::eval_custom("x", function(p, ex) 1))))
  expect_true(grepl("must be unique", e1, fixed = TRUE))

  e2 <- err_msg(agentgraph::evaluate(f, agentgraph::eval_dataset("q"),
                                     list(agentgraph::eval_custom("answer", function(p, ex) 1))))
  expect_true(grepl("must not be one of", e2, fixed = TRUE))

  e3 <- err_msg(agentgraph::evaluate(42, agentgraph::eval_dataset("q")))
  expect_true(grepl("agent or a function", e3, fixed = TRUE))

  e4 <- err_msg(agentgraph::evaluate(f, 42))
  expect_false(is.null(e4))

  e5 <- err_msg(agentgraph::evaluate(f, data.frame(expected = "a")))
  expect_true(grepl("`input` column", e5, fixed = TRUE))
})

test_that("print shows the summary", {
  r <- agentgraph::evaluate(function(x) "4", agentgraph::eval_dataset("2+2", "4"),
                            list(agentgraph::eval_exact_match()))
  out <- capture.output(print(r))
  expect_true(any(grepl("agentgraph evaluation", out, fixed = TRUE)))
  expect_true(any(grepl("exact_match", out, fixed = TRUE)))
  expect_true(any(grepl("PASS", out, fixed = TRUE)))
})
