# visualize() output contract and graph-structure introspection.

has <- function(txt, pat) any(grepl(pat, txt, fixed = TRUE))

test_that("visualize() renders node shapes and plain edges", {
  g <- state_graph(entry = "llm")
  g <- add_node(g, "llm",
                llm_node(provider_openai(api_key = "k", model = "m",
                                         base_url = "http://x")))
  g <- add_node(g, "tool", tool_node())
  g <- add_node(g, "router", router_node())
  inner <- state_graph(entry = "step")
  inner <- add_node(inner, "step", tool_node())
  g <- add_node(g, "sub", subgraph_node(inner))
  g <- add_node(g, "intr", interrupt_node())
  g <- add_node(g, "par", parallel_node(c("tool")))
  g <- add_edge(g, "llm", "tool")
  g <- add_edge(g, "tool", "router")
  g <- add_edge(g, "router", "sub")

  res <- withVisible(visualize(g))
  txt <- paste(capture.output(visualize(g)), collapse = "\n")

  expect_false(res$visible)
  expect_identical(res$value[[1]], "graph TD")

  expect_true(has(txt, "llm[") && has(txt, "LLM]"))
  expect_true(has(txt, "tool[") && has(txt, "Tool]"))
  expect_true(has(txt, "router{") && has(txt, "Router}"))
  expect_true(has(txt, "sub[sub]"))
  expect_true(has(txt, "intr[intr]"))
  expect_true(has(txt, "par[par]"))
  expect_true(has(txt, "__end__((END))"))

  expect_true(has(txt, "llm --> tool"))
  expect_true(has(txt, "tool --> router"))
  expect_true(has(txt, "router --> sub"))
})

test_that("visualize() renders conditional edge labels", {
  g2 <- state_graph(entry = "router")
  g2 <- add_node(g2, "router", router_node())
  g2 <- add_node(g2, "tool", tool_node())
  g2 <- add_conditional_edge(g2, "router",
                             route_on("decision",
                                      rules = list(approve = "tool",
                                                   reject = "__end__")))
  txt2 <- paste(capture.output(visualize(g2)), collapse = "\n")

  expect_true(has(txt2, "router -->|approve| tool"))
  expect_true(has(txt2, "router -->|reject| __end__"))
})

test_that("route_on() exposes field, rules, and default", {
  ro <- route_on("action", rules = list(yes = "a", no = "b"), default = "b")
  expect_identical(ro$field, "action")
  expect_identical(ro$default, "b")
  expect_identical(names(ro$rules), c("yes", "no"))
})
