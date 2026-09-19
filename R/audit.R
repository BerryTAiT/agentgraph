# Compliance & audit ----------------------------------------------------------
#
# A tamper-evident, hash-chained JSONL audit log: each entry stores the hash of
# the previous entry, so any modification/insertion/deletion breaks the chain
# and is caught by audit_verify(). pii_report() summarizes what pii_scrub()
# would redact, so a "what was redacted and why" trail can be recorded.

# Deterministic non-cryptographic hash (djb2-style, 32-bit). Good for integrity
# checking (tamper-evidence), NOT for cryptographic security.
.audit_hash <- function(x) {
  codes <- utf8ToInt(x)
  h <- 5381
  for (c in codes) {
    h <- ((h * 33) + c) %% 4294967296
  }
  sprintf("%.0f", h)
}

#' Open a hash-chained audit log
#'
#' Creates (or opens) a JSONL audit log file whose entries are chained with
#' hashes, so tampering is detectable with [audit_verify()]. The returned handle
#' tracks the chain's last hash and sequence number.
#'
#' @param path Path to the audit log file
#' @return An audit-log handle (class `agentgraph_audit`)
#' @export
audit_log <- function(path) {
  if (!is.character(path) || length(path) != 1L || is.na(path) || !nzchar(path)) {
    stop("audit_log(): `path` must be a single non-empty string.")
  }
  state <- new.env(parent = emptyenv())
  state$seq <- 0L
  state$last_hash <- "genesis"
  structure(list(path = path, state = state), class = "agentgraph_audit")
}

#' Append an entry to an audit log
#'
#' Appends one entry, chaining its hash to the previous entry. `pii` is an
#' optional list describing any redactions (e.g. from [pii_report()]).
#'
#' @param log An audit-log handle from [audit_log()]
#' @param event A short event name
#' @param data Optional named list of event data
#' @param pii Optional named list describing redactions
#' @return Invisibly the entry's hash
#' @export
audit_record <- function(log, event, data = list(), pii = list()) {
  if (!inherits(log, "agentgraph_audit")) {
    stop("audit_record(): `log` must be an audit_log().")
  }
  if (!is.character(event) || length(event) != 1L || is.na(event)) {
    stop("audit_record(): `event` must be a single non-NA string.")
  }
  log$state$seq <- log$state$seq + 1L
  prev <- log$state$last_hash
  content <- list(seq = log$state$seq,
                  ts_ms = as.numeric(Sys.time()) * 1000,
                  event = event, data = data, pii = pii)
  h <- .audit_hash(paste0(prev, "|", jsonlite::toJSON(content, auto_unbox = TRUE)))

  entry <- content
  entry$prev <- prev
  entry$hash <- h
  write(jsonlite::toJSON(entry, auto_unbox = TRUE), log$path, append = TRUE)

  log$state$last_hash <- h
  invisible(h)
}

#' Verify an audit log's integrity
#'
#' Recomputes every entry's hash and checks the chain linkage. Returns FALSE if
#' any entry was modified, inserted, deleted, or reordered.
#'
#' @param log An audit-log handle from [audit_log()]
#' @return `TRUE` if the chain is intact, `FALSE` if tampering is detected
#' @export
audit_verify <- function(log) {
  if (!inherits(log, "agentgraph_audit")) {
    stop("audit_verify(): `log` must be an audit_log().")
  }
  if (!file.exists(log$path)) return(TRUE)
  lines <- readLines(log$path, warn = FALSE)
  lines <- lines[nzchar(lines)]
  if (length(lines) == 0L) return(TRUE)
  prev <- "genesis"
  for (ln in lines) {
    e <- jsonlite::fromJSON(ln, simplifyVector = FALSE)
    content <- list(seq = e$seq, ts_ms = e$ts_ms, event = e$event,
                    data = e$data, pii = e$pii)
    body <- paste0(prev, "|", jsonlite::toJSON(content, auto_unbox = TRUE))
    if (!identical(.audit_hash(body), e$hash)) return(FALSE)
    if (!identical(e$prev, prev)) return(FALSE)
    prev <- e$hash
  }
  TRUE
}

#' Read the entries of an audit log
#'
#' @param log An audit-log handle from [audit_log()]
#' @return A data.frame with columns `seq`, `ts_ms`, `event`, and `hash`
#' @export
audit_read <- function(log) {
  if (!inherits(log, "agentgraph_audit")) {
    stop("audit_read(): `log` must be an audit_log().")
  }
  empty <- data.frame(seq = integer(0), ts_ms = numeric(0),
                      event = character(0), hash = character(0))
  if (!file.exists(log$path)) return(empty)
  lines <- readLines(log$path, warn = FALSE)
  lines <- lines[nzchar(lines)]
  if (length(lines) == 0L) return(empty)
  out <- lapply(lines, function(l) jsonlite::fromJSON(l, simplifyVector = FALSE))
  data.frame(
    seq = vapply(out, function(x) x$seq, integer(1)),
    ts_ms = vapply(out, function(x) x$ts_ms, numeric(1)),
    event = vapply(out, function(x) x$event, character(1)),
    hash = vapply(out, function(x) x$hash, character(1)),
    stringsAsFactors = FALSE
  )
}

#' Summarize the PII that [pii_scrub()] would redact
#'
#' Counts, per entity type, the occurrences in `text` that [pii_scrub()] would
#' replace. Use the result (or a subset) as the `pii` argument to
#' [audit_record()] to build a "what was redacted" audit trail.
#'
#' @param text A character vector of strings to scan
#' @param entities Entity types to count (any subset of the six PII types)
#' @return A data.frame with columns `entity` and `count`
#' @export
pii_report <- function(text,
                       entities = c("email", "api_key", "ssn",
                                    "credit_card", "phone", "ipv4")) {
  if (!is.character(text)) stop("pii_report(): `text` must be a character vector.")
  entities <- match.arg(entities, .pii_canonical, several.ok = TRUE)
  counts <- vapply(.pii_canonical, function(e) {
    if (!(e %in% entities)) return(0L)
    sum(vapply(text, function(t) {
      m <- gregexpr(.pii_patterns[[e]], t, perl = TRUE)[[1L]]
      if (m[1L] == -1L) 0L else length(m)
    }, integer(1L)))
  }, integer(1L))
  data.frame(entity = .pii_canonical, count = unname(counts), stringsAsFactors = FALSE)
}

#' Print an audit-log handle
#'
#' @param x An audit-log handle from [audit_log()]
#' @param ... Unused
#' @return `x`, invisibly
#' @export
print.agentgraph_audit <- function(x, ...) {
  n <- tryCatch(nrow(audit_read(x)), error = function(e) 0L)
  cat(sprintf("agentgraph audit log: %s (%d entr%s)\n",
              x$path, n, if (n == 1L) "y" else "ies"))
  invisible(x)
}
