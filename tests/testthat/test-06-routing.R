run_routing_case <- function(scenario, build) {
  m <- start_mock_llm(scenario)
  on.exit(stop_py_mock(m), add = TRUE)
  provider <- mock_provider(m)
  graph <- build(provider)
  run(graph, state = list(messages = list(user_msg("go"))))
  sys_prompts(m$log)
}

test_that("boolean route false -> B", {
  testthat::skip_if_not(python_available())
  prompts <- run_routing_case(
    list(list(finish_reason = "stop", content = "done")),
    function(p) {
      state_graph(entry = "gate") |>
        add_node("gate", llm_node(provider = p, system_prompt = "GATE")) |>
        add_node("A", llm_node(provider = p, system_prompt = "A")) |>
        add_node("B", llm_node(provider = p, system_prompt = "B")) |>
        add_conditional_edge("gate", route_on(field = "has_tool_calls",
                                              rules = c("true" = "A", "false" = "B"))) |>
        add_edge("A", "__end__") |>
        add_edge("B", "__end__")
    }
  )
  expect_identical(prompts, c("GATE", "B"))
})

test_that("boolean route true -> A", {
  testthat::skip_if_not(python_available())
  prompts <- run_routing_case(
    list(list(finish_reason = "tool_calls",
              tool_calls = list(list(id = "c1", name = "calculator",
                                     arguments = '{"expression":"1+1"}'))),
         list(finish_reason = "stop", content = "ok")),
    function(p) {
      state_graph(entry = "gate") |>
        add_node("gate", llm_node(provider = p, system_prompt = "GATE")) |>
        add_node("A", llm_node(provider = p, system_prompt = "A")) |>
        add_node("B", llm_node(provider = p, system_prompt = "B")) |>
        add_conditional_edge("gate", route_on(field = "has_tool_calls",
                                              rules = c("true" = "A", "false" = "B"))) |>
        add_edge("A", "__end__") |>
        add_edge("B", "__end__")
    }
  )
  expect_identical(prompts, c("GATE", "A"))
})

test_that("string route length -> B", {
  testthat::skip_if_not(python_available())
  prompts <- run_routing_case(
    list(list(finish_reason = "length", content = "")),
    function(p) {
      state_graph(entry = "gate") |>
        add_node("gate", llm_node(provider = p, system_prompt = "GATE")) |>
        add_node("A", llm_node(provider = p, system_prompt = "A")) |>
        add_node("B", llm_node(provider = p, system_prompt = "B")) |>
        add_node("D", llm_node(provider = p, system_prompt = "D")) |>
        add_conditional_edge("gate", route_on(field = "last_finish_reason",
                                              rules = c("stop" = "A", "length" = "B"),
                                              default = "D")) |>
        add_edge("A", "__end__") |>
        add_edge("B", "__end__") |>
        add_edge("D", "__end__")
    }
  )
  expect_identical(prompts, c("GATE", "B"))
})

test_that("missing route field -> default D", {
  testthat::skip_if_not(python_available())
  prompts <- run_routing_case(
    list(list(finish_reason = "stop", content = "done")),
    function(p) {
      state_graph(entry = "gate") |>
        add_node("gate", llm_node(provider = p, system_prompt = "GATE")) |>
        add_node("A", llm_node(provider = p, system_prompt = "A")) |>
        add_node("D", llm_node(provider = p, system_prompt = "D")) |>
        add_conditional_edge("gate", route_on(field = "no_such_field",
                                              rules = c("x" = "A"), default = "D")) |>
        add_edge("A", "__end__") |>
        add_edge("D", "__end__")
    }
  )
  expect_identical(prompts, c("GATE", "D"))
})

test_that("unmatched route value -> default D", {
  testthat::skip_if_not(python_available())
  prompts <- run_routing_case(
    list(list(finish_reason = "stop", content = "done")),
    function(p) {
      state_graph(entry = "gate") |>
        add_node("gate", llm_node(provider = p, system_prompt = "GATE")) |>
        add_node("A", llm_node(provider = p, system_prompt = "A")) |>
        add_node("D", llm_node(provider = p, system_prompt = "D")) |>
        add_conditional_edge("gate", route_on(field = "last_finish_reason",
                                              rules = c("length" = "A"), default = "D")) |>
        add_edge("A", "__end__") |>
        add_edge("D", "__end__")
    }
  )
  expect_identical(prompts, c("GATE", "D"))
})
