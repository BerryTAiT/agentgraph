# Multi-tenancy ---------------------------------------------------------------
#
# A tenant() config carries per-tenant rate limits, usage caps, and an optional
# audit log. run(..., tenant = ...) enforces the limits before executing and
# records the run's token/cost usage + an audit line afterwards. tenant_usage()
# reports per-tenant totals; tenant_namespace() prefixes vector-store names.

# Registered tenant configs (tenant_id -> tenant config).
.agentgraph_tenants <- new.env(parent = emptyenv())
# Per-tenant usage state (tenant_id -> environment with counters).
.agentgraph_tenant_usage <- new.env(parent = emptyenv())

.tenant_state <- function(tenant_id) {
  if (!exists(tenant_id, envir = .agentgraph_tenant_usage, inherits = FALSE)) {
    st <- new.env(parent = emptyenv())
    st$requests <- 0L
    st$total_tokens <- 0
    st$cost_usd <- 0
    st$request_times <- numeric()
    assign(tenant_id, st, envir = .agentgraph_tenant_usage)
  }
  get(tenant_id, envir = .agentgraph_tenant_usage, inherits = FALSE)
}

.get_tenant_config <- function(tenant_id) {
  cfg <- get0(tenant_id, envir = .agentgraph_tenants, inherits = FALSE)
  if (is.null(cfg)) stop("tenant not found: ", tenant_id, " (create it with tenant())")
  cfg
}

#' Create a tenant configuration
#'
#' Defines per-tenant limits and an optional audit log. Pass it to [run()] via
#' `tenant =`; limits are enforced per tenant across runs (0 = unlimited).
#'
#' @param tenant_id A non-empty tenant identifier
#' @param requests_per_minute Rate limit (0 = unlimited)
#' @param max_requests Cumulative request cap (0 = unlimited)
#' @param max_total_tokens Cumulative token cap (0 = unlimited)
#' @param max_cost_usd Cumulative cost cap in USD (0 = unlimited)
#' @param audit_path Optional JSONL file to append an audit line per run
#' @return A tenant object (class `agentgraph_tenant`)
#' @export
tenant <- function(tenant_id, requests_per_minute = 0, max_requests = 0,
                   max_total_tokens = 0, max_cost_usd = 0, audit_path = NULL) {
  if (!is.character(tenant_id) || length(tenant_id) != 1L || is.na(tenant_id) || !nzchar(tenant_id)) {
    stop("tenant(): `tenant_id` must be a single non-empty string.")
  }
  cfg <- structure(list(
    tenant_id = tenant_id,
    requests_per_minute = as.integer(requests_per_minute),
    max_requests = as.integer(max_requests),
    max_total_tokens = as.numeric(max_total_tokens),
    max_cost_usd = as.numeric(max_cost_usd),
    audit_path = if (is.null(audit_path)) "" else as.character(audit_path)[1L]
  ), class = "agentgraph_tenant")
  assign(tenant_id, cfg, envir = .agentgraph_tenants)
  cfg
}

# Enforce a tenant's limits before a run (raises on violation).
.tenant_check <- function(t) {
  st <- .tenant_state(t$tenant_id)
  if (t$requests_per_minute > 0L) {
    now <- as.numeric(Sys.time())
    st$request_times <- st$request_times[st$request_times > now - 60]
    if (length(st$request_times) >= t$requests_per_minute) {
      stop("tenant '", t$tenant_id, "' rate limit exceeded (",
           t$requests_per_minute, " requests/minute)")
    }
  }
  if (t$max_requests > 0L && st$requests >= t$max_requests) {
    stop("tenant '", t$tenant_id, "' max_requests exceeded (", t$max_requests, ")")
  }
  if (t$max_total_tokens > 0 && st$total_tokens >= t$max_total_tokens) {
    stop("tenant '", t$tenant_id, "' max_total_tokens exceeded (", t$max_total_tokens, ")")
  }
  if (t$max_cost_usd > 0 && st$cost_usd >= t$max_cost_usd) {
    stop("tenant '", t$tenant_id, "' max_cost_usd exceeded (", t$max_cost_usd, ")")
  }
  invisible(TRUE)
}

# Record a completed run's usage against a tenant (and write an audit line).
.tenant_record <- function(t, tokens, cost_usd) {
  st <- .tenant_state(t$tenant_id)
  st$requests <- st$requests + 1L
  st$request_times <- c(st$request_times, as.numeric(Sys.time()))
  st$total_tokens <- st$total_tokens + tokens
  st$cost_usd <- st$cost_usd + cost_usd

  if (nzchar(t$audit_path)) {
    line <- jsonlite::toJSON(list(
      ts_ms = as.numeric(Sys.time()) * 1000,
      tenant_id = t$tenant_id,
      tokens = tokens,
      cost_usd = cost_usd
    ), auto_unbox = TRUE)
    write(line, t$audit_path, append = TRUE)
  }
  invisible(NULL)
}

#' Report a tenant's usage
#'
#' @param tenant_id A tenant ID previously created with [tenant()]
#' @return A data.frame with one row: usage totals and the tenant's limits
#' @export
tenant_usage <- function(tenant_id) {
  cfg <- .get_tenant_config(tenant_id)
  st <- .tenant_state(tenant_id)
  data.frame(
    tenant_id = tenant_id,
    requests = st$requests,
    total_tokens = st$total_tokens,
    cost_usd = round(st$cost_usd, 6),
    requests_per_minute = cfg$requests_per_minute,
    max_requests = cfg$max_requests,
    max_total_tokens = cfg$max_total_tokens,
    max_cost_usd = cfg$max_cost_usd,
    stringsAsFactors = FALSE
  )
}

#' Read a tenant's audit log
#'
#' Returns the audit lines written for `tenant_id` (requires the tenant to have
#' been created with an `audit_path`).
#'
#' @param tenant_id A tenant ID
#' @return A data.frame with columns `ts_ms`, `tenant_id`, `tokens`, `cost_usd`
#' @export
tenant_audit <- function(tenant_id) {
  cfg <- .get_tenant_config(tenant_id)
  empty <- data.frame(ts_ms = numeric(0), tenant_id = character(0),
                      tokens = numeric(0), cost_usd = numeric(0))
  if (!nzchar(cfg$audit_path) || !file.exists(cfg$audit_path)) return(empty)
  lines <- readLines(cfg$audit_path, warn = FALSE)
  lines <- lines[nzchar(lines)]
  if (length(lines) == 0L) return(empty)
  out <- lapply(lines, function(l) jsonlite::fromJSON(l, simplifyVector = FALSE))
  data.frame(
    ts_ms = vapply(out, function(x) x$ts_ms, numeric(1)),
    tenant_id = vapply(out, function(x) x$tenant_id, character(1)),
    tokens = vapply(out, function(x) x$tokens, numeric(1)),
    cost_usd = vapply(out, function(x) x$cost_usd, numeric(1)),
    stringsAsFactors = FALSE
  )
}

#' Reset tenant usage counters
#'
#' @param tenant_id Optional tenant ID; NULL resets all tenants
#' @return `NULL`, invisibly
#' @export
tenant_reset <- function(tenant_id = NULL) {
  if (is.null(tenant_id)) {
    ids <- ls(.agentgraph_tenant_usage, all.names = TRUE)
    for (id in ids) rm(list = id, envir = .agentgraph_tenant_usage)
  } else {
    if (exists(tenant_id, envir = .agentgraph_tenant_usage, inherits = FALSE)) {
      rm(list = tenant_id, envir = .agentgraph_tenant_usage)
    }
  }
  invisible(NULL)
}

#' Namespace a resource name for a tenant
#'
#' Prefixes `name` with the tenant ID for per-tenant isolation of resources
#' such as vector-store collection names.
#'
#' @param tenant_id A tenant ID
#' @param name A resource name (e.g. a collection name)
#' @return The namespaced name `"<tenant_id>::<name>"`
#' @export
tenant_namespace <- function(tenant_id, name) {
  paste0(tenant_id, "::", name)
}

#' Print a tenant configuration
#'
#' @param x A tenant from [tenant()]
#' @param ... Unused
#' @return `x`, invisibly
#' @export
print.agentgraph_tenant <- function(x, ...) {
  cat(sprintf("agentgraph tenant: %s\n", x$tenant_id))
  if (x$requests_per_minute > 0L) cat("  requests_per_minute:", x$requests_per_minute, "\n")
  if (x$max_requests > 0L) cat("  max_requests:", x$max_requests, "\n")
  if (x$max_total_tokens > 0) cat("  max_total_tokens:", x$max_total_tokens, "\n")
  if (x$max_cost_usd > 0) cat("  max_cost_usd:", x$max_cost_usd, "\n")
  if (nzchar(x$audit_path)) cat("  audit_path:", x$audit_path, "\n")
  invisible(x)
}
