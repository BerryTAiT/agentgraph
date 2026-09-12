# Central configuration for the Streamly subscription agent.
# Override any of these with environment variables before running.

config <- list(
  api_key  = Sys.getenv("AGENTGRAPH_API_KEY",  unset = ""),
  model    = Sys.getenv("AGENTGRAPH_MODEL",    unset = ""),
  base_url = Sys.getenv("AGENTGRAPH_BASE_URL", unset = ""),
  db_path  = Sys.getenv("AGENTGRAPH_DB_PATH",  unset = file.path(getwd(), "data", "subscription_agent.sqlite"))
)

# Plan catalog (single source of truth; mirrored in graph.R's system prompt).
PLANS <- list(
  monthly = list(name = "Monthly", price = 300,  period = "month", description = "Full movie access, billed monthly."),
  annual  = list(name = "Annual",  price = 1000, period = "year",  description = "Full movie access, billed yearly (best value).")
)
