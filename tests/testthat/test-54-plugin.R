# Plugin / extension system (R/plugin.R).

test_that("register_plugin / call_plugin / list_plugins / unregister", {
  agentgraph::register_plugin("demo", "double", function(x) x * 2)
  expect_true(agentgraph::has_plugin("demo", "double"))
  expect_identical(agentgraph::call_plugin("demo", "double", 21), 42)

  pl <- agentgraph::list_plugins("demo")
  expect_identical(pl$name, "double")

  agentgraph::unregister_plugin("demo", "double")
  expect_false(agentgraph::has_plugin("demo", "double"))

  e <- err_msg(agentgraph::call_plugin("demo", "double", 1))
  expect_true(grepl("plugin not found", e, fixed = TRUE))
})

test_that("register_plugin rejects duplicates unless overwrite", {
  agentgraph::register_plugin("demo", "dup", function() 1)
  e <- err_msg(agentgraph::register_plugin("demo", "dup", function() 2))
  expect_true(grepl("already registered", e, fixed = TRUE))

  agentgraph::register_plugin("demo", "dup", function() 2, overwrite = TRUE)
  expect_identical(agentgraph::call_plugin("demo", "dup"), 2)

  agentgraph::unregister_plugin("demo", "dup")
})

test_that("register_plugin validates its inputs", {
  e <- err_msg(agentgraph::register_plugin("", "x", function() 1))
  expect_true(grepl("non-empty", e, fixed = TRUE))

  e2 <- err_msg(agentgraph::register_plugin("k", "a::b", function() 1))
  expect_true(grepl("without '::'", e2, fixed = TRUE))

  e3 <- err_msg(agentgraph::register_plugin("k", "n", 42))
  expect_true(grepl("function", e3, fixed = TRUE))
})

test_that("register_provider + provider dispatch a factory", {
  agentgraph::register_provider("mystery", function(base_url) {
    agentgraph::provider_openai(api_key = "k", base_url = base_url)
  })
  p <- agentgraph::provider("mystery", base_url = "http://plugin.example/v1")
  expect_identical(p$name, "openai")
  expect_identical(p$base_url, "http://plugin.example/v1")

  agentgraph::unregister_plugin("provider", "mystery")
})

test_that("register_tool + get_tool round-trip", {
  t <- agentgraph::tool(name = "greet", description = "d",
                        parameters = list(), handler = function(a) '{}')
  agentgraph::register_tool("greet", t)
  got <- agentgraph::get_tool("greet")
  expect_identical(got$name, "greet")
  expect_true(is.function(got$handler))

  agentgraph::unregister_plugin("tool", "greet")
})

test_that("register_tool validates its tool", {
  e <- err_msg(agentgraph::register_tool("x", list(name = "x")))
  expect_true(grepl("tool definition", e, fixed = TRUE))
})
