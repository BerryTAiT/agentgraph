# Tool-call validation (R/policy.R). All offline except the final integration
# test, which runs a restricted tool through the mock LLM + tool server.

test_that("tool_policy builds and validates", {
  p <- agentgraph::tool_policy(path_allow = c("/safe"), domain_allow = "example.com")
  expect_s3_class(p, "agentgraph_tool_policy")
  expect_identical(p$domain_allow, "example.com")

  e <- err_msg(agentgraph::validate_tool_args(list(), "nope"))
  expect_true(grepl("tool_policy()", e, fixed = TRUE))
})

test_that("validate_tool_args enforces path allow", {
  allow <- normalizePath(tempdir(), winslash = "/", mustWork = FALSE)
  p <- agentgraph::tool_policy(path_allow = allow)

  expect_true(agentgraph::validate_tool_args(
    list(path = file.path(allow, "data.csv")), p))

  outside <- file.path(dirname(allow), "outside.csv")
  e <- err_msg(agentgraph::validate_tool_args(list(path = outside), p))
  expect_true(grepl("not within an allowed path", e, fixed = TRUE))
})

test_that("validate_tool_args enforces path deny", {
  d <- normalizePath(tempdir(), winslash = "/", mustWork = FALSE)
  p <- agentgraph::tool_policy(path_deny = d)

  expect_true(agentgraph::validate_tool_args(
    list(path = file.path(dirname(d), "ok.csv")), p))
  e <- err_msg(agentgraph::validate_tool_args(list(path = file.path(d, "x.csv")), p))
  expect_true(grepl("is denied", e, fixed = TRUE))
})

test_that("validate_tool_args enforces domain allow with subdomains", {
  p <- agentgraph::tool_policy(domain_allow = "example.com")

  expect_true(agentgraph::validate_tool_args(list(url = "https://example.com/x"), p))
  expect_true(agentgraph::validate_tool_args(list(url = "https://api.example.com/v1"), p))

  e <- err_msg(agentgraph::validate_tool_args(list(url = "https://evil.com/x"), p))
  expect_true(grepl("domain 'evil.com' is not allowed", e, fixed = TRUE))

  # bare host + port are normalized
  expect_true(agentgraph::validate_tool_args(list(url = "example.com:8080/x"), p))
})

test_that("validate_tool_args enforces domain deny", {
  p <- agentgraph::tool_policy(domain_deny = "evil.com")
  expect_true(agentgraph::validate_tool_args(list(url = "https://example.com/x"), p))
  e <- err_msg(agentgraph::validate_tool_args(list(url = "https://evil.com/x"), p))
  expect_true(grepl("is denied", e, fixed = TRUE))
  # subdomain of a denied domain is also denied
  e2 <- err_msg(agentgraph::validate_tool_args(list(url = "https://sub.evil.com/x"), p))
  expect_true(grepl("is denied", e2, fixed = TRUE))
})

test_that("validate_tool_args ignores non-path/url args", {
  p <- agentgraph::tool_policy(path_allow = tempdir(), domain_allow = "example.com")
  expect_true(agentgraph::validate_tool_args(
    list(query = "anything", n = 5, url = "https://example.com"), p))
})

test_that("validate_tool_args accepts a JSON string", {
  p <- agentgraph::tool_policy(domain_allow = "example.com")
  expect_true(agentgraph::validate_tool_args('{"url":"https://example.com"}', p))
  e <- err_msg(agentgraph::validate_tool_args('{"url":"https://evil.com"}', p))
  expect_true(grepl("not allowed", e, fixed = TRUE))
})

test_that("restrict_tool validates args before delegating (direct call)", {
  allow <- normalizePath(tempdir(), winslash = "/", mustWork = FALSE)
  calls <- 0L
  t <- agentgraph::tool(
    name = "read",
    description = "read a file",
    parameters = list(path = agentgraph::param_string("path")),
    handler = function(args_json) {
      calls <<- calls + 1L
      '{"ok":true}'
    }
  )
  g <- agentgraph::restrict_tool(t, agentgraph::tool_policy(path_allow = allow))

  # allowed -> handler runs
  out <- g$handler(jsonlite::toJSON(list(path = file.path(allow, "x.csv")), auto_unbox = TRUE))
  expect_identical(calls, 1L)
  expect_identical(out, '{"ok":true}')

  # denied -> handler never runs
  outside <- file.path(dirname(allow), "evil.csv")
  e <- err_msg(g$handler(jsonlite::toJSON(list(path = outside), auto_unbox = TRUE)))
  expect_true(grepl("not within an allowed path", e, fixed = TRUE))
  expect_identical(calls, 1L)  # unchanged
})

test_that("restrict_tool validates its inputs", {
  e <- err_msg(agentgraph::restrict_tool(list(name = "x"), agentgraph::tool_policy()))
  expect_true(grepl("tool definition", e, fixed = TRUE))

  t <- agentgraph::tool(name = "x", description = "d",
                        parameters = list(), handler = function(a) '{}')
  e2 <- err_msg(agentgraph::restrict_tool(t, "nope"))
  expect_true(grepl("tool_policy()", e2, fixed = TRUE))
})

test_that("restrict_tool blocks a denied path end-to-end (mock LLM)", {
  testthat::skip_if_not(python_available())
  allow <- normalizePath(tempdir(), winslash = "/", mustWork = FALSE)
  outside <- normalizePath(file.path(dirname(allow), "evil.txt"),
                           winslash = "/", mustWork = FALSE)
  args_json <- jsonlite::toJSON(list(path = outside), auto_unbox = TRUE)

  m <- start_mock_llm(list(
    list(finish_reason = "tool_calls",
         tool_calls = list(list(id = "c1", name = "read", arguments = args_json))),
    list(finish_reason = "stop", content = "handled")
  ))
  on.exit(stop_py_mock(m), add = TRUE)

  provider <- agentgraph::provider_openai(
    api_key = "test", model = "mock-model",
    base_url = paste0("http://127.0.0.1:", m$port), max_retries = 0L
  )

  read_tool <- agentgraph::tool(
    name = "read",
    description = "read a file",
    parameters = list(path = agentgraph::param_string("path")),
    handler = function(args_json) '{"ok":true}'
  )
  restricted <- agentgraph::restrict_tool(read_tool, agentgraph::tool_policy(path_allow = allow))

  agent <- agentgraph::react_agent(provider, tools = list(restricted))
  r <- agentgraph::run_agent(agent, "read the file")

  tool_msgs <- Filter(function(x) identical(x$role, "tool"), r$state$messages)
  expect_length(tool_msgs, 1L)
  expect_true(grepl("tool policy", tool_msgs[[1]]$content, fixed = TRUE))
  expect_true(grepl("not within an allowed path", tool_msgs[[1]]$content, fixed = TRUE))
})
