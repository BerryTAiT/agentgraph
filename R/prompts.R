# Prompt management ------------------------------------------------------------
#
# Prompt templates with {variable} placeholders, file persistence, and a
# lightweight directory-backed registry. Templates render to plain strings,
# so they plug directly into llm_node(system_prompt=), chat(), and the
# *_agent() constructors. Pure R — no C++ changes.

# Internal: extract {name} placeholders in first-appearance order. Only
# identifier-like names (letters, digits, underscore, dot; not starting with
# a digit) are placeholders; anything else stays literal.
.prompt_var_names <- function(text) {
  m <- regmatches(text, gregexpr("\\{[A-Za-z_.][A-Za-z0-9_.]*\\}", text))[[1]]
  if (length(m) == 0L) return(character(0))
  unique(substr(m, 2L, nchar(m) - 1L))
}

.as_prompt_text <- function(prompt) {
  if (inherits(prompt, "agentgraph_prompt")) return(prompt$text)
  if (is.character(prompt) && length(prompt) == 1L && !is.na(prompt)) return(prompt)
  stop("`prompt` must be a prompt_template() or a single character string.")
}

#' Create a prompt template
#'
#' The template text may contain \code{\{name\}} placeholders that are filled
#' in by [render_prompt()]. Only identifier-like names (letters, digits,
#' underscore, dot; not starting with a digit) are treated as placeholders —
#' every other brace stays literal.
#'
#' @param text Template text (a single non-empty string)
#' @param name Optional name; required to add the prompt to a registry
#' @param version Optional version tag
#' @param role Message role used by [prompt_message()]: "system", "user",
#'   or "assistant"
#' @return A prompt template object
#' @export
prompt_template <- function(text, name = "", version = "", role = "system") {
  if (!is.character(text) || length(text) != 1L || is.na(text) || !nzchar(text)) {
    stop("prompt_template(): `text` must be a single non-empty string.")
  }
  if (!is.character(name) || length(name) != 1L || is.na(name)) {
    stop("prompt_template(): `name` must be a single string.")
  }
  if (!is.character(version) || length(version) != 1L || is.na(version)) {
    stop("prompt_template(): `version` must be a single string.")
  }
  if (!is.character(role) || length(role) != 1L || is.na(role) ||
      !role %in% c("system", "user", "assistant")) {
    stop('prompt_template(): `role` must be one of "system", "user", "assistant".')
  }
  structure(
    list(text = text, name = name, version = version, role = role),
    class = "agentgraph_prompt"
  )
}

#' List the placeholder variables in a prompt template
#'
#' @param prompt A prompt template (or a single string)
#' @return A character vector of unique variable names, in first-appearance order
#' @export
prompt_variables <- function(prompt) {
  .prompt_var_names(.as_prompt_text(prompt))
}

#' Render a prompt template
#'
#' Fills every \code{\{name\}} placeholder with the given variable values.
#' Substituted values are inserted verbatim (they may contain braces, dollar
#' signs, or backslashes). Placeholders with no matching value are an error;
#' extra variables are ignored.
#'
#' @param prompt A [prompt_template()] or a single character string
#' @param ... Named variables (take precedence over `vars`)
#' @param vars Named list of variables
#' @return The rendered string
#' @export
render_prompt <- function(prompt, ..., vars = list()) {
  text <- .as_prompt_text(prompt)

  extra <- list(...)
  if (length(extra) > 0L && (is.null(names(extra)) ||
                             any(is.na(names(extra))) || any(!nzchar(names(extra))))) {
    stop("render_prompt(): variables passed through ... must be named.")
  }
  if (length(vars) > 0L && (!is.list(vars) || is.null(names(vars)) ||
                            any(is.na(names(vars))) || any(!nzchar(names(vars))))) {
    stop("render_prompt(): `vars` must be a fully named list.")
  }
  values <- if (length(vars) == 0L) extra else utils::modifyList(vars, extra)

  placeholders <- .prompt_var_names(text)
  missing <- setdiff(placeholders, names(values))
  if (length(missing) > 0L) {
    stop("render_prompt(): missing value(s) for: ", paste(missing, collapse = ", "), ".")
  }
  if (length(placeholders) == 0L) return(text)

  m <- gregexpr("\\{[A-Za-z_.][A-Za-z0-9_.]*\\}", text)
  found <- regmatches(text, m)[[1]]
  subs <- vapply(substr(found, 2L, nchar(found) - 1L), function(nm) {
    v <- as.character(values[[nm]])
    if (length(v) != 1L || is.na(v)) {
      stop("render_prompt(): variable `", nm, "` must be a single non-NA value.")
    }
    v
  }, character(1))
  regmatches(text, m) <- list(subs)
  text
}

#' Render a prompt template into a message object
#'
#' Renders the template (same rules as [render_prompt()]) and wraps the result
#' in a message list using the template's `role` (default "system"; raw
#' strings render as "user"), so it can be passed directly as a message.
#'
#' @param prompt A [prompt_template()] or a single character string
#' @param ... Named variables
#' @param vars Named list of variables
#' @return A message list: `list(role, content)`
#' @export
prompt_message <- function(prompt, ..., vars = list()) {
  role <- if (inherits(prompt, "agentgraph_prompt")) prompt$role else "user"
  list(role = role, content = render_prompt(prompt, ..., vars = vars))
}

#' Load a prompt template from a text file
#'
#' Lines are joined with `"\n"`. The prompt's name defaults to the file name
#' without its extension.
#'
#' @param path Path to a text file
#' @param name Optional prompt name (defaults to the file name sans extension)
#' @param version Optional version tag
#' @param role Message role for [prompt_message()]
#' @return A prompt template object
#' @export
prompt_file <- function(path, name = NULL, version = "", role = "system") {
  if (!is.character(path) || length(path) != 1L || is.na(path) || !nzchar(path)) {
    stop("prompt_file(): `path` must be a single non-empty string.")
  }
  if (!file.exists(path)) {
    stop("prompt_file(): no such file: ", path)
  }
  text <- paste(readLines(path, warn = FALSE), collapse = "\n")
  if (is.null(name)) name <- sub("\\.[^.]*$", "", basename(path))
  prompt_template(text, name = name, version = version, role = role)
}

#' Write a prompt template to a text file
#'
#' Writes the template text only (name/version/role are not persisted); the
#' file can be reloaded with [prompt_file()]. Parent directories are created
#' as needed.
#'
#' @param prompt A [prompt_template()]
#' @param path Destination file path
#' @return `path`, invisibly
#' @export
save_prompt <- function(prompt, path) {
  if (!inherits(prompt, "agentgraph_prompt")) {
    stop("save_prompt(): `prompt` must be a prompt_template().")
  }
  if (!is.character(path) || length(path) != 1L || is.na(path) || !nzchar(path)) {
    stop("save_prompt(): `path` must be a single non-empty string.")
  }
  d <- dirname(path)
  if (!dir.exists(d)) dir.create(d, recursive = TRUE, showWarnings = FALSE)
  writeLines(prompt$text, path)
  invisible(path)
}

#' Create a prompt registry
#'
#' A registry is a named list of prompt templates (accessed with `$name`).
#' When `path` is given, every `.txt` / `.md` file in that directory is loaded
#' as a prompt named after the file (sans extension).
#'
#' @param path Optional directory of `.txt` / `.md` prompt files
#' @return A prompt registry (a named list of templates, class
#'   `agentgraph_prompt_registry`)
#' @export
prompt_registry <- function(path = NULL) {
  reg <- structure(list(), class = "agentgraph_prompt_registry")
  if (!is.null(path)) {
    if (!is.character(path) || length(path) != 1L || is.na(path) || !nzchar(path)) {
      stop("prompt_registry(): `path` must be a single non-empty string.")
    }
    if (!dir.exists(path)) {
      stop("prompt_registry(): no such directory: ", path)
    }
    files <- list.files(path, pattern = "\\.(txt|md)$",
                        full.names = TRUE, ignore.case = TRUE)
    for (f in files) {
      p <- prompt_file(f)
      reg[[p$name]] <- p
    }
    attr(reg, "dir") <- path
  }
  reg
}

#' Add a prompt to a registry
#'
#' Functional style (like [add_node()]): returns a new registry with the
#' prompt added; the input registry is unchanged. The prompt must have a
#' `name`.
#'
#' @param registry A [prompt_registry()]
#' @param prompt A [prompt_template()] with a non-empty `name`
#' @return The updated registry
#' @export
add_prompt <- function(registry, prompt) {
  if (!inherits(registry, "agentgraph_prompt_registry")) {
    stop("add_prompt(): `registry` must be a prompt_registry().")
  }
  if (!inherits(prompt, "agentgraph_prompt")) {
    stop("add_prompt(): `prompt` must be a prompt_template().")
  }
  if (!nzchar(prompt$name)) {
    stop("add_prompt(): the prompt must have a `name`.")
  }
  registry[[prompt$name]] <- prompt
  registry
}

#' Save every prompt in a registry to a directory
#'
#' Writes each prompt to `<path>/<name>.txt`. Defaults to the directory the
#' registry was loaded from (or created with), so a loaded registry can be
#' written back where it came from.
#'
#' @param registry A [prompt_registry()]
#' @param path Destination directory (defaults to the registry's directory)
#' @return `path`, invisibly
#' @export
save_registry <- function(registry, path = NULL) {
  if (!inherits(registry, "agentgraph_prompt_registry")) {
    stop("save_registry(): `registry` must be a prompt_registry().")
  }
  if (is.null(path)) path <- attr(registry, "dir")
  if (is.null(path) || !is.character(path) || length(path) != 1L ||
      is.na(path) || !nzchar(path)) {
    stop("save_registry(): no path (pass one or create the registry with a directory).")
  }
  if (!dir.exists(path)) dir.create(path, recursive = TRUE, showWarnings = FALSE)
  for (nm in names(registry)) {
    save_prompt(registry[[nm]], file.path(path, paste0(nm, ".txt")))
  }
  invisible(path)
}

#' Print a prompt template
#'
#' @param x A prompt template
#' @param ... Unused
#' @return `x`, invisibly
#' @export
print.agentgraph_prompt <- function(x, ...) {
  cat(sprintf("<agentgraph_prompt%s%s>\n",
              if (nzchar(x$name)) paste0(" '", x$name, "'") else "",
              if (nzchar(x$version)) paste0(" v", x$version) else ""))
  vars <- .prompt_var_names(x$text)
  if (length(vars) > 0L) {
    cat("variables:", paste(vars, collapse = ", "), "\n")
  } else {
    cat("variables: (none)\n")
  }
  first <- strsplit(x$text, "\n", fixed = TRUE)[[1]][1]
  preview <- if (nchar(first) > 60L) paste0(substr(first, 1L, 57L), "...") else first
  cat("text:", preview, "\n")
  invisible(x)
}

#' Print a prompt registry
#'
#' @param x A prompt registry
#' @param ... Unused
#' @return `x`, invisibly
#' @export
print.agentgraph_prompt_registry <- function(x, ...) {
  n <- length(x)
  cat(sprintf("agentgraph prompt registry: %d prompt%s\n",
              n, if (n == 1L) "" else "s"))
  d <- attr(x, "dir")
  if (!is.null(d)) cat("directory:", d, "\n")
  for (nm in names(x)) {
    vars <- .prompt_var_names(x[[nm]]$text)
    cat(sprintf("  %s: %d variable%s\n",
                nm, length(vars), if (length(vars) == 1L) "" else "s"))
  }
  invisible(x)
}
