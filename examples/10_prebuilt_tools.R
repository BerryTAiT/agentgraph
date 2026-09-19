# Example 10: Pre-built tools (web search, Wikipedia, arXiv, code execution,
# CSV/PDF reading, SQL). Each constructor returns a ready-made tool object that
# runs in agentgraph's isolated tool-server process.
library(agentgraph)

provider <- provider_openai(model = "gpt-4o")

# Assemble a small agent. The `tools =` names on the LLM node must match the
# `name` field of each tool object passed to run().
t_web  <- tool_web_search()
t_wiki <- tool_wikipedia()
t_arxiv <- tool_arxiv()
t_code <- tool_code_exec()

graph <- state_graph(entry = "agent") |>
  add_node("agent", llm_node(
    provider = provider,
    system_prompt = "Answer questions using the tools available to you.",
    tools = c("web_search", "wikipedia_search", "arxiv_search", "code_exec")
  )) |>
  add_node("tools", tool_node()) |>
  add_conditional_edge("agent", route_on(
    field = "has_tool_calls",
    rules = c("true" = "tools", "false" = "__end__")
  )) |>
  add_edge("tools", "agent")

result <- run(
  graph,
  state = list(messages = list(user_msg("Who was Ada Lovelace?"))),
  tools = list(t_web, t_wiki, t_arxiv, t_code)
)

cat("Final answer:", tail(result$messages, 1)[[1]]$content, "\n")

# Other ready-made tools:
#   tool_http_request()         generic REST calls (Slack, GitHub, Jira, ...)
#   tool_read_csv()             load + preview CSV files
#   tool_read_pdf()             extract text from PDFs (requires pdftools)
#   tool_sql(db_path = "...")   run SQL against SQLite (requires DBI + RSQLite)
