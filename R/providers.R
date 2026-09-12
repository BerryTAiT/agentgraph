#' Create an OpenAI provider configuration
#'
#' @param api_key API key (or set OPENAI_API_KEY env var)
#' @param model Model name
#' @param base_url Base URL for the API
#' @param max_tokens Maximum tokens in response
#' @param temperature Sampling temperature
#' @return A provider configuration list
#' @export
provider_openai <- function(api_key = Sys.getenv("OPENAI_API_KEY"),
                            model = "gpt-4o",
                            base_url = "https://api.openai.com/v1",
                            max_tokens = 4096,
                            temperature = 0.7) {
  list(
    name = "openai",
    api_key = api_key,
    model = model,
    base_url = base_url,
    max_tokens = as.integer(max_tokens),
    temperature = temperature
  )
}

#' Create an Anthropic provider configuration
#'
#' @param api_key API key (or set ANTHROPIC_API_KEY env var)
#' @param model Model name
#' @param base_url Base URL for the API
#' @param max_tokens Maximum tokens in response
#' @param temperature Sampling temperature
#' @return A provider configuration list
#' @export
provider_anthropic <- function(api_key = Sys.getenv("ANTHROPIC_API_KEY"),
                               model = "claude-sonnet-4-20250514",
                               base_url = "https://api.anthropic.com",
                               max_tokens = 4096,
                               temperature = 0.7) {
  list(
    name = "anthropic",
    api_key = api_key,
    model = model,
    base_url = base_url,
    max_tokens = as.integer(max_tokens),
    temperature = temperature
  )
}

#' Create an Ollama provider configuration
#'
#' @param model Model name
#' @param base_url Base URL for the Ollama server
#' @param max_tokens Maximum tokens in response
#' @param temperature Sampling temperature
#' @return A provider configuration list
#' @export
provider_ollama <- function(model = "llama3",
                            base_url = "http://localhost:11434/v1",
                            max_tokens = 4096,
                            temperature = 0.7) {
  list(
    name = "openai",
    api_key = "ollama",
    model = model,
    base_url = base_url,
    max_tokens = as.integer(max_tokens),
    temperature = temperature
  )
}
