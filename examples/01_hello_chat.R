# Example 1: Single chat message (requires a real API key)
library(agentgraph)

provider <- provider_openai(model = "gpt-4o")

response <- chat(
  message = "Explain what a neural network is in one sentence.",
  provider = provider,
  system_prompt = "You are a concise, helpful assistant."
)

cat("Response:", response$content, "\n")
cat("Tokens used:", response$total_tokens, "\n")
