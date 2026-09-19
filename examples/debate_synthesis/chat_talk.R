#=====================================================================
# chat_talk.R :: an interactive REPL to TALK to the AI
#
# A real back-and-forth chat: type a question, the AI replies, repeat.
# The conversation remembers prior turns because the message history is
# kept in the graph's `state.messages` and replayed on every call (the
# framework's native memory mechanism).
#
# Exit the session by typing:  quit   or   exit   or   q   (or Ctrl+C)
#
# Usage:
#   Rscript chat_talk.R                        # offline mock
#   Rscript chat_talk.R --deepseek             # live via DEEPSEEK_API_KEY
#   Rscript chat_talk.R --live                 # live via OPENAI_API_KEY
#   Rscript chat_talk.R --topic="... First prompt"
#=====================================================================

library(agentgraph)

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

`%||%` <- function(a, b) if (is.null(a)) b else a

## ---- build a memory-preserving chat graph ----
build_chat_graph <- function(provider, persona = NULL) {
  if (is.null(persona)) {
    persona <- paste(
      "You are a friendly, knowledgeable assistant. You always answer in",
      "plain English. You remember the whole conversation and refer back",
      "to earlier turns when relevant.")
  }
  state_graph(entry = "agent") |>
    add_node("agent", llm_node(provider = provider, system_prompt = persona))
}

## ---- one chat turn ----
# `messages` is the running conversation; returns new assistant reply text.
chat_turn <- function(graph, messages, user_input) {
  messages <- c(messages, list(user_msg(user_input)))
  st <- run(graph, state = list(messages = messages), n_threads = 1L)
  as <- Filter(function(m) m$role == "assistant", st$messages)
  list(
    reply     = if (length(as)) as[[length(as)]]$content else "",
    new_messages = st$messages
  )
}

## ---- interactive session ----
talk <- function(argv = commandArgs(trailingOnly = TRUE)) {
  deepseek <- "--deepseek" %in% argv
  live     <- "--live" %in% argv
  first    <- grep("^--topic=", argv, value = TRUE)
  first    <- if (length(first)) sub("^--topic=", "", first[1]) else NULL

  provider <- if (deepseek) {
    key <- Sys.getenv("DEEPSEEK_API_KEY", "")
    if (!nzchar(key)) {
      stop("--deepseek requires DEEPSEEK_API_KEY env var set before running.")
    }
    provider_openai(api_key = key, model = "deepseek-v4-flash",
                    base_url = "https://api.deepseek.com")
  } else if (live) {
    provider_openai(model = "gpt-4o")
  } else {
    cat("(offline mock mode — use --deepseek or --live for a real model)\n")
    provider_mock(responses = list("*" =
      "I'm the assistant. (mock reply — every answer looks like this offline.)"))
  }

  graph <- build_chat_graph(provider)
  messages <- list()

  intro <- c(
    "== agentgraph interactive chat ==",
    sprintf("provider: %s", provider$model %||% "?") |> trimws(),
    "Type your messages. 'quit'/'exit'/'q' to leave."
  )
  if (!is.null(first)) intro <- c(intro, sprintf("Opening: %s", first))
  cat(paste(intro, collapse = "\n"), "\n")

  # seed with the `--topic=` opening prompt if given
  if (!is.null(first)) {
    out <- chat_turn(graph, messages, first)
    messages <- out$new_messages
    cat("\n", wrap(out$reply), "\n\n", sep = "")
  }

  repeat {
    cat("> ", sep = "")
    inp <- readLines("stdin", n = 1)
    if (length(inp) == 0L) break
    inp <- trimws(inp)
    if (!nzchar(inp)) next
    if (tolower(inp) %in% c("quit", "exit", "q")) {
      cat("bye\n")
      break
    }
    out <- tryCatch(chat_turn(graph, messages, inp),
                    error = function(e) list(reply = paste("error:", conditionMessage(e)),
                                             new_messages = messages))
    messages <- out$new_messages
    cat("\n", wrap(out$reply), "\n\n", sep = "")
  }
  invisible(NULL)
}

## ---- simple word-wrap for console output ----
wrap <- function(text, width = 88) {
  if (!length(text) || is.na(text) || !nzchar(text)) return("(empty reply)")
  text <- gsub("\n+", "\n", text)
  lines <- strsplit(text, "\n")[[1]]
  out <- character(0)
  for (ln in lines) {
    if (nchar(ln) <= width) { out <- c(out, ln); next }
    words <- strsplit(ln, " ", fixed = TRUE)[[1]]
    cur <- ""
    for (w in words) {
      if (nchar(cur) + nchar(w) + 1 > width) { out <- c(out, cur); cur <- w }
      else cur <- if (nzchar(cur)) paste(cur, w) else w
    }
    if (nzchar(cur)) out <- c(out, cur)
  }
  paste(out, collapse = "\n")
}

if (sys.nframe() == 0) {
  if (!interactive()) talk()
}