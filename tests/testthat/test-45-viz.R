# Interactive graph visualization (R/ui-helpers.R).

test_that("graph_mermaid renders nodes and edges", {
  g <- state_graph(entry = "a")
  g <- add_node(g, "a", llm_node(provider_openai(api_key = "k", model = "m", base_url = "http://x")))
  g <- add_node(g, "b", tool_node())
  g <- add_edge(g, "a", "b")
  g <- add_edge(g, "b", "__end__")

  md <- agentgraph::graph_mermaid(g)
  expect_identical(md[[1]], "graph TD")
  expect_true(any(grepl("a[", md, fixed = TRUE)))
  expect_true(any(grepl("b[", md, fixed = TRUE)))
  expect_true(any(grepl("a --> b", md, fixed = TRUE)))
  expect_true(any(grepl("__end__((END))", md, fixed = TRUE)))
})

test_that("visualize writes an interactive HTML file", {
  g <- state_graph(entry = "a")
  g <- add_node(g, "a", llm_node(provider_openai(api_key = "k", model = "m", base_url = "http://x")))
  g <- add_edge(g, "a", "__end__")

  f <- tempfile(fileext = ".html")
  res <- withVisible(agentgraph::visualize(g, file = f))
  expect_false(res$visible)
  expect_identical(res$value, f)
  expect_true(file.exists(f))

  html <- paste(readLines(f, warn = FALSE), collapse = "\n")
  expect_true(grepl("mermaid", html, fixed = TRUE))
  expect_true(grepl("graph TD", html, fixed = TRUE))
  expect_true(grepl("class=\"mermaid\"", html, fixed = TRUE))
})

test_that("plot.agentgraph prints the mermaid source", {
  g <- state_graph(entry = "a")
  g <- add_node(g, "a", tool_node())
  out <- capture.output(plot(g))
  expect_true(any(grepl("graph TD", out, fixed = TRUE)))
})

test_that("graph_mermaid validates its input", {
  e <- err_msg(agentgraph::graph_mermaid("nope"))
  expect_true(grepl("graph object", e, fixed = TRUE))

  g <- state_graph(entry = "a")
  e2 <- err_msg(agentgraph::visualize(g, file = NA_character_))
  expect_true(grepl("single non-empty path", e2, fixed = TRUE))
})
