# Interactive console for the Streamly subscription agent.
#
# Run from the app directory (so source() finds the sibling files), e.g.:
#   setwd("path/to/subscription-agent"); source("main.R")
#   ...or from a shell:  Rscript main.R
#
# Set your key first:
#   Sys.setenv(AGENTGRAPH_API_KEY = "sk-...")     # or set it in your shell

suppressPackageStartupMessages({
  library(agentgraph)
})

source("config.R")
source("db.R")
source("tools.R")
source("graph.R")

db_path <- normalizePath(config$db_path, mustWork = FALSE)
dir.create(dirname(db_path), showWarnings = FALSE, recursive = TRUE)
Sys.setenv(AGENTGRAPH_DB_PATH = db_path)
db_init(db_path)

if (!nzchar(config$api_key)) {
  cat("AGENTGRAPH_API_KEY is not set. Set it first, e.g.:\n",
      '  Sys.setenv(AGENTGRAPH_API_KEY = "sk-...")\n', sep = "")
  quit(save = "no", status = 1)
}

provider <- provider_openai(api_key = config$api_key,
                            model = config$model,
                            base_url = config$base_url)
graph <- build_graph(provider)
tools <- build_tools()

read_line <- function(prompt = "You: ") {
  cat(prompt)
  flush.console()
  if (interactive()) {
    readline()
  } else {
    con <- file("stdin", "r")
    on.exit(close(con), add = TRUE)
    readLines(con, n = 1L, warn = FALSE)
  }
}

cat("Streamly support agent — type 'quit' to exit.\n")
cat("Database:", db_path, "\n\n")

messages <- list()
repeat {
  input <- read_line()
  if (length(input) == 0) break
  line <- trimws(input)
  if (line %in% c("quit", "exit", "q")) break
  if (!nzchar(line)) next

  messages <- c(messages, list(user_msg(line)))
  result <- tryCatch(
    run(graph, state = list(messages = messages), tools = tools),
    error = function(e) { cat("ERROR:", conditionMessage(e), "\n"); NULL }
  )
  if (is.null(result)) next

  messages <- result$messages
  reply <- tail(messages, 1)[[1]]$content
  cat("Agent:", reply, "\n\n")
}
