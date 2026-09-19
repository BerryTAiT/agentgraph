# Cost tracking --------------------------------------------------------------
#
# A best-effort pricing table plus helpers to estimate and report the cost of
# LLM usage. `agentgraph_usage()` reports the session's accumulated tokens and
# estimated cost (tracked in the C++ engine per call, so multi-model runs are
# priced correctly). `provider_pricing()` attaches per-token prices to a
# provider so the `max_cost_usd` budget/kill switch can enforce a dollar cap.

#' Best-effort LLM pricing table
#'
#' A named list of model -> `c(input = ..., output = ...)` prices in USD per 1M
#' tokens. This is a curated snapshot for convenience and may drift; verify
#' current pricing for anything production-critical.
#'
#' @export
agentgraph_prices <- list(
  "gpt-4o"          = c(input = 2.50, output = 10.00),
  "gpt-4o-mini"     = c(input = 0.15, output = 0.60),
  "gpt-4.1"         = c(input = 2.00, output = 8.00),
  "gpt-4.1-mini"    = c(input = 0.40, output = 1.60),
  "gpt-4.1-nano"    = c(input = 0.10, output = 0.40),
  "o3-mini"         = c(input = 1.10, output = 4.40),
  "claude-sonnet-4" = c(input = 3.00, output = 15.00),
  "claude-opus-4"   = c(input = 15.00, output = 75.00),
  "gemini-2.0-flash" = c(input = 0.10, output = 0.40),
  "gemini-1.5-pro"  = c(input = 1.25, output = 5.00),
  "llama-3.3-70b"   = c(input = 0.59, output = 0.79)
)

#' Estimate the cost of an LLM completion
#'
#' Looks up `model` in `prices` (a named list of `c(input, output)` USD per 1M
#' tokens) and computes `prompt_tokens * input + completion_tokens * output`
#' over 1e6.
#'
#' @param prompt_tokens Number of input tokens
#' @param completion_tokens Number of output tokens
#' @param model Model name (a key of `prices`)
#' @param prices A pricing table (default [agentgraph_prices()])
#' @return Estimated cost in USD
#' @export
estimate_cost <- function(prompt_tokens, completion_tokens, model,
                          prices = agentgraph_prices) {
  if (!is.character(model) || length(model) != 1L || is.na(model)) {
    stop("estimate_cost(): `model` must be a single non-NA string.")
  }
  p <- prices[[model]]
  if (is.null(p)) {
    stop("estimate_cost(): no price for model '", model,
         "'. Pass a custom `prices` list or use provider_pricing().")
  }
  (as.numeric(prompt_tokens) * p[["input"]] +
     as.numeric(completion_tokens) * p[["output"]]) / 1e6
}

#' Attach per-token pricing to a provider
#'
#' Sets the input/output price (USD per 1M tokens) on a provider configuration
#' so the engine can estimate cost. Required for the [run()] `max_cost_usd`
#' kill switch to fire; without pricing, cost is not tracked.
#'
#' @param provider A provider configuration list
#' @param input_per_1m Input price in USD per 1M tokens
#' @param output_per_1m Output price in USD per 1M tokens
#' @return The provider configuration with pricing attached
#' @export
provider_pricing <- function(provider, input_per_1m, output_per_1m) {
  if (!is.list(provider) || is.null(provider$name)) {
    stop("provider_pricing(): `provider` must be a provider configuration list.")
  }
  provider$input_price_per_1m <- as.numeric(input_per_1m)
  provider$output_price_per_1m <- as.numeric(output_per_1m)
  provider
}

#' Report this session's accumulated LLM usage
#'
#' Returns the process-wide totals of prompt/completion/total tokens and the
#' estimated cost (USD) accumulated across every LLM call made in this R
#' session. Cost is estimated in the engine using each provider's pricing, so
#' multi-model sessions are priced correctly; providers without pricing
#' contribute tokens but no cost.
#'
#' @return A data.frame with one row: `prompt_tokens`, `completion_tokens`,
#'   `total_tokens`, `cost_usd`
#' @export
agentgraph_usage <- function() {
  s <- usage_stats_cpp()
  data.frame(
    prompt_tokens = s$prompt_tokens,
    completion_tokens = s$completion_tokens,
    total_tokens = s$total_tokens,
    cost_usd = round(s$cost_usd, 6),
    stringsAsFactors = FALSE
  )
}

#' Reset the session usage accumulator
#'
#' @return Invisibly `NULL`
#' @export
usage_reset <- function() {
  invisible(usage_reset_cpp())
}
