test_that("RPC tool server handles single, concurrent, and unknown-tool calls", {
  in_tool <- list(
    name = "in_tool",
    handler = function(args_json) {
      args <- jsonlite::fromJSON(args_json, simplifyVector = FALSE)
      jsonlite::toJSON(list(result = args$x * 2), auto_unbox = TRUE)
    }
  )

  server <- NULL
  on.exit(if (!is.null(server)) agentgraph:::.stop_tool_server(server), add = TRUE)

  server <- agentgraph:::.start_tool_server(list(in_tool))
  expect_true(!is.null(server$port) && is.numeric(server$port))
  port <- server$port

  base <- agentgraph:::rpc_call_cpp(port, "in_tool", '{"x":5}')
  expect_true(base$ok)
  expect_equal(
    as.numeric(jsonlite::fromJSON(base$result, simplifyVector = FALSE)$result),
    10
  )

  stress <- agentgraph:::rpc_stress_cpp(
    port, "in_tool", '{"x":3}', n_calls = 8L, n_threads = 4L
  )
  expect_identical(stress$n, 8L)
  expect_identical(stress$ok, 8L)
  expect_true(all(vapply(stress$calls, function(c) isTRUE(c$ok), logical(1))))
  vals <- vapply(stress$calls,
                 function(c) jsonlite::fromJSON(c$result, simplifyVector = FALSE)$result,
                 numeric(1))
  expect_true(all(vals == 6))

  bad <- agentgraph:::rpc_call_cpp(port, "no_such_tool", "{}")
  expect_false(bad$ok)
  expect_true(grepl("Tool not found", bad$error, fixed = TRUE))
})
