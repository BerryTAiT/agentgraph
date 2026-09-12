test_that("providers construct with the expected fields", {
  p <- provider_openai(model = "deepseek-v4-flash", base_url = "http://x/v1")
  expect_identical(p$name, "openai")
  expect_identical(p$model, "deepseek-v4-flash")
  expect_identical(p$base_url, "http://x/v1")
  expect_true(is.integer(p$max_tokens))

  pa <- provider_anthropic()
  expect_identical(pa$name, "anthropic")

  po <- provider_ollama()
  expect_identical(po$name, "openai")
  expect_identical(po$api_key, "ollama")
})

test_that("node constructors populate type and config fields", {
  p <- provider_openai(model = "m", base_url = "http://x")

  n_llm <- llm_node(p, system_prompt = "hi", tools = "calculator")
  expect_identical(n_llm$type, "llm")
  expect_identical(n_llm$system_prompt, "hi")
  expect_identical(n_llm$tool_names, "calculator")

  n_tool <- tool_node()
  expect_identical(n_tool$type, "tool")

  n_router <- router_node(route_field = "next", rules = list(a = "b"), default_route = "__end__")
  expect_identical(n_router$type, "router")
  expect_identical(n_router$rules$a, "b")

  n_int <- interrupt_node()
  expect_identical(n_int$type, "interrupt")

  n_par <- parallel_node(c("x", "y"))
  expect_identical(n_par$type, "parallel")
  expect_identical(n_par$sub_node_ids, c("x", "y"))
})

test_that("graph builders and edges record structure correctly", {
  p <- provider_openai(model = "m", base_url = "http://x")
  n_llm <- llm_node(p)

  g <- state_graph(entry = "start", max_iterations = 10L)
  expect_s3_class(g, "agentgraph")
  expect_identical(g$entry_point, "start")
  expect_identical(g$max_iterations, 10L)

  g <- add_node(g, "start", n_llm)
  g <- add_node(g, "tools", tool_node())
  g <- add_edge(g, "start", "tools")
  expect_identical(g$edges[[1]]$from, "start")
  expect_identical(g$edges[[1]]$to, "tools")
  expect_false(g$edges[[1]]$is_conditional)

  r <- route_on("decision", rules = list(yes = "tools", no = "__end__"), default = "__end__")
  g <- add_conditional_edge(g, "tools", r)
  ce <- g$edges[[2]]
  expect_true(ce$is_conditional)
  expect_identical(ce$route_field, "decision")
  expect_identical(ce$route_map$yes, "tools")
  expect_identical(ce$default_route, "__end__")
})

test_that("tools and parameters serialize into a JSON schema", {
  t <- tool("add", "adds two numbers",
            parameters = list(a = param_number("left"),
                              b = param_integer("right", required = FALSE)),
            handler = function(args) "{}")
  expect_identical(t$name, "add")
  expect_identical(t$description, "adds two numbers")

  pj <- jsonlite::fromJSON(t$parameters_json)
  expect_identical(pj$type, "object")
  expect_identical(pj$properties$a$type, "number")
  expect_identical(pj$required, "a")

  pe <- param_enum("mode", c("on", "off"))
  expect_identical(pe$schema$enum, c("on", "off"))

  po2 <- param_object("cfg", properties = list(x = param_boolean("flag")))
  expect_identical(po2$schema$type, "object")
})

test_that("message helpers and reducers behave as documented", {
  u <- user_msg("hello")
  expect_identical(u$role, "user")
  expect_identical(u$content, "hello")

  s <- system_msg("sys")
  expect_identical(s$role, "system")

  a <- assistant_msg("hi")
  expect_identical(a$role, "assistant")

  tm <- tool_msg("id1", "42")
  expect_identical(tm$role, "tool")
  expect_identical(tm$tool_call_id, "id1")

  expect_length(append_messages(list(u), list(a)), 2L)
  expect_identical(overwrite(1, 2), 2)

  m <- merge_state(list(a = 1), list(b = 2))
  expect_identical(m$a, 1)
  expect_identical(m$b, 2)
})

test_that("subgraph nodes wrap an inner graph", {
  p <- provider_openai(model = "m", base_url = "http://x")
  g2 <- state_graph(entry = "inner")
  g2 <- add_node(g2, "inner", llm_node(p))
  sg <- subgraph_node(g2)
  expect_identical(sg$type, "subgraph")
  expect_identical(sg$sub_graph$entry_point, "inner")
})
