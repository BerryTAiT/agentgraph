# Agent versioning & A/B ------------------------------------------------------
#
# save_agent() / load_agent() / agent_versions() give a small on-disk version
# registry (one .rds per version). ab_evaluate() runs two agents (or graphs, or
# functions) over a dataset with the evaluation framework and reports which is
# better — "rollback" is then just load_agent(name, older_version).

#' Default agent-registry directory
#'
#' @return The registry directory (overridable via
#'   `options(agentgraph.registry_dir = ...)`)
#' @export
agent_registry_dir <- function() {
  getOption("agentgraph.registry_dir",
            file.path(path.expand("~"), ".agentgraph", "agents"))
}

.sort_versions <- function(vers) {
  nv <- tryCatch(numeric_version(vers), error = function(e) NULL)
  if (!is.null(nv)) as.character(sort(nv)) else sort(vers)
}

.is_graph <- function(x) {
  is.list(x) && !is.null(x$entry_point) && !is.null(x$nodes) && !is.null(x$edges)
}

#' Save an agent (or graph) under a name and version
#'
#' Serializes `agent` to `<dir>/<name>/<version>.rds`. Only graph-based agents
#' and graphs serialize; `router_agent()` (an R closure) is rejected.
#'
#' @param agent An agent (from [chat_agent()], etc.) or a graph (from [state_graph()])
#' @param name Registry name
#' @param version Version tag (e.g. "1.0.0")
#' @param dir Registry directory (defaults to [agent_registry_dir()])
#' @return Invisibly the saved file path
#' @export
save_agent <- function(agent, name, version = "1.0.0", dir = NULL) {
  if (!is.character(name) || length(name) != 1L || is.na(name) || !nzchar(name)) {
    stop("save_agent(): `name` must be a single non-empty string.")
  }
  if (!is.character(version) || length(version) != 1L || is.na(version) || !nzchar(version)) {
    stop("save_agent(): `version` must be a single non-empty string.")
  }
  if (is_agent(agent)) {
    if (!is.null(agent$run_fn)) {
      stop("save_agent(): router_agent() is not serializable; only graph-based agents or graphs can be saved.")
    }
  } else if (!.is_graph(agent)) {
    stop("save_agent(): `agent` must be an agent or a graph.")
  }
  dir <- if (is.null(dir)) agent_registry_dir() else dir
  d <- file.path(dir, name)
  dir.create(d, recursive = TRUE, showWarnings = FALSE)
  path <- file.path(d, paste0(version, ".rds"))
  saveRDS(agent, path)
  invisible(path)
}

#' Load a saved agent (or graph)
#'
#' Loads `<dir>/<name>/<version>.rds`. With `version = NULL`, the highest
#' version is loaded.
#'
#' @param name Registry name
#' @param version Version tag, or NULL for the latest
#' @param dir Registry directory (defaults to [agent_registry_dir()])
#' @return The saved agent or graph
#' @export
load_agent <- function(name, version = NULL, dir = NULL) {
  dir <- if (is.null(dir)) agent_registry_dir() else dir
  d <- file.path(dir, name)
  if (!dir.exists(d)) stop("load_agent(): no agent named '", name, "'")
  files <- list.files(d, pattern = "\\.rds$", full.names = TRUE)
  if (length(files) == 0L) stop("load_agent(): no versions for '", name, "'")

  if (is.null(version)) {
    vers <- sub("\\.rds$", "", basename(files))
    sorted <- .sort_versions(vers)
    version <- sorted[[length(sorted)]]
  }
  path <- file.path(d, paste0(version, ".rds"))
  if (!file.exists(path)) {
    stop("load_agent(): version '", version, "' not found for '", name, "'")
  }
  readRDS(path)
}

#' List the saved versions of an agent
#'
#' @param name Registry name
#' @param dir Registry directory (defaults to [agent_registry_dir()])
#' @return A character vector of version tags (sorted)
#' @export
agent_versions <- function(name, dir = NULL) {
  dir <- if (is.null(dir)) agent_registry_dir() else dir
  d <- file.path(dir, name)
  if (!dir.exists(d)) return(character(0))
  vers <- sub("\\.rds$", "", basename(list.files(d, pattern = "\\.rds$")))
  .sort_versions(vers)
}

.as_eval_target <- function(target) {
  if (is_agent(target)) return(target)
  if (.is_graph(target)) return(new_agent(graph = target, tools = list()))
  target
}

#' A/B compare two agents over a dataset
#'
#' Runs both `a` and `b` through [evaluate()] on `dataset` and reports the mean
#' score of each and the winner. Accepts agents, graphs, or functions.
#'
#' @param a First target (agent, graph, or function)
#' @param b Second target
#' @param dataset An [eval_dataset()], data.frame, or character vector
#' @param evaluators A list of evaluators (see [eval_exact_match()], ...)
#' @param ... Extra arguments forwarded to the targets
#' @return A comparison object (class `agentgraph_ab`)
#' @export
ab_evaluate <- function(a, b, dataset, evaluators = list(), ...) {
  ra <- evaluate(.as_eval_target(a), dataset, evaluators, ...)
  rb <- evaluate(.as_eval_target(b), dataset, evaluators, ...)
  score_a <- if (nrow(ra$summary) == 0L) 1 else mean(ra$summary$mean_score)
  score_b <- if (nrow(rb$summary) == 0L) 1 else mean(rb$summary$mean_score)
  structure(
    list(a = ra, b = rb,
         score_a = score_a, score_b = score_b,
         winner = if (score_a >= score_b) "a" else "b"),
    class = "agentgraph_ab"
  )
}

#' Print an A/B comparison
#'
#' @param x A comparison from [ab_evaluate()]
#' @param ... Unused
#' @return `x`, invisibly
#' @export
print.agentgraph_ab <- function(x, ...) {
  cat(sprintf("agentgraph A/B: a=%.4f b=%.4f -> winner: %s\n",
              x$score_a, x$score_b, x$winner))
  invisible(x)
}
