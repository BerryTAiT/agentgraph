# Evaluation framework --------------------------------------------------------
#
# Run an agent (or any answer-producing function) over a dataset of examples
# and score each answer with one or more evaluators (exact match, substring,
# regex, numeric, LLM-as-judge, embedding similarity, or a custom function).
# Pure R on top of run_agent()/chat()/embed() — no C++ changes.

# Dataset ---------------------------------------------------------------------

#' Create an evaluation dataset
#'
#' A dataset is a set of inputs (optionally with reference answers) that an
#' agent is evaluated over.
#'
#' @param input Character vector of user inputs
#' @param expected Optional character vector of reference answers (same length
#'   as `input`; empty strings mean "no reference")
#' @return A dataset object usable with [evaluate()]
#' @export
eval_dataset <- function(input, expected = NULL) {
  if (is.list(input)) input <- vapply(input, function(x) as.character(x)[1], "")
  input <- as.character(input)
  if (length(input) == 0L) {
    stop("eval_dataset(): `input` must contain at least one example.")
  }
  if (any(!nzchar(input))) {
    stop("eval_dataset(): every input must be a non-empty string.")
  }
  if (is.null(expected)) {
    expected <- rep("", length(input))
  } else {
    if (is.list(expected)) expected <- vapply(expected, function(x) as.character(x)[1], "")
    expected <- as.character(expected)
    if (length(expected) != length(input)) {
      stop("eval_dataset(): `expected` must have the same length as `input`.")
    }
    expected[is.na(expected)] <- ""
  }
  structure(list(input = input, expected = expected),
            class = "agentgraph_eval_dataset")
}

.as_eval_dataset <- function(x) {
  if (inherits(x, "agentgraph_eval_dataset")) return(x)
  if (is.data.frame(x)) {
    if (!"input" %in% names(x)) {
      stop("evaluate(): a data.frame dataset must have an `input` column.")
    }
    expected <- if ("expected" %in% names(x)) x$expected else NULL
    return(eval_dataset(x$input, expected))
  }
  if (is.character(x) || is.list(x)) return(eval_dataset(x))
  stop("evaluate(): `dataset` must be an eval_dataset(), a data.frame with an `input` column, or a character vector of inputs.")
}

# Evaluators ------------------------------------------------------------------

new_evaluator <- function(name, fn) {
  if (!is.character(name) || length(name) != 1L || !nzchar(name)) {
    stop("evaluator name must be a non-empty string.")
  }
  if (!is.function(fn)) stop("evaluator `fn` must be a function.")
  structure(list(name = name, fn = fn), class = "agentgraph_evaluator")
}

#' Evaluator: exact string match against the reference answer
#'
#' @param case_sensitive If TRUE, compare case-sensitively
#' @param trim If TRUE, trim surrounding whitespace before comparing
#' @return An evaluator object usable with [evaluate()]
#' @export
eval_exact_match <- function(case_sensitive = TRUE, trim = TRUE) {
  new_evaluator("exact_match", function(prediction, example) {
    if (!nzchar(example$expected)) {
      return(list(score = 0, passed = FALSE, reason = "example has no expected answer"))
    }
    a <- if (trim) trimws(prediction) else prediction
    b <- if (trim) trimws(example$expected) else example$expected
    if (!case_sensitive) {
      a <- tolower(a)
      b <- tolower(b)
    }
    ok <- identical(a, b)
    list(score = as.numeric(ok), passed = ok, reason = "")
  })
}

#' Evaluator: check that required substrings appear in the answer
#'
#' @param needles Character vector of substrings that must appear in the answer
#' @param all If TRUE (default) every needle must appear; if FALSE any one suffices
#' @param case_sensitive If TRUE, compare case-sensitively
#' @return An evaluator object usable with [evaluate()]
#' @export
eval_contains <- function(needles, all = TRUE, case_sensitive = FALSE) {
  needles <- as.character(needles)
  needles <- needles[nzchar(needles)]
  if (length(needles) == 0L) {
    stop("eval_contains(): `needles` must contain at least one non-empty string.")
  }
  new_evaluator("contains", function(prediction, example) {
    hay <- if (case_sensitive) prediction else tolower(prediction)
    hits <- vapply(needles, function(nd) {
      n <- if (case_sensitive) nd else tolower(nd)
      grepl(n, hay, fixed = TRUE)
    }, logical(1))
    score <- mean(hits)
    passed <- if (all) all(hits) else any(hits)
    list(score = score, passed = passed, reason = "")
  })
}

#' Evaluator: check the answer against a regular expression
#'
#' The pattern is applied to the agent's answer (not to the reference).
#'
#' @param pattern Regular expression (as in [grepl()])
#' @param ignore_case If TRUE, case-insensitive matching
#' @return An evaluator object usable with [evaluate()]
#' @export
eval_regex <- function(pattern, ignore_case = FALSE) {
  if (!is.character(pattern) || length(pattern) != 1L || !nzchar(pattern)) {
    stop("eval_regex(): `pattern` must be a single non-empty string.")
  }
  new_evaluator("regex", function(prediction, example) {
    ok <- grepl(pattern, prediction, ignore.case = ignore_case, perl = TRUE)
    list(score = as.numeric(ok), passed = ok, reason = "")
  })
}

#' Evaluator: compare numbers appearing in the answer and the reference
#'
#' Extracts every number from both texts; the example passes when each number
#' in the reference appears in the answer within `tolerance`.
#'
#' @param tolerance Allowed absolute difference between numbers
#' @return An evaluator object usable with [evaluate()]
#' @export
eval_numeric <- function(tolerance = 1e-6) {
  tolerance <- as.numeric(tolerance)[1]
  if (is.na(tolerance) || tolerance < 0) {
    stop("eval_numeric(): `tolerance` must be a non-negative number.")
  }
  extract <- function(text) {
    m <- regmatches(text, gregexpr("-?[0-9]+(?:\\.[0-9]+)?", text))[[1]]
    as.numeric(m)
  }
  new_evaluator("numeric", function(prediction, example) {
    if (!nzchar(example$expected)) {
      return(list(score = 0, passed = FALSE, reason = "example has no expected answer"))
    }
    exp_nums <- extract(example$expected)
    if (length(exp_nums) == 0L) {
      return(list(score = 0, passed = FALSE, reason = "expected answer contains no numbers"))
    }
    pred_nums <- extract(prediction)
    if (length(pred_nums) == 0L) {
      return(list(score = 0, passed = FALSE, reason = "answer contains no numbers"))
    }
    hits <- vapply(exp_nums, function(e) any(abs(pred_nums - e) <= tolerance), logical(1))
    list(score = mean(hits), passed = all(hits), reason = "")
  })
}

#' Evaluator: grade the answer with an LLM-as-judge
#'
#' Sends the question, the reference answer (when present), and the agent's
#' answer to a judge LLM, which must reply PASS or FAIL. A reply that parses
#' as a number between 0 and 1 is also accepted as a fractional score.
#'
#' @param provider A provider configuration used for judging
#' @param criteria Optional natural-language criteria the judge must apply
#' @param system_prompt Optional system prompt for the judge
#' @return An evaluator object usable with [evaluate()]
#' @export
eval_llm_judge <- function(provider, criteria = "", system_prompt = "") {
  new_evaluator("llm_judge", function(prediction, example) {
    ref <- if (nzchar(example$expected)) example$expected else "(none)"
    msg <- paste0(
      "You are judging an AI response.\n",
      if (nzchar(criteria)) paste0("Criteria: ", criteria, "\n") else "",
      "Question: ", example$input, "\n",
      "Reference answer: ", ref, "\n",
      "Response to evaluate: ", prediction, "\n\n",
      "Reply with exactly one word: PASS or FAIL."
    )
    res <- tryCatch(chat(msg, provider = provider, system_prompt = system_prompt),
                    error = function(e) list(.judge_error = conditionMessage(e)))
    if (!is.null(res$.judge_error)) {
      return(list(score = 0, passed = FALSE,
                  reason = paste("judge call failed:", res$.judge_error)))
    }
    content <- toupper(trimws(as.character(res$content)[1]))
    if (is.na(content)) content <- ""
    if (grepl("PASS", content)) {
      list(score = 1, passed = TRUE, reason = content)
    } else if (grepl("FAIL", content)) {
      list(score = 0, passed = FALSE, reason = content)
    } else {
      num <- suppressWarnings(as.numeric(content))
      if (!is.na(num) && num >= 0 && num <= 1) {
        list(score = num, passed = num >= 0.5, reason = content)
      } else {
        list(score = 0, passed = FALSE, reason = paste("unrecognized judge reply:", content))
      }
    }
  })
}

#' Evaluator: embedding similarity against the reference answer
#'
#' Embeds both texts with the provider's embedding endpoint and compares them
#' by cosine similarity. The example passes when similarity >= `threshold`.
#'
#' @param provider A provider configuration with an embeddings endpoint
#' @param threshold Minimum cosine similarity to pass (default 0.8)
#' @return An evaluator object usable with [evaluate()]
#' @export
eval_semantic <- function(provider, threshold = 0.8) {
  threshold <- as.numeric(threshold)[1]
  if (is.na(threshold)) stop("eval_semantic(): `threshold` must be a number.")
  cosine <- function(a, b) sum(a * b) / (sqrt(sum(a * a)) * sqrt(sum(b * b)))
  new_evaluator("semantic", function(prediction, example) {
    if (!nzchar(example$expected)) {
      return(list(score = 0, passed = FALSE, reason = "example has no expected answer"))
    }
    tryCatch({
      v1 <- embed(prediction, provider)
      v2 <- embed(example$expected, provider)
      sim <- cosine(v1, v2)
      list(score = max(0, min(1, sim)), passed = sim >= threshold,
           reason = sprintf("cosine similarity %.4f", sim))
    }, error = function(e) {
      list(score = 0, passed = FALSE, reason = paste("embedding failed:", conditionMessage(e)))
    })
  })
}

#' Evaluator: a custom scoring function
#'
#' @param name Evaluator name (used as the results column name)
#' @param fn Function(prediction, example) returning a single number in
#'   \[0, 1\], a single logical, or a list with `score`, `passed` (optional),
#'   and `reason` (optional). `example` carries `input` and `expected`.
#' @return An evaluator object usable with [evaluate()]
#' @export
eval_custom <- function(name, fn) {
  if (!is.function(fn)) stop("eval_custom(): `fn` must be a function.")
  new_evaluator(name, function(prediction, example) {
    out <- fn(prediction, example)
    if (is.numeric(out) && length(out) == 1L && !is.na(out)) {
      list(score = out, passed = out >= 0.5, reason = "")
    } else if (is.logical(out) && length(out) == 1L && !is.na(out)) {
      list(score = as.numeric(out), passed = out, reason = "")
    } else if (is.list(out) && is.numeric(out$score) && length(out$score) == 1L) {
      list(score = out$score,
           passed = if (is.logical(out$passed) && length(out$passed) == 1L) out$passed else out$score >= 0.5,
           reason = if (is.character(out$reason) && length(out$reason) == 1L) out$reason else "")
    } else {
      stop("eval_custom(): `fn` must return a number, a logical, or a list with `score`.")
    }
  })
}

# Runner ----------------------------------------------------------------------

#' Evaluate a target over a dataset
#'
#' Runs `target` on every dataset example and scores each answer with every
#' evaluator. `target` is either an agent (built with [chat_agent()],
#' [react_agent()], etc.) or a function of the input that returns the answer
#' (a string, or a list with an `answer` element). Extra arguments in `...`
#' are forwarded to [run_agent()] or the function on every call.
#'
#' Errors in the target or in an evaluator are contained per example: the run
#' continues and the failure is recorded.
#'
#' @param target An agent object or a function(input, ...) returning an answer
#' @param dataset An [eval_dataset()], a data.frame with an `input` column
#'   (and optional `expected`), or a character vector of inputs
#' @param evaluators A list of evaluator objects (from [eval_exact_match()],
#'   [eval_llm_judge()], [eval_custom()], ...)
#' @param ... Extra arguments forwarded to the target on every example
#' @return An evaluation result: a list with `results` (per-example data
#'   frame), `summary` (per-evaluator aggregates), `details` (per-example
#'   evaluator reasons), and `passed` (overall)
#' @export
evaluate <- function(target, dataset, evaluators = list(), ...) {
  ds <- .as_eval_dataset(dataset)

  if (is.function(target)) {
    target_fn <- function(input, ...) {
      out <- target(input, ...)
      if (is.list(out) && !is.null(out$answer)) as.character(out$answer)[1] else as.character(out)[1]
    }
  } else if (is_agent(target)) {
    target_fn <- function(input, ...) run_agent(target, input, ...)$answer
  } else {
    stop("evaluate(): `target` must be an agent or a function.")
  }

  if (!all(vapply(evaluators, function(e) inherits(e, "agentgraph_evaluator"), logical(1)))) {
    stop("evaluate(): every element of `evaluators` must be an evaluator from an eval_*() constructor.")
  }
  ev_names <- vapply(evaluators, function(e) e$name, character(1))
  if (anyDuplicated(ev_names)) {
    stop("evaluate(): evaluator names must be unique (got: ",
         paste(ev_names, collapse = ", "), ").")
  }
  reserved <- c("i", "input", "expected", "answer", "error", "elapsed", "passed")
  if (any(ev_names %in% reserved)) {
    stop("evaluate(): evaluator names must not be one of: ", paste(reserved, collapse = ", "), ".")
  }

  n <- length(ds$input)
  answers <- rep(NA_character_, n)
  errors <- rep("", n)
  elapsed <- rep(0, n)
  score_cols <- setNames(rep(list(rep(0, n)), length(ev_names)), ev_names)
  passed_mat <- matrix(TRUE, nrow = n, ncol = length(ev_names),
                       dimnames = list(NULL, if (length(ev_names)) ev_names else NULL))
  details <- vector("list", n)

  for (i in seq_len(n)) {
    example <- list(input = ds$input[[i]], expected = ds$expected[[i]])
    err <- NULL
    t0 <- Sys.time()
    ans <- tryCatch(target_fn(ds$input[[i]], ...),
                    error = function(e) { err <<- conditionMessage(e); NULL })
    elapsed[[i]] <- as.numeric(difftime(Sys.time(), t0, units = "secs"))
    errored <- !is.null(err)

    if (errored) {
      errors[[i]] <- err
      answers[[i]] <- NA_character_
    } else {
      answers[[i]] <- as.character(ans)[1]
      if (is.na(answers[[i]])) {
        errors[[i]] <- "target returned NA"
        errored <- TRUE
      }
    }

    row_details <- list()
    for (j in seq_along(evaluators)) {
      ev <- evaluators[[j]]
      res <- tryCatch(ev$fn(answers[[i]], example),
                      error = function(e) list(score = 0, passed = FALSE,
                                               reason = conditionMessage(e)))
      if (is.null(res) || !is.list(res)) {
        res <- list(score = 0, passed = FALSE, reason = "evaluator returned nothing")
      }
      score <- suppressWarnings(as.numeric(res$score)[1])
      if (is.na(score)) score <- 0
      score <- max(0, min(1, score))
      ok <- is.logical(res$passed) && length(res$passed) == 1L && !is.na(res$passed)
      if (!ok) res$passed <- score >= 0.5
      reason <- if (is.character(res$reason) && length(res$reason) == 1L) res$reason else ""

      if (errored) {
        score <- 0
        res$passed <- FALSE
      }
      score_cols[[ev$name]][[i]] <- score
      passed_mat[i, j] <- isTRUE(res$passed)
      row_details[[ev$name]] <- reason
    }
    details[[i]] <- row_details
  }

  results <- data.frame(
    i = seq_len(n),
    input = ds$input,
    expected = ds$expected,
    answer = answers,
    error = errors,
    elapsed = round(elapsed, 4),
    stringsAsFactors = FALSE
  )
  for (nm in ev_names) results[[nm]] <- score_cols[[nm]]
  if (length(ev_names) > 0L) {
    results$passed <- apply(passed_mat, 1, all)
  } else {
    results$passed <- rep(TRUE, n)
  }

  if (length(ev_names) > 0L) {
    summary <- data.frame(
      evaluator = ev_names,
      mean_score = round(vapply(ev_names, function(nm) mean(score_cols[[nm]]), 0), 4),
      pass_rate = round(colMeans(passed_mat), 4),
      row.names = NULL,
      stringsAsFactors = FALSE
    )
  } else {
    summary <- data.frame(evaluator = character(0), mean_score = numeric(0),
                          pass_rate = numeric(0))
  }

  structure(
    list(results = results, summary = summary, details = details,
         passed = all(results$passed)),
    class = "agentgraph_eval"
  )
}

#' Print an evaluation result
#'
#' @param x An evaluation result from [evaluate()]
#' @param ... Unused
#' @return `x`, invisibly
#' @export
print.agentgraph_eval <- function(x, ...) {
  n <- nrow(x$results)
  cat(sprintf("agentgraph evaluation: %d example%s, %d evaluator%s\n",
              n, if (n == 1L) "" else "s",
              nrow(x$summary), if (nrow(x$summary) == 1L) "" else "s"))
  cat("overall:", if (x$passed) "PASS" else "FAIL", "\n\n")
  if (nrow(x$summary) > 0L) print(x$summary)
  invisible(x)
}
