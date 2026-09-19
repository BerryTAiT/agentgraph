#=====================================================================
# chat_console.R :: run this in RStudio / Positron (play button)
#
# Two ways to use it:
#
#  (1) Click the **Source** (play) button  ->  a terminal-style chat
#      loop starts right in the R console. Type and press Enter each
#      turn; type `quit` to stop.
#
#  (2) Call the function yourself from the console:
#        library(agentgraph)                 # if not auto-loaded
#        ask("What is a vector database?")   # first turn
#        ask("How is it different from SQL?")# second turn (REMEMBERS)
#        reset_chat()                         # start a fresh conversation
#
# Why this works and the old one didn't: this uses readline() which
# reads straight from the R console, instead of readLines("stdin")
# which only works when piping text in from a shell.
#
# Live model? Set an env var in R before running (never paste a key
# into the file):
#     Sys.setenv(DEEPSEEK_API_KEY = "sk-...")
#     or  Sys.setenv(OPENAI_API_KEY = "sk-...")
#=====================================================================

if (!"agentgraph" %in% loadedNamespaces()) {
  suppressPackageStartupMessages(library(agentgraph))
}

## ---- load local .env (project keys, git-ignored) ----
# Robust script-location detection: works when Rscript runs this file AND when
# it is source()d from an IDE. Falls back to getwd().
script_dir <- tryCatch({
  ofile <- tryCatch(sys.frame(1)$ofile, error = function(e) NULL)
  if (!is.null(ofile) && nzchar(ofile)) {
    dirname(normalizePath(ofile))
  } else {
    src <- commandArgs(FALSE)
    i <- which(startsWith(src, "--file="))
    if (length(i)) dirname(normalizePath(sub("^--file=", "", src[i[1]])))
    else getwd()
  }
}, error = function(e) getwd())
if (!exists("load_env", inherits = TRUE)) {
  source(file.path(script_dir, "dotenv.R"), local = FALSE)
}
load_env(path = script_dir)

## ---- configuration ----
CONFIG <- list(
  deepseek = Sys.getenv("DEEPSEEK_API_KEY", "") != "",
  openai   = !nzchar(Sys.getenv("DEEPSEEK_API_KEY", "")) &&
             Sys.getenv("OPENAI_API_KEY", "") != "",
  model_deepseek = Sys.getenv("DEEPSEEK_MODEL", "deepseek-v4-flash"),
  model_openai   = Sys.getenv("OPENAI_MODEL", "gpt-4o")
)

## ---- provider: pick live model if a key is set, else offline mock ----
make_provider <- function() {
  if (CONFIG$deepseek) {
    provider_openai(api_key = Sys.getenv("DEEPSEEK_API_KEY"),
                    model = CONFIG$model_deepseek,
                    base_url = "https://api.deepseek.com")
  } else if (CONFIG$openai) {
    provider_openai(model = CONFIG$model_openai)
  } else {
    provider_mock(responses = list("*" =
      "[offline mock] Set DEEPSEEK_API_KEY or OPENAI_API_KEY in R with",
      "Sys.setenv(...) to talk to a real model."))
  }
}

## ---- graph + conversation state (kept as a package/environment) ----
.env <- new.env(parent = emptyenv())
.env$graph    <- NULL
.env$messages <- NULL

start_chat <- function(persona = NULL) {
  if (is.null(persona)) {
    persona <- paste("You are a friendly, knowledgeable assistant. You answer",
                     "in plain English. You remember the whole conversation",
                     "and refer back to earlier turns when relevant.")
  }
  p <- make_provider()
  .env$graph <- state_graph(entry = "agent") |>
    add_node("agent", llm_node(provider = p, system_prompt = persona))
  .env$messages <- list()
  cat("Chat started (", p$model, "). Call ask(\"...\") to talk.\n", sep = "")
  invisible(NULL)
}

reset_chat <- function() {
  .env$graph    <- NULL
  .env$messages <- NULL
  cat("Chat reset.\n")
  invisible(NULL)
}

## ---- one turn: send a message, print the reply, keep memory ----
ask <- function(input) {
  if (is.null(.env$graph)) start_chat()
  .env$messages <- c(.env$messages, list(user_msg(input)))
  st <- run(.env$graph, state = list(messages = .env$messages), n_threads = 1L)
  as <- Filter(function(m) m$role == "assistant", st$messages)
  reply <- if (length(as)) as[[length(as)]]$content else "(empty reply)"
  .env$messages <- st$messages
  cat("\n")
  cat(wrap(reply))
  cat("\n")
  invisible(reply)
}

## ---- console loop for the Source / play button ----
run_console <- function() {
  start_chat()
  cat("\nType your message (Enter to send); 'quit' to exit.\n\n")
  repeat {
    inp <- readline(prompt = "> ")
    if (!nzchar(inp)) next
    if (tolower(trimws(inp)) %in% c("quit", "exit", "q")) {
      cat("bye\n"); break
    }
    ask(trimws(inp))
    cat("\n")
  }
}

## ---- word wrap for console ----
wrap <- function(text, width = 88) {
  if (!length(text) || is.na(text) || !nzchar(text)) return("(empty reply)")
  text <- gsub("\n+", "\n", text)
  lines <- strsplit(text, "\n")[[1]]
  out  <- character(0)
  for (ln in lines) {
    if (is.na(ln) || nchar(ln) <= width) { out <- c(out, ln); next }
    words <- strsplit(ln, " ", fixed = TRUE)[[1]]
    cur <- ""
    for (w in words) {
      if (nzchar(cur) && nchar(cur) + nchar(w) + 1 > width) {
        out <- c(out, cur); cur <- w
      } else cur <- if (nzchar(cur)) paste(cur, w) else w
    }
    if (nzchar(cur)) out <- c(out, cur)
  }
  paste(out, collapse = "\n")
}

## ---- when Source'd non-interactively from an IDE, start the loop ----
if (sys.nframe() == 0 && !interactive()) {
  # Pure script_context with no console: just initialize and show how to use it.
  start_chat()
  cat("Using Agentgraph console chat.\n")
}

if (sys.nframe() == 0 && interactive()) {
  run_console()
}