# RLHF / feedback loop ---------------------------------------------------------
#
# record_feedback() captures a thumbs-up/down (and optional correction) on a run
# result, building a dataset for fine-tuning or prompt optimization. Retrieve it
# with feedback_dataset() or export JSONL with feedback_export().

.agentgraph_feedback <- new.env(parent = emptyenv())
.agentgraph_feedback$records <- list()
.agentgraph_feedback$seq <- 0L

.normalize_rating <- function(rating) {
  if (is.logical(rating) && length(rating) == 1L && !is.na(rating)) {
    return(if (rating) "good" else "bad")
  }
  if (is.numeric(rating) && length(rating) == 1L && !is.na(rating)) {
    return(if (rating > 0) "good" else "bad")
  }
  r <- tolower(as.character(rating)[1L])
  if (r %in% c("good", "up", "thumbs_up", "thumbs-up", "positive", "+", "1")) return("good")
  if (r %in% c("bad", "down", "thumbs_down", "thumbs-down", "negative", "-", "-1", "0")) return("bad")
  stop("record_feedback(): `rating` must be good/bad (or up/down, 1/-1, TRUE/FALSE).")
}

# Extract (input, output) from a run() state or run_agent() result.
.extract_qa <- function(result) {
  msgs <- NULL
  output <- NULL
  if (is.list(result) && !is.null(result$answer)) {
    output <- as.character(result$answer)[1L]
    if (is.list(result$state)) msgs <- result$state$messages
  } else if (is.list(result) && !is.null(result$messages)) {
    msgs <- result$messages
  } else {
    stop("record_feedback(): `result` must be a run() state or run_agent() result.")
  }

  input <- ""
  if (!is.null(msgs)) {
    for (m in rev(msgs)) {
      if (identical(m$role, "user") && is.character(m$content)) { input <- m$content; break }
    }
  }
  if (is.null(output) || !nzchar(output)) {
    output <- ""
    if (!is.null(msgs)) {
      for (m in rev(msgs)) {
        if (identical(m$role, "assistant") && is.character(m$content) && nzchar(m$content)) {
          output <- m$content; break
        }
      }
    }
  }
  list(input = input, output = output)
}

#' Record feedback on a run result
#'
#' Captures a thumbs-up/down (and optional correction) for a run, building a
#' feedback dataset for fine-tuning or prompt optimization. `input`/`output` may
#' be supplied explicitly, or extracted from `result` (a [run()] state or a
#' [run_agent()] result).
#'
#' @param result A run state or run_agent() result (optional if input/output given)
#' @param rating "good"/"bad" (or up/down, 1/-1, TRUE/FALSE)
#' @param correction Optional corrected answer (for "bad" feedback)
#' @param input Optional explicit input text
#' @param output Optional explicit output text
#' @param comment Optional free-text note
#' @return Invisibly the recorded feedback (a list)
#' @export
record_feedback <- function(result = NULL, rating, correction = NULL,
                            input = NULL, output = NULL, comment = NULL) {
  r <- .normalize_rating(rating)
  if (is.null(result)) {
    if (is.null(input) || is.null(output)) {
      stop("record_feedback(): provide `result` or both `input` and `output`.")
    }
    inp <- as.character(input)[1L]
    out <- as.character(output)[1L]
  } else {
    qa <- .extract_qa(result)
    inp <- if (is.null(input)) qa$input else as.character(input)[1L]
    out <- if (is.null(output)) qa$output else as.character(output)[1L]
  }

  .agentgraph_feedback$seq <- .agentgraph_feedback$seq + 1L
  rec <- list(
    seq = .agentgraph_feedback$seq,
    ts_ms = as.numeric(Sys.time()) * 1000,
    input = inp,
    output = out,
    rating = r,
    correction = if (is.null(correction)) "" else as.character(correction)[1L],
    comment = if (is.null(comment)) "" else as.character(comment)[1L]
  )
  .agentgraph_feedback$records[[length(.agentgraph_feedback$records) + 1L]] <- rec
  invisible(rec)
}

#' Return the collected feedback as a data.frame
#'
#' @return A data.frame with columns `seq`, `ts_ms`, `input`, `output`, `rating`,
#'   `correction`, and `comment`
#' @export
feedback_dataset <- function() {
  recs <- .agentgraph_feedback$records
  empty <- data.frame(seq = integer(0), ts_ms = numeric(0), input = character(0),
                      output = character(0), rating = character(0),
                      correction = character(0), comment = character(0))
  if (length(recs) == 0L) return(empty)
  data.frame(
    seq = vapply(recs, function(x) x$seq, integer(1)),
    ts_ms = vapply(recs, function(x) x$ts_ms, numeric(1)),
    input = vapply(recs, function(x) x$input, character(1)),
    output = vapply(recs, function(x) x$output, character(1)),
    rating = vapply(recs, function(x) x$rating, character(1)),
    correction = vapply(recs, function(x) x$correction, character(1)),
    comment = vapply(recs, function(x) x$comment, character(1)),
    stringsAsFactors = FALSE
  )
}

#' Summarize feedback counts
#'
#' @return A data.frame with one row: `good`, `bad`, `total`
#' @export
feedback_stats <- function() {
  ds <- feedback_dataset()
  data.frame(good = sum(ds$rating == "good"), bad = sum(ds$rating == "bad"),
             total = nrow(ds))
}

#' Export the feedback dataset as JSONL
#'
#' Writes one JSON object per feedback record (suitable for a fine-tuning or
#' prompt-optimization pipeline).
#'
#' @param path Destination file path
#' @return Invisibly `path`
#' @export
feedback_export <- function(path) {
  if (!is.character(path) || length(path) != 1L || is.na(path) || !nzchar(path)) {
    stop("feedback_export(): `path` must be a single non-empty string.")
  }
  recs <- .agentgraph_feedback$records
  lines <- if (length(recs) == 0L) character(0)
           else vapply(recs, function(r) jsonlite::toJSON(r, auto_unbox = TRUE), character(1))
  writeLines(lines, path)
  invisible(path)
}

#' Reset the feedback dataset
#'
#' @return `NULL`, invisibly
#' @export
feedback_reset <- function() {
  .agentgraph_feedback$records <- list()
  .agentgraph_feedback$seq <- 0L
  invisible(NULL)
}
