# Every built-in provider works with chat(), stream() and graph nodes.
library(agentgraph)

# OpenAI (default base URL)
p <- provider_openai(api_key = "sk-...")

# Anthropic (via its OpenAI-compatible endpoint)
p <- provider_anthropic(api_key = "sk-ant-...")

# Ollama (local, no key needed)
p <- provider_ollama(model = "llama3")

# Google Gemini
p <- provider_gemini(api_key = "...")

# Mistral
p <- provider_mistral(api_key = "...")

# Groq (fast inference)
p <- provider_groq(api_key = "...")

# Cohere
p <- provider_cohere(api_key = "...")

# Azure OpenAI (deployment + endpoint + api-key auth)
p <- provider_azure(
  api_key = "...",
  deployment = "gpt-4o",
  endpoint = "https://my-resource.openai.azure.com"
)

# AWS Bedrock (SigV4 auth with your AWS credentials)
p <- provider_bedrock(
  aws_access_key_id = "...",
  aws_secret_access_key = "...",
  region = "us-east-1",
  model = "us.anthropic.claude-sonnet-4-20250514-v1:0"
)

# Any other OpenAI-compatible API also works with a custom provider list,
# e.g. DeepSeek via an aggregator:
deepseek <- list(
  name = "openai",
  api_key = "sk-...",
  model = "deepseek-chat",
  base_url = "https://api.deepseek.com/v1",
  max_tokens = 4096L,
  temperature = 0.7
)

# resp <- chat("Hello!", provider = deepseek)
