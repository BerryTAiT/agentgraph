run_subgraph_case <- function(scenario, make_graph) {
  m <- start_mock_llm(scenario)
  on.exit(stop_py_mock(m), add = TRUE)
  provider <- mock_provider(m)
  graph <- make_graph(provider)
  res <- run(graph, state = list(messages = list(user_msg("go"))))
  list(prompts = sys_prompts(m$log), result = res)
}

test_that("flat subgraph runs inner nodes then outer node", {
  testthat::skip_if_not(python_available())
  r <- run_subgraph_case(
    list(list(finish_reason = "stop", content = "from inner 1"),
         list(finish_reason = "stop", content = "from inner 2"),
         list(finish_reason = "stop", content = "from outer")),
    function(p) {
      inner <- state_graph(entry = "i1") |>
        add_node("i1", llm_node(provider = p, system_prompt = "INNER-1")) |>
        add_node("i2", llm_node(provider = p, system_prompt = "INNER-2")) |>
        add_edge("i1", "i2") |>
        add_edge("i2", "__end__")

      state_graph(entry = "group") |>
        add_node("group", subgraph_node(inner)) |>
        add_node("outer", llm_node(provider = p, system_prompt = "OUTER")) |>
        add_edge("group", "outer") |>
        add_edge("outer", "__end__")
    })

  expect_identical(r$prompts, c("INNER-1", "INNER-2", "OUTER"))
  final <- tail(r$result$messages, 1)[[1]]
  expect_identical(final$role, "assistant")
  expect_identical(final$content, "from outer")
  expect_length(r$result$messages, 4L)
  expect_false(is_interrupted(r$result))
})

test_that("nested subgraph runs leaf, mid, then top", {
  testthat::skip_if_not(python_available())
  r <- run_subgraph_case(
    list(list(finish_reason = "stop", content = "leaf"),
         list(finish_reason = "stop", content = "mid"),
         list(finish_reason = "stop", content = "top")),
    function(p) {
      leaf <- state_graph(entry = "leaf") |>
        add_node("leaf", llm_node(provider = p, system_prompt = "LEAF")) |>
        add_edge("leaf", "__end__")

      mid <- state_graph(entry = "midgroup") |>
        add_node("midgroup", subgraph_node(leaf)) |>
        add_node("mid", llm_node(provider = p, system_prompt = "MID")) |>
        add_edge("midgroup", "mid") |>
        add_edge("mid", "__end__")

      state_graph(entry = "topgroup") |>
        add_node("topgroup", subgraph_node(mid)) |>
        add_node("top", llm_node(provider = p, system_prompt = "TOP")) |>
        add_edge("topgroup", "top") |>
        add_edge("top", "__end__")
    })

  expect_identical(r$prompts, c("LEAF", "MID", "TOP"))
  final <- tail(r$result$messages, 1)[[1]]
  expect_identical(final$content, "top")
})
