test_that("parallel fan-out runs children then join, collecting outputs", {
  testthat::skip_if_not(python_available())
  s <- start_latent_mock(0.0)
  on.exit(stop_py_mock(s), add = TRUE)
  provider <- mock_provider(s)

  graph <- state_graph(entry = "fan") |>
    add_node("a", llm_node(provider = provider, system_prompt = "PAR-A")) |>
    add_node("b", llm_node(provider = provider, system_prompt = "PAR-B")) |>
    add_node("c", llm_node(provider = provider, system_prompt = "PAR-C")) |>
    add_node("fan", parallel_node(c("a", "b", "c"))) |>
    add_node("join", llm_node(provider = provider, system_prompt = "JOIN")) |>
    add_edge("fan", "join") |>
    add_edge("join", "__end__")

  res <- run(graph, state = list(messages = list(user_msg("go"))), n_threads = 3L)
  prompts <- readLines(s$log, warn = FALSE)

  expect_identical(sort(prompts[1:3]), c("PAR-A", "PAR-B", "PAR-C"))
  expect_identical(prompts[4], "JOIN")
  expect_length(prompts, 4L)

  contents <- sort(vapply(res$messages, function(m) m$content, character(1)))
  expect_identical(contents, sort(c("go", "JOIN", "PAR-A", "PAR-B", "PAR-C")))
  expect_identical(tail(res$messages, 1)[[1]]$content, "JOIN")
  expect_length(res$messages, 5L)
  expect_false(is_interrupted(res))
})

test_that("parallel children overlap (finish faster than serial)", {
  testthat::skip_if_not(python_available())
  s <- start_latent_mock(0.6)
  on.exit(stop_py_mock(s), add = TRUE)
  provider <- mock_provider(s)

  graph <- state_graph(entry = "fan") |>
    add_node("a", llm_node(provider = provider, system_prompt = "PAR-A")) |>
    add_node("b", llm_node(provider = provider, system_prompt = "PAR-B")) |>
    add_node("c", llm_node(provider = provider, system_prompt = "PAR-C")) |>
    add_node("fan", parallel_node(c("a", "b", "c"))) |>
    add_edge("fan", "__end__")

  t0 <- proc.time()
  res <- run(graph, state = list(messages = list(user_msg("go"))), n_threads = 3L)
  elapsed <- (proc.time() - t0)[["elapsed"]]

  logged <- sort(readLines(s$log, warn = FALSE))
  expect_identical(logged, c("PAR-A", "PAR-B", "PAR-C"))
  contents <- sort(vapply(res$messages, function(m) m$content, character(1)))
  expect_identical(contents, sort(c("PAR-A", "PAR-B", "PAR-C", "go")))
  expect_lt(elapsed, 1.3)
})
