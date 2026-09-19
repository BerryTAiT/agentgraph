#=====================================================================
# dotenv.R :: tiny dependency-free .env loader for this project
#
# Lets each user keep their own keys in a local `.env` file (next to
# this script) instead of editing source. `.env` follows the usual
# dotenv rules:
#     KEY=value
#     KEY="quoted value"     # quotes are stripped
#     KEY='single too'
#     # comment            # blank lines and # comments ignored
#
# Existing values in the session are NOT overwritten unless
# load_env(overwrite = TRUE) is used. Values are exported to the
# R environment so Sys.getenv("KEY") works afterwards.
#
# Example `.env`:
#     DEEPSEEK_API_KEY=sk-...
#     DEEPSEEK_MODEL=deepseek-v4-flash
#     OPENAI_API_KEY=
#=====================================================================

#' Load key=value pairs from a `.env` file into the R session env.
#'
#' @param file   path to the dotenv file (default: `.env` in the current
#'               working directory).
#' @param path   optional directory to look in; if given, `file` is treated
#'               as a filename inside `path`.
#' @param overwrite  logical: overwrite keys that are already set in the
#'               session (default FALSE keeps an in-session value).
#' @return invisibly, the character vector of keys that were set.
load_env <- function(file = ".env",
                     path = NULL,
                     overwrite = FALSE) {
  if (!is.null(path)) file <- file.path(path, file)
  if (!file.exists(file)) {
    return(invisible(character(0)))
  }
  lines <- readLines(file, warn = FALSE, encoding = "UTF-8")
  setkeys <- character(0)
  for (raw in lines) {
    # strip comments (a # that starts a token, respecting quotes roughly)
    line <- sub("^(.*?)(\\s*#.*)?$", "\\1", raw)
    line <- trimws(line)
    if (!nzchar(line)) next
    eq <- regexpr("=", line, fixed = TRUE)
    if (eq < 1L) next
    key   <- trimws(substr(line, 1L, eq - 1L))
    value <- trimws(substr(line, eq + 1L, nchar(line)))
    # quote stripping
    if (nchar(value) >= 2L) {
      first <- substr(value, 1L, 1L); last <- substr(value, nchar(value), nchar(value))
      if ((first == '"' && last == '"') || (first == "'" && last == "'")) {
        value <- substr(value, 2L, nchar(value) - 1L)
      }
    }
    if (!nzchar(key)) next
    if (!overwrite && Sys.getenv(key) != "") next
    do.call(Sys.setenv, stats::setNames(list(value), key))
    setkeys <- c(setkeys, key)
  }
  invisible(setkeys)
}