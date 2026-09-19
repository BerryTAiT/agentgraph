# Pre-built tools ---------------------------------------------------------
#
# Ready-made tool constructors. Each returns a `tool()` object whose handler
# runs in agentgraph's isolated tool-server process (R/tool_server.R). The
# handlers are written to be fully self-contained: they reference only base R
# and installed packages (via pkg::fun) and never internal agentgraph helpers,
# so they serialize cleanly through saveRDS()/readRDS() into the tool server.

# Shared HTTP fetch logic, inlined per-constructor so no handler captures a
# reference into the agentgraph namespace. Uses only curl + base R.

#' Web search tool (DuckDuckGo Instant Answer)
#'
#' Returns a ready-to-use tool that searches the web via the DuckDuckGo
#' Instant Answer API. No API key is required.
#'
#' @return A tool definition list (see [tool()]).
#' @export
tool_web_search <- function() {
  fetch <- function(url) {
    if (!requireNamespace("curl", quietly = TRUE)) {
      stop("The 'curl' package is required for this tool. Install it with install.packages(\"curl\").")
    }
    r <- curl::curl_fetch_memory(url, handle = curl::new_handle(useragent = "agentgraph"))
    if (r$status_code >= 400L) stop("HTTP ", r$status_code, " from ", url)
    rawToChar(r$content)
  }
  tool(
    name = "web_search",
    description = paste(
      "Search the web using the DuckDuckGo Instant Answer API (no key required).",
      "Returns an abstract summary plus a list of related topics."
    ),
    parameters = list(query = param_string("Search query")),
    handler = function(args_json) {
      args <- jsonlite::fromJSON(args_json)
      if (is.null(args$query) || !nzchar(args$query)) stop("Missing 'query'")
      q <- utils::URLencode(args$query, reserved = TRUE)
      url <- paste0("https://api.duckduckgo.com/?q=", q,
                    "&format=json&no_html=1&skip_disambig=1")
      res <- jsonlite::fromJSON(fetch(url), simplifyVector = FALSE)
      related <- list()
      if (!is.null(res$RelatedTopics)) {
        related <- lapply(res$RelatedTopics, function(x) {
          if (!is.null(x$Topics)) {
            list(text = x$Name, url = x$FirstURL)
          } else {
            list(text = x$Text, url = x$FirstURL)
          }
        })
      }
      jsonlite::toJSON(
        list(
          heading  = if (is.null(res$Heading)) "" else res$Heading,
          abstract = if (is.null(res$AbstractText)) "" else res$AbstractText,
          url      = if (is.null(res$AbstractURL)) "" else res$AbstractURL,
          related  = related
        ),
        auto_unbox = TRUE
      )
    }
  )
}

#' Wikipedia search tool
#'
#' Returns a ready-to-use tool that searches Wikipedia and returns up to three
#' article titles with short plain-text extracts. No API key is required.
#'
#' @return A tool definition list (see [tool()]).
#' @export
tool_wikipedia <- function() {
  fetch <- function(url) {
    if (!requireNamespace("curl", quietly = TRUE)) {
      stop("The 'curl' package is required for this tool. Install it with install.packages(\"curl\").")
    }
    r <- curl::curl_fetch_memory(url, handle = curl::new_handle(useragent = "agentgraph"))
    if (r$status_code >= 400L) stop("HTTP ", r$status_code, " from ", url)
    rawToChar(r$content)
  }
  tool(
    name = "wikipedia_search",
    description = paste(
      "Search Wikipedia and return up to three article titles with short",
      "plain-text extracts. No API key is required."
    ),
    parameters = list(query = param_string("Search query")),
    handler = function(args_json) {
      args <- jsonlite::fromJSON(args_json)
      if (is.null(args$query) || !nzchar(args$query)) stop("Missing 'query'")
      q <- utils::URLencode(args$query, reserved = TRUE)
      url <- paste0(
        "https://en.wikipedia.org/w/api.php?action=query&generator=search",
        "&gsrsearch=", q, "&gsrlimit=3&prop=extracts&exintro=1",
        "&explaintext=1&format=json"
      )
      res <- jsonlite::fromJSON(fetch(url), simplifyVector = FALSE)
      pages <- res$query$pages
      results <- lapply(pages, function(p) list(
        title   = p$title,
        extract = if (is.null(p$extract)) "" else p$extract,
        url     = paste0("https://en.wikipedia.org/?curid=", p$pageid)
      ))
      jsonlite::toJSON(list(results = results), auto_unbox = TRUE)
    }
  )
}

#' arXiv search tool
#'
#' Returns a ready-to-use tool that searches arXiv and returns paper titles,
#' abstracts, and links. No API key is required.
#'
#' @return A tool definition list (see [tool()]).
#' @export
tool_arxiv <- function() {
  fetch <- function(url) {
    if (!requireNamespace("curl", quietly = TRUE)) {
      stop("The 'curl' package is required for this tool. Install it with install.packages(\"curl\").")
    }
    r <- curl::curl_fetch_memory(url, handle = curl::new_handle(useragent = "agentgraph"))
    if (r$status_code >= 400L) stop("HTTP ", r$status_code, " from ", url)
    rawToChar(r$content)
  }
  tool(
    name = "arxiv_search",
    description = paste(
      "Search arXiv for papers and return titles, abstracts, and links.",
      "No API key is required."
    ),
    parameters = list(
      query = param_string("Search query"),
      max_results = param_integer("Maximum number of results", required = FALSE)
    ),
    handler = function(args_json) {
      args <- jsonlite::fromJSON(args_json)
      if (is.null(args$query) || !nzchar(args$query)) stop("Missing 'query'")
      q <- utils::URLencode(args$query, reserved = TRUE)
      n <- if (is.null(args$max_results)) 5L else as.integer(args$max_results)
      url <- paste0("https://export.arxiv.org/api/query?search_query=all:",
                    q, "&start=0&max_results=", n)
      xml <- fetch(url)
      entries <- strsplit(xml, "<entry>", fixed = TRUE)[[1]][-1]
      extract_tag <- function(text, tag) {
        m <- regmatches(
          text,
          regexpr(paste0("<", tag, "[^>]*>(.*?)</", tag, ">"), text, perl = TRUE)
        )
        if (length(m) == 0L) return("")
        val <- sub(paste0("^<", tag, "[^>]*>"), "", m[[1L]])
        sub(paste0("</", tag, ">$"), "", val)
      }
      results <- lapply(entries, function(e) list(
        title   = extract_tag(e, "title"),
        summary = extract_tag(e, "summary"),
        id      = extract_tag(e, "id")
      ))
      jsonlite::toJSON(list(results = results), auto_unbox = TRUE)
    }
  )
}

#' Generic HTTP request tool
#'
#' Returns a ready-to-use tool that makes an HTTP request (GET, POST, PUT, or
#' DELETE) to any URL and returns the response body. Use it for REST APIs that
#' do not have a dedicated pre-built tool.
#'
#' @return A tool definition list (see [tool()]).
#' @export
tool_http_request <- function() {
  tool(
    name = "http_request",
    description = paste(
      "Make an HTTP request (GET, POST, PUT, or DELETE) to any URL and return",
      "the response body. Use for REST APIs that lack a dedicated pre-built tool."
    ),
    parameters = list(
      url     = param_string("Target URL"),
      method  = param_enum("HTTP method", c("GET", "POST", "PUT", "DELETE"), required = FALSE),
      body    = param_string("Request body string (for POST/PUT)", required = FALSE),
      headers = param_string("JSON object of extra headers", required = FALSE)
    ),
    handler = function(args_json) {
      if (!requireNamespace("curl", quietly = TRUE)) {
        stop("The 'curl' package is required for this tool. Install it with install.packages(\"curl\").")
      }
      args <- jsonlite::fromJSON(args_json)
      if (is.null(args$url) || !nzchar(args$url)) stop("Missing 'url'")
      method <- if (is.null(args$method)) "GET" else args$method
      body   <- if (is.null(args$body) || !nzchar(args$body)) NULL else args$body
      header_lines <- character(0)
      if (!is.null(args$headers) && nzchar(args$headers)) {
        hdrs <- jsonlite::fromJSON(args$headers, simplifyVector = FALSE)
        header_lines <- vapply(names(hdrs), function(nm) {
          paste0(nm, ": ", hdrs[[nm]])
        }, character(1))
      }
      h <- curl::new_handle(useragent = "agentgraph", customrequest = method)
      if (length(header_lines) > 0L) curl::handle_setopt(h, httpheader = header_lines)
      if (!is.null(body)) curl::handle_setopt(h, postfields = body)
      r <- curl::curl_fetch_memory(args$url, handle = h)
      if (r$status_code >= 400L) stop("HTTP ", r$status_code, " from ", args$url)
      jsonlite::toJSON(list(body = rawToChar(r$content)), auto_unbox = TRUE)
    }
  )
}

#' Code execution tool
#'
#' Returns a ready-to-use tool that evaluates an R expression in an isolated R
#' process and returns the captured output (or any error).
#'
#' @return A tool definition list (see [tool()]).
#' @export
tool_code_exec <- function() {
  tool(
    name = "code_exec",
    description = paste(
      "Evaluate an R expression and return captured output or any error.",
      "Runs in an isolated R process."
    ),
    parameters = list(code = param_string("R code to evaluate")),
    handler = function(args_json) {
      args <- jsonlite::fromJSON(args_json)
      if (is.null(args$code) || !nzchar(args$code)) stop("Missing 'code'")
      res <- tryCatch({
        out <- utils::capture.output(
          val <- withVisible(eval(parse(text = args$code), envir = .GlobalEnv))
        )
        if (isTRUE(val$visible) && !is.null(val$value)) {
          out <- c(out, utils::capture.output(print(val$value)))
        }
        list(ok = TRUE, output = paste(out, collapse = "\n"))
      }, error = function(e) list(ok = FALSE, error = conditionMessage(e)))
      jsonlite::toJSON(res, auto_unbox = TRUE)
    }
  )
}

#' CSV reader tool
#'
#' Returns a ready-to-use tool that reads a CSV file and returns column names
#' plus a preview of the rows as JSON.
#'
#' @param max_rows Maximum number of preview rows to return.
#' @return A tool definition list (see [tool()]).
#' @export
tool_read_csv <- function(max_rows = 50L) {
  tool(
    name = "read_csv",
    description = paste(
      "Read a CSV file and return column names plus a preview of the rows.",
      "Returns the row count and up to the configured number of preview rows."
    ),
    parameters = list(path = param_string("Path to the CSV file")),
    handler = function(args_json) {
      args <- jsonlite::fromJSON(args_json)
      if (is.null(args$path) || !nzchar(args$path)) stop("Missing 'path'")
      df <- utils::read.csv(args$path, stringsAsFactors = FALSE)
      n <- min(as.integer(max_rows), nrow(df))
      jsonlite::toJSON(
        list(rows = nrow(df), columns = names(df), data = utils::head(df, n)),
        auto_unbox = TRUE
      )
    }
  )
}

#' PDF text extraction tool
#'
#' Returns a ready-to-use tool that extracts text from a PDF file. Requires the
#' `pdftools` package.
#'
#' @return A tool definition list (see [tool()]).
#' @export
tool_read_pdf <- function() {
  tool(
    name = "read_pdf",
    description = paste(
      "Extract text from a PDF file. Requires the 'pdftools' package.",
      "Returns the number of pages and the concatenated text."
    ),
    parameters = list(path = param_string("Path to the PDF file")),
    handler = function(args_json) {
      if (!requireNamespace("pdftools", quietly = TRUE)) {
        stop("The 'pdftools' package is required for this tool. Install it with install.packages(\"pdftools\").")
      }
      args <- jsonlite::fromJSON(args_json)
      if (is.null(args$path) || !nzchar(args$path)) stop("Missing 'path'")
      txt <- pdftools::pdf_text(args$path)
      jsonlite::toJSON(
        list(pages = length(txt), text = paste(txt, collapse = "\n\n")),
        auto_unbox = TRUE
      )
    }
  )
}

#' SQLite query tool
#'
#' Returns a ready-to-use tool that runs a SQL query against a SQLite database
#' and returns the result rows as JSON. Requires the `DBI` and `RSQLite`
#' packages. The connection is opened and closed per call.
#'
#' @param db_path Default path to the SQLite file (used when the caller does
#'   not pass a `db` argument). Leave `NULL` to require the caller to supply it.
#' @return A tool definition list (see [tool()]).
#' @export
tool_sql <- function(db_path = NULL) {
  tool(
    name = "sql_query",
    description = paste(
      "Run a SQL query against a SQLite database and return the result rows.",
      "Requires the 'DBI' and 'RSQLite' packages."
    ),
    parameters = list(
      query = param_string("SQL query to run"),
      db    = param_string("Path to the SQLite file", required = FALSE)
    ),
    handler = function(args_json) {
      if (!requireNamespace("DBI", quietly = TRUE) ||
          !requireNamespace("RSQLite", quietly = TRUE)) {
        stop("This tool requires the 'DBI' and 'RSQLite' packages.")
      }
      args <- jsonlite::fromJSON(args_json)
      if (is.null(args$query) || !nzchar(args$query)) stop("Missing 'query'")
      db <- if (is.null(args$db) || !nzchar(args$db)) db_path else args$db
      if (is.null(db) || !nzchar(db)) stop("No SQLite database path supplied.")
      con <- DBI::dbConnect(RSQLite::SQLite(), db)
      on.exit(DBI::dbDisconnect(con), add = TRUE)
      res <- DBI::dbGetQuery(con, args$query)
      jsonlite::toJSON(res, auto_unbox = TRUE)
    }
  )
}
