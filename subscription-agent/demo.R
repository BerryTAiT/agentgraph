# Scripted end-to-end demo of the Streamly subscription agent.
# Exercises: plans -> register -> profile -> upgrade -> cancel, against the
# real LLM API, and prints the final database contents.

suppressPackageStartupMessages({
  library(agentgraph)
  library(DBI)
  library(RSQLite)
})

source("config.R")
source("db.R")
source("tools.R")
source("graph.R")

db_path <- normalizePath(config$db_path, mustWork = FALSE)
dir.create(dirname(db_path), showWarnings = FALSE, recursive = TRUE)
# Fresh database for a clean, reproducible demo.
if (file.exists(db_path)) invisible(file.remove(db_path))
Sys.setenv(AGENTGRAPH_DB_PATH = db_path)
db_init(db_path)

stopifnot(nzchar(config$api_key))

provider <- provider_openai(api_key = config$api_key,
                            model = config$model,
                            base_url = config$base_url)
graph <- build_graph(provider)
tools <- build_tools()

conversation <- c(
  "Hi! What subscriptions do you offer?",
  "My username is alice, my email is alice@example.com and my password is secret123.",
  "Show me my profile please.",
  "I want the monthly plan.",
  "Cancel my subscription please."
)

messages <- list()
for (turn in conversation) {
  cat("\n=== You: ", turn, " ===\n", sep = "")
  messages <- c(messages, list(user_msg(turn)))
  result <- run(graph, state = list(messages = messages), tools = tools)
  messages <- result$messages
  cat("Agent: ", tail(messages, 1)[[1]]$content, "\n", sep = "")
}

cat("\n=== Final database state ===\n")
con <- DBI::dbConnect(RSQLite::SQLite(), db_path)
on.exit(DBI::dbDisconnect(con), add = TRUE)
print(DBI::dbGetQuery(con, "SELECT username, email, plan, created_at FROM users"))
