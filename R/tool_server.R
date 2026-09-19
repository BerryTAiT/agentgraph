# Internal: start the isolated R tool-server process for custom tools.
#
# Custom R tool handlers cannot be called back from the C++ engine's worker
# threads: the main R thread is blocked inside .Call(run_graph_cpp) while the
# graph executes, and R is single-threaded. Instead, handlers are serialized
# into a separate R process (the "tool server", inst/tools/tool_server.R)
# that listens on a local TCP port; the C++ engine calls it over a
# newline-framed JSON protocol (see src/tools/rpc_tool_client.cpp).
#
# Not exported: managed automatically by run() and resume().

.start_tool_server <- function(tools,
                               port_range = c(25100L, 25200L),
                               timeout = 30) {
  defs <- lapply(tools, function(t) list(name = t$name, handler = t$handler))

  handlers_file <- tempfile(pattern = "agentgraph_handlers_", fileext = ".rds")
  saveRDS(defs, handlers_file)

  port_file <- tempfile(pattern = "agentgraph_port_", fileext = ".txt")
  stdout_file <- tempfile(pattern = "agentgraph_srvout_")
  stderr_file <- tempfile(pattern = "agentgraph_srverr_")

  script <- system.file("tools", "tool_server.R", package = "agentgraph")
  if (!nzchar(script)) {
    stop("agentgraph: tool_server.R missing from the installed package ",
         "(reinstall agentgraph).")
  }

  # Per-run auth token: the server rejects any request without it, so no other
  # process can drive tool execution on the port while this run is alive.
  # Generated in the parent and passed only via argv (visible only to the
  # child) and the returned handle (never written to disk or logs).
  token <- paste(
    sample(c(letters, LETTERS, 0:9), 32, replace = TRUE),
    collapse = ""
  )

  rscript <- file.path(
    R.home("bin"),
    if (.Platform$OS.type == "windows") "Rscript.exe" else "Rscript"
  )

  p <- processx::process$new(
    rscript,
    c(script, handlers_file, port_file,
      as.character(port_range[1]), as.character(port_range[2]), token),
    stdout = stdout_file,
    stderr = stderr_file,
    cleanup = TRUE
  )

  deadline <- Sys.time() + timeout
  while (!file.exists(port_file) && p$is_alive() && Sys.time() < deadline) {
    Sys.sleep(0.05)
  }

  if (!file.exists(port_file)) {
    err_text <- ""
    if (file.exists(stderr_file)) {
      err_text <- paste(readLines(stderr_file, warn = FALSE), collapse = "\n")
    }
    tryCatch(p$kill(), error = function(e) NULL)
    stop("agentgraph: tool server failed to start\n", err_text)
  }

  port <- suppressWarnings(as.integer(readLines(port_file, warn = FALSE)[1]))
  if (is.na(port)) {
    tryCatch(p$kill(), error = function(e) NULL)
    stop("agentgraph: tool server reported an invalid port.")
  }

  list(process = p,
       port = port,
       token = token,
       files = c(handlers_file, port_file, stdout_file, stderr_file))
}

# Internal: stop a tool server started by .start_tool_server().
.stop_tool_server <- function(server) {
  if (is.null(server)) return(invisible(NULL))
  tryCatch({
    if (server$process$is_alive()) server$process$kill()
  }, error = function(e) NULL)
  tryCatch(unlink(server$files), error = function(e) NULL)
  invisible(NULL)
}
