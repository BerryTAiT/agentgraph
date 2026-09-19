# Provider constructors all return a plain named list understood by the C++
# engine (`provider_from_list()`). Shared HTTP reliability knobs are accepted
# by every constructor so users can tune retry/backoff and rate limiting per
# provider without touching C++:
#   - max_retries          0 disables retry; N retries transient failures (429/5xx)
#   - retry_base_delay_ms  initial backoff, grows exponentially per attempt
#   - retry_max_delay_ms    cap on the backoff delay
#   - requests_per_minute  0 disables the token-bucket; N caps requests/minute

#' Create an OpenAI provider configuration
#'
#' @param api_key API key (or set OPENAI_API_KEY env var)
#' @param model Model name
#' @param base_url Base URL for the API
#' @param max_tokens Maximum tokens in response
#' @param temperature Sampling temperature
#' @param max_retries Retry transient HTTP failures (429/5xx); 0 disables
#' @param retry_base_delay_ms Initial backoff delay (ms), doubles each attempt
#' @param retry_max_delay_ms Upper bound on the backoff delay (ms)
#' @param requests_per_minute Token-bucket request cap; 0 disables rate limiting
#' @return A provider configuration list
#' @export
provider_openai <- function(api_key = Sys.getenv("OPENAI_API_KEY"),
                            model = "gpt-4o",
                            base_url = "https://api.openai.com/v1",
                            max_tokens = 4096,
                            temperature = 0.7,
                            max_retries = 3L,
                            retry_base_delay_ms = 500L,
                            retry_max_delay_ms = 8000L,
                            requests_per_minute = 0L) {
  if (length(max_tokens) != 1L || is.na(max_tokens) || max_tokens < 0) {
    stop("provider_openai(): `max_tokens` must be a non-negative number.")
  }
  if (length(temperature) != 1L || is.na(temperature) || temperature < 0) {
    stop("provider_openai(): `temperature` must be a non-negative number.")
  }
  if (length(max_retries) != 1L || is.na(max_retries) || max_retries < 0) {
    stop("provider_openai(): `max_retries` must be a non-negative number.")
  }
  list(
    name = "openai",
    api_key = api_key,
    model = model,
    base_url = base_url,
    max_tokens = as.integer(max_tokens),
    temperature = temperature,
    max_retries = as.integer(max_retries),
    retry_base_delay_ms = as.integer(retry_base_delay_ms),
    retry_max_delay_ms = as.integer(retry_max_delay_ms),
    requests_per_minute = as.integer(requests_per_minute)
  )
}

#' Enable exact LLM caching on a provider configuration
#'
#' Wraps an existing provider (or fallback chain) so that identical requests are
#' served from an in-process cache instead of hitting the HTTP API. The cache key
#' is the full request (messages + tools + system prompt) plus the
#' provider/model/sampling identity, so two calls are only considered identical
#' when they would produce the same response. Entries persist across `chat()`,
#' `stream()`, and graph runs within the same R process.
#'
#' @param provider A provider configuration list (from \code{provider_openai()},
#'   \code{provider_anthropic()}, \code{provider_fallback()}, etc.)
#' @param ttl_seconds Cache entry lifetime in seconds; \code{0} means never expire
#' @param max_entries Maximum cached entries for this provider; \code{0} means unlimited
#' @return A provider configuration list with caching enabled
#' @export
#' @examples
#' provider_cache(provider_openai(model = "gpt-4o"), ttl_seconds = 60)
provider_cache <- function(provider, ttl_seconds = 300, max_entries = 1000) {
  if (!is.list(provider) || is.null(provider$name)) {
    stop("provider_cache(): `provider` must be a provider configuration list")
  }
  provider$cache_ttl_seconds <- as.integer(ttl_seconds)
  provider$cache_max_entries <- as.integer(max_entries)
  provider
}

#' Clear the process-wide LLM exact cache
#'
#' @param namespace Optional provider namespace to clear; empty (the default)
#'   clears all cached providers.
#' @return Invisibly \code{NULL}
#' @export
cache_clear <- function(namespace = "") {
  invisible(cache_clear_cpp(namespace))
}

#' Enable PII scrubbing on a provider configuration
#'
#' Wraps an existing provider (or fallback chain) so that message content,
#' text parts, tool results, tool-call arguments, and the system prompt are
#' redacted for common PII — email addresses, API keys, US SSNs, phone
#' numbers, credit-card-like digit runs, and IPv4 addresses — before every
#' outbound HTTP call to the LLM endpoint. Scrub patterns match the
#' standalone [pii_scrub()] helper.
#'
#' @param provider A provider configuration list (from \code{provider_openai()},
#'   \code{provider_anthropic()}, \code{provider_fallback()}, etc.)
#' @param redact Replacement text for redacted values
#' @return A provider configuration list with PII filtering enabled
#' @export
#' @examples
#' provider_pii(provider_openai(model = "gpt-4o"))
provider_pii <- function(provider, redact = "[REDACTED]") {
  if (!is.list(provider) || is.null(provider$name)) {
    stop("provider_pii(): `provider` must be a provider configuration list")
  }
  if (!is.character(redact) || length(redact) != 1L || is.na(redact)) {
    stop("provider_pii(): `redact` must be a single non-NA string")
  }
  provider$pii_filter <- TRUE
  provider$pii_redact <- redact
  provider
}

#' Snapshot the process-wide LLM exact cache
#'
#' @return A data.frame with one row per cached provider namespace and its
#'   current entry count.
#' @export
cache_stats <- function() {
  cache_stats_cpp()
}

#' Create an Anthropic provider configuration
#'
#' Uses Anthropic's OpenAI-compatible endpoint, so the native C++ client
#' speaks the chat-completions format directly.
#'
#' @param api_key API key (or set ANTHROPIC_API_KEY env var)
#' @param model Model name
#' @param base_url Base URL for the API
#' @param max_tokens Maximum tokens in response
#' @param temperature Sampling temperature
#' @param max_retries Retry transient HTTP failures (429/5xx); 0 disables
#' @param retry_base_delay_ms Initial backoff delay (ms), doubles each attempt
#' @param retry_max_delay_ms Upper bound on the backoff delay (ms)
#' @param requests_per_minute Token-bucket request cap; 0 disables rate limiting
#' @return A provider configuration list
#' @export
provider_anthropic <- function(api_key = Sys.getenv("ANTHROPIC_API_KEY"),
                               model = "claude-sonnet-4-20250514",
                               base_url = "https://api.anthropic.com/v1",
                               max_tokens = 4096,
                               temperature = 0.7,
                               max_retries = 3L,
                               retry_base_delay_ms = 500L,
                               retry_max_delay_ms = 8000L,
                               requests_per_minute = 0L) {
  list(
    name = "anthropic",
    api_key = api_key,
    model = model,
    base_url = base_url,
    max_tokens = as.integer(max_tokens),
    temperature = temperature,
    max_retries = as.integer(max_retries),
    retry_base_delay_ms = as.integer(retry_base_delay_ms),
    retry_max_delay_ms = as.integer(retry_max_delay_ms),
    requests_per_minute = as.integer(requests_per_minute)
  )
}

#' Create an Ollama provider configuration
#'
#' @param model Model name
#' @param base_url Base URL for the Ollama server
#' @param max_tokens Maximum tokens in response
#' @param temperature Sampling temperature
#' @param max_retries Retry transient HTTP failures (429/5xx); 0 disables
#' @param retry_base_delay_ms Initial backoff delay (ms), doubles each attempt
#' @param retry_max_delay_ms Upper bound on the backoff delay (ms)
#' @param requests_per_minute Token-bucket request cap; 0 disables rate limiting
#' @return A provider configuration list
#' @export
provider_ollama <- function(model = "llama3",
                            base_url = "http://localhost:11434/v1",
                            max_tokens = 4096,
                            temperature = 0.7,
                            max_retries = 3L,
                            retry_base_delay_ms = 500L,
                            retry_max_delay_ms = 8000L,
                            requests_per_minute = 0L) {
  list(
    name = "openai",
    api_key = "ollama",
    model = model,
    base_url = base_url,
    max_tokens = as.integer(max_tokens),
    temperature = temperature,
    max_retries = as.integer(max_retries),
    retry_base_delay_ms = as.integer(retry_base_delay_ms),
    retry_max_delay_ms = as.integer(retry_max_delay_ms),
    requests_per_minute = as.integer(requests_per_minute)
  )
}

#' Create a Google Gemini provider configuration
#'
#' Uses Gemini's OpenAI-compatible endpoint, so chat(), stream() and graph
#' nodes all work with no extra setup.
#'
#' @param api_key API key (or set GEMINI_API_KEY env var)
#' @param model Model name
#' @param base_url Base URL for the API
#' @param max_tokens Maximum tokens in response
#' @param temperature Sampling temperature
#' @param max_retries Retry transient HTTP failures (429/5xx); 0 disables
#' @param retry_base_delay_ms Initial backoff delay (ms), doubles each attempt
#' @param retry_max_delay_ms Upper bound on the backoff delay (ms)
#' @param requests_per_minute Token-bucket request cap; 0 disables rate limiting
#' @return A provider configuration list
#' @export
provider_gemini <- function(api_key = Sys.getenv("GEMINI_API_KEY"),
                            model = "gemini-2.0-flash",
                            base_url = "https://generativelanguage.googleapis.com/v1beta/openai",
                            max_tokens = 4096,
                            temperature = 0.7,
                            max_retries = 3L,
                            retry_base_delay_ms = 500L,
                            retry_max_delay_ms = 8000L,
                            requests_per_minute = 0L) {
  list(
    name = "openai",
    api_key = api_key,
    model = model,
    base_url = base_url,
    max_tokens = as.integer(max_tokens),
    temperature = temperature,
    max_retries = as.integer(max_retries),
    retry_base_delay_ms = as.integer(retry_base_delay_ms),
    retry_max_delay_ms = as.integer(retry_max_delay_ms),
    requests_per_minute = as.integer(requests_per_minute)
  )
}

#' Create a Mistral provider configuration
#'
#' @param api_key API key (or set MISTRAL_API_KEY env var)
#' @param model Model name
#' @param base_url Base URL for the API
#' @param max_tokens Maximum tokens in response
#' @param temperature Sampling temperature
#' @param max_retries Retry transient HTTP failures (429/5xx); 0 disables
#' @param retry_base_delay_ms Initial backoff delay (ms), doubles each attempt
#' @param retry_max_delay_ms Upper bound on the backoff delay (ms)
#' @param requests_per_minute Token-bucket request cap; 0 disables rate limiting
#' @return A provider configuration list
#' @export
provider_mistral <- function(api_key = Sys.getenv("MISTRAL_API_KEY"),
                             model = "mistral-large-latest",
                             base_url = "https://api.mistral.ai/v1",
                             max_tokens = 4096,
                             temperature = 0.7,
                             max_retries = 3L,
                             retry_base_delay_ms = 500L,
                             retry_max_delay_ms = 8000L,
                             requests_per_minute = 0L) {
  list(
    name = "openai",
    api_key = api_key,
    model = model,
    base_url = base_url,
    max_tokens = as.integer(max_tokens),
    temperature = temperature,
    max_retries = as.integer(max_retries),
    retry_base_delay_ms = as.integer(retry_base_delay_ms),
    retry_max_delay_ms = as.integer(retry_max_delay_ms),
    requests_per_minute = as.integer(requests_per_minute)
  )
}

#' Create a Groq provider configuration
#'
#' @param api_key API key (or set GROQ_API_KEY env var)
#' @param model Model name
#' @param base_url Base URL for the API
#' @param max_tokens Maximum tokens in response
#' @param temperature Sampling temperature
#' @param max_retries Retry transient HTTP failures (429/5xx); 0 disables
#' @param retry_base_delay_ms Initial backoff delay (ms), doubles each attempt
#' @param retry_max_delay_ms Upper bound on the backoff delay (ms)
#' @param requests_per_minute Token-bucket request cap; 0 disables rate limiting
#' @return A provider configuration list
#' @export
provider_groq <- function(api_key = Sys.getenv("GROQ_API_KEY"),
                          model = "llama-3.3-70b-versatile",
                          base_url = "https://api.groq.com/openai/v1",
                          max_tokens = 4096,
                          temperature = 0.7,
                          max_retries = 3L,
                          retry_base_delay_ms = 500L,
                          retry_max_delay_ms = 8000L,
                          requests_per_minute = 0L) {
  list(
    name = "openai",
    api_key = api_key,
    model = model,
    base_url = base_url,
    max_tokens = as.integer(max_tokens),
    temperature = temperature,
    max_retries = as.integer(max_retries),
    retry_base_delay_ms = as.integer(retry_base_delay_ms),
    retry_max_delay_ms = as.integer(retry_max_delay_ms),
    requests_per_minute = as.integer(requests_per_minute)
  )
}

#' Create a Cohere provider configuration
#'
#' Uses Cohere's OpenAI-compatible endpoint.
#'
#' @param api_key API key (or set COHERE_API_KEY env var)
#' @param model Model name
#' @param base_url Base URL for the API
#' @param max_tokens Maximum tokens in response
#' @param temperature Sampling temperature
#' @param max_retries Retry transient HTTP failures (429/5xx); 0 disables
#' @param retry_base_delay_ms Initial backoff delay (ms), doubles each attempt
#' @param retry_max_delay_ms Upper bound on the backoff delay (ms)
#' @param requests_per_minute Token-bucket request cap; 0 disables rate limiting
#' @return A provider configuration list
#' @export
provider_cohere <- function(api_key = Sys.getenv("COHERE_API_KEY"),
                            model = "command-r-plus-08-2024",
                            base_url = "https://api.cohere.com/compatibility/v1",
                            max_tokens = 4096,
                            temperature = 0.7,
                            max_retries = 3L,
                            retry_base_delay_ms = 500L,
                            retry_max_delay_ms = 8000L,
                            requests_per_minute = 0L) {
  list(
    name = "openai",
    api_key = api_key,
    model = model,
    base_url = base_url,
    max_tokens = as.integer(max_tokens),
    temperature = temperature,
    max_retries = as.integer(max_retries),
    retry_base_delay_ms = as.integer(retry_base_delay_ms),
    retry_max_delay_ms = as.integer(retry_max_delay_ms),
    requests_per_minute = as.integer(requests_per_minute)
  )
}

#' Create an Azure OpenAI provider configuration
#'
#' Azure uses the `api-key` header (not Bearer) and requires a deployment
#' name plus an API version in the URL; both are handled by the C++ engine
#' when the provider name is "azure".
#'
#' @param api_key Azure OpenAI key (or set AZURE_OPENAI_API_KEY env var)
#' @param deployment Your Azure deployment name (required)
#' @param endpoint Resource endpoint, e.g. "https://my-resource.openai.azure.com"
#'   (or set AZURE_OPENAI_ENDPOINT env var)
#' @param api_version Azure API version string
#' @param max_tokens Maximum tokens in response
#' @param temperature Sampling temperature
#' @param max_retries Retry transient HTTP failures (429/5xx); 0 disables
#' @param retry_base_delay_ms Initial backoff delay (ms), doubles each attempt
#' @param retry_max_delay_ms Upper bound on the backoff delay (ms)
#' @param requests_per_minute Token-bucket request cap; 0 disables rate limiting
#' @return A provider configuration list
#' @export
provider_azure <- function(api_key = Sys.getenv("AZURE_OPENAI_API_KEY"),
                           deployment,
                           endpoint = Sys.getenv("AZURE_OPENAI_ENDPOINT"),
                           api_version = "2024-10-21",
                           max_tokens = 4096,
                           temperature = 0.7,
                           max_retries = 3L,
                           retry_base_delay_ms = 500L,
                           retry_max_delay_ms = 8000L,
                           requests_per_minute = 0L) {
  if (missing(deployment)) {
    stop("provider_azure(): `deployment` is required (your Azure deployment name)")
  }
  if (is.null(endpoint) || nchar(endpoint) == 0) {
    stop("provider_azure(): `endpoint` is required, e.g. https://my-resource.openai.azure.com")
  }
  endpoint <- sub("/+$", "", endpoint)

  list(
    name = "azure",
    api_key = api_key,
    model = deployment,
    base_url = paste0(endpoint, "/openai/deployments/", deployment),
    api_version = api_version,
    max_tokens = as.integer(max_tokens),
    temperature = temperature,
    max_retries = as.integer(max_retries),
    retry_base_delay_ms = as.integer(retry_base_delay_ms),
    retry_max_delay_ms = as.integer(retry_max_delay_ms),
    requests_per_minute = as.integer(requests_per_minute)
  )
}

#' Create a provider fallback chain
#'
#' Tries each provider in order, falling through to the next only when the
#' previous one fails hard (its retries are exhausted or it returns a
#' non-transient error such as a bad status, timeout, or network failure).
#' The first successful response wins, so a temporarily-down primary provider
#' silently fails over to a backup.
#'
#' @param ... Two or more provider configurations (from \code{provider_openai()},
#'   \code{provider_anthropic()}, \code{provider_local()}, etc.). The first is
#'   the primary; the rest are tried in order as backups.
#' @return A provider configuration list with name "fallback"
#' @export
#' @examples
#' provider_fallback(
#'   provider_openai(model = "gpt-4o"),
#'   provider_anthropic(model = "claude-sonnet-4-20250514"),
#'   provider_local(model = "mistral-7b")
#' )
provider_fallback <- function(...) {
  providers <- list(...)
  if (length(providers) < 2L) {
    stop("provider_fallback(): provide at least 2 provider configurations")
  }
  for (p in providers) {
    if (!is.list(p) || is.null(p$name)) {
      stop("provider_fallback(): each argument must be a provider configuration ",
           "from provider_openai(), provider_anthropic(), etc.")
    }
  }
  primary <- providers[[1L]]
  list(
    name = "fallback",
    model = if (is.null(primary$model)) "fallback" else as.character(primary$model),
    fallbacks = providers
  )
}

#' Create an AWS Bedrock provider configuration
#'
#' Authenticates with AWS Signature Version 4 (implemented in the C++ engine)
#' against Bedrock's OpenAI-compatible endpoint. Credentials default to the
#' standard AWS environment variables.
#'
#' @param aws_access_key_id AWS access key (or set AWS_ACCESS_KEY_ID env var)
#' @param aws_secret_access_key AWS secret key (or set AWS_SECRET_ACCESS_KEY env var)
#' @param aws_session_token Optional session token for temporary credentials
#'   (or set AWS_SESSION_TOKEN env var)
#' @param region AWS region (or set AWS_REGION env var)
#' @param model Bedrock model ID, e.g. "us.anthropic.claude-sonnet-4-20250514-v1:0"
#' @param max_tokens Maximum tokens in response
#' @param temperature Sampling temperature
#' @param max_retries Retry transient HTTP failures (429/5xx); 0 disables
#' @param retry_base_delay_ms Initial backoff delay (ms), doubles each attempt
#' @param retry_max_delay_ms Upper bound on the backoff delay (ms)
#' @param requests_per_minute Token-bucket request cap; 0 disables rate limiting
#' @return A provider configuration list
#' @export
provider_bedrock <- function(aws_access_key_id = Sys.getenv("AWS_ACCESS_KEY_ID"),
                             aws_secret_access_key = Sys.getenv("AWS_SECRET_ACCESS_KEY"),
                             aws_session_token = Sys.getenv("AWS_SESSION_TOKEN"),
                             region = Sys.getenv("AWS_REGION", "us-east-1"),
                             model = "us.anthropic.claude-sonnet-4-20250514-v1:0",
                             max_tokens = 4096,
                             temperature = 0.7,
                             max_retries = 3L,
                             retry_base_delay_ms = 500L,
                             retry_max_delay_ms = 8000L,
                             requests_per_minute = 0L) {
  list(
    name = "bedrock",
    api_key = "",
    model = model,
    base_url = paste0("https://bedrock-runtime.", region, ".amazonaws.com/openai/v1"),
    aws_access_key_id = aws_access_key_id,
    aws_secret_access_key = aws_secret_access_key,
    aws_session_token = aws_session_token,
    aws_region = region,
    max_tokens = as.integer(max_tokens),
    temperature = temperature,
    max_retries = as.integer(max_retries),
    retry_base_delay_ms = as.integer(retry_base_delay_ms),
    retry_max_delay_ms = as.integer(retry_max_delay_ms),
    requests_per_minute = as.integer(requests_per_minute)
  )
}
