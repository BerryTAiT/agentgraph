# SQLite schema + initialization.
#
# This is called by the MAIN process (main.R / demo.R) before the graph runs so
# the database file exists in the expected place. The tool handlers open their
# own connections in the isolated tool-server process (see tools.R).

suppressPackageStartupMessages({
  library(DBI)
  library(RSQLite)
})

db_init <- function(db_path) {
  dir.create(dirname(db_path), showWarnings = FALSE, recursive = TRUE)
  con <- DBI::dbConnect(RSQLite::SQLite(), db_path)
  on.exit(DBI::dbDisconnect(con), add = TRUE)
  DBI::dbExecute(con, paste(
    "CREATE TABLE IF NOT EXISTS users (",
    "  username      TEXT PRIMARY KEY,",
    "  email         TEXT UNIQUE NOT NULL,",
    "  password_hash TEXT NOT NULL,",
    "  plan          TEXT NOT NULL DEFAULT 'basic',",
    "  created_at    TEXT NOT NULL",
    ")"
  ))
  invisible(db_path)
}
