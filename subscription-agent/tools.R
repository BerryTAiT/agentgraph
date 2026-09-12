# Tool definitions for the Streamly subscription agent.
#
# IMPORTANT: agentgraph runs custom tool handlers in an ISOLATED R process
# (the "tool server"). R closures do NOT serialize their enclosing environment,
# so every handler below is fully self-contained: it loads its own packages,
# resolves the database path from AGENTGRAPH_DB_PATH (with a stable fallback),
# creates the table if needed, opens its own connection, and returns a JSON
# string.

build_tools <- function() {

  # --- catalog -------------------------------------------------------------
  get_plans <- tool(
    name = "get_plans",
    description = "Return the subscription plan catalog for the movie-streaming platform.",
    parameters = list(),
    handler = function(args_json) {
      suppressPackageStartupMessages(library(jsonlite))
      plans <- list(
        basic   = list(price = 0,    period = "none",  description = "Default plan for new accounts. No charge, but no access to watch movies."),
        monthly = list(price = 300,  period = "month", description = "Full access to the entire movie library, billed monthly."),
        annual  = list(price = 1000, period = "year",  description = "Full access to the entire movie library, billed once a year.")
      )
      jsonlite::toJSON(list(ok = TRUE, plans = plans), auto_unbox = TRUE)
    }
  )

  # --- register ------------------------------------------------------------
  register_user <- tool(
    name = "register_user",
    description = "Create a new account for a user with the given username, email and password. The account starts on the 'basic' plan.",
    parameters = list(
      username = param_string("Desired username"),
      email    = param_string("Email address"),
      password = param_string("Password")
    ),
    handler = function(args_json) {
      suppressPackageStartupMessages({
        library(jsonlite); library(DBI); library(RSQLite); library(openssl)
      })
      db <- Sys.getenv("AGENTGRAPH_DB_PATH", unset = "")
      if (!nzchar(db)) db <- file.path(Sys.getenv("USERPROFILE", tempdir()), "subscription_agent.sqlite")
      dir.create(dirname(db), showWarnings = FALSE, recursive = TRUE)
      con <- DBI::dbConnect(RSQLite::SQLite(), db)
      on.exit(DBI::dbDisconnect(con), add = TRUE)
      DBI::dbExecute(con, "CREATE TABLE IF NOT EXISTS users (username TEXT PRIMARY KEY, email TEXT UNIQUE NOT NULL, password_hash TEXT NOT NULL, plan TEXT NOT NULL DEFAULT 'basic', created_at TEXT NOT NULL)")

      args <- jsonlite::fromJSON(args_json, simplifyVector = FALSE)
      username <- if (is.null(args$username)) "" else trimws(as.character(args$username))
      email    <- if (is.null(args$email))    "" else trimws(as.character(args$email))
      password <- if (is.null(args$password)) "" else as.character(args$password)

      if (!nzchar(username) || !nzchar(email) || !nzchar(password))
        return(jsonlite::toJSON(list(ok = FALSE, error = "username, email and password are all required."), auto_unbox = TRUE))
      if (!grepl("@", email, fixed = TRUE))
        return(jsonlite::toJSON(list(ok = FALSE, error = "That email looks invalid."), auto_unbox = TRUE))

      existing <- DBI::dbGetQuery(con, "SELECT username FROM users WHERE username = ? OR email = ?",
                                  params = list(username, email))
      if (nrow(existing) > 0)
        return(jsonlite::toJSON(list(ok = FALSE, error = "That username or email is already registered."), auto_unbox = TRUE))

      salt <- paste(sprintf("%02x", as.integer(openssl::rand_bytes(16))), collapse = "")
      hash <- openssl::sha256(paste0(salt, ":", password))
      DBI::dbExecute(con, "INSERT INTO users (username, email, password_hash, plan, created_at) VALUES (?, ?, ?, 'basic', ?)",
                     params = list(username, email, paste0(salt, ":", hash), as.character(Sys.time())))
      jsonlite::toJSON(list(ok = TRUE, message = paste0("Registered '", username, "'. Their profile now shows name '", username, "' and plan 'basic'."), username = username, plan = "basic"), auto_unbox = TRUE)
    }
  )

  # --- login ---------------------------------------------------------------
  login_user <- tool(
    name = "login_user",
    description = "Sign a returning user in by verifying their username and password.",
    parameters = list(
      username = param_string("Username"),
      password = param_string("Password")
    ),
    handler = function(args_json) {
      suppressPackageStartupMessages({
        library(jsonlite); library(DBI); library(RSQLite); library(openssl)
      })
      db <- Sys.getenv("AGENTGRAPH_DB_PATH", unset = "")
      if (!nzchar(db)) db <- file.path(Sys.getenv("USERPROFILE", tempdir()), "subscription_agent.sqlite")
      dir.create(dirname(db), showWarnings = FALSE, recursive = TRUE)
      con <- DBI::dbConnect(RSQLite::SQLite(), db)
      on.exit(DBI::dbDisconnect(con), add = TRUE)
      DBI::dbExecute(con, "CREATE TABLE IF NOT EXISTS users (username TEXT PRIMARY KEY, email TEXT UNIQUE NOT NULL, password_hash TEXT NOT NULL, plan TEXT NOT NULL DEFAULT 'basic', created_at TEXT NOT NULL)")

      args <- jsonlite::fromJSON(args_json, simplifyVector = FALSE)
      username <- if (is.null(args$username)) "" else trimws(as.character(args$username))
      password <- if (is.null(args$password)) "" else as.character(args$password)
      if (!nzchar(username) || !nzchar(password))
        return(jsonlite::toJSON(list(ok = FALSE, error = "username and password are required."), auto_unbox = TRUE))

      row <- DBI::dbGetQuery(con, "SELECT username, email, password_hash, plan FROM users WHERE username = ?", params = list(username))
      if (nrow(row) == 0)
        return(jsonlite::toJSON(list(ok = FALSE, error = paste0("No account found for '", username, "'. Please register first.")), auto_unbox = TRUE))

      parts <- strsplit(row$password_hash[1], ":", fixed = TRUE)[[1]]
      got <- openssl::sha256(paste0(parts[1], ":", password))
      if (!identical(got, parts[2]))
        return(jsonlite::toJSON(list(ok = FALSE, error = "Incorrect password."), auto_unbox = TRUE))

      jsonlite::toJSON(list(ok = TRUE, message = paste0("Welcome back, ", username, "!"), username = row$username[1], email = row$email[1], plan = row$plan[1]), auto_unbox = TRUE)
    }
  )

  # --- profile -------------------------------------------------------------
  get_profile <- tool(
    name = "get_profile",
    description = "Look up a user's name, email and current plan.",
    parameters = list(
      username = param_string("Username")
    ),
    handler = function(args_json) {
      suppressPackageStartupMessages({
        library(jsonlite); library(DBI); library(RSQLite)
      })
      db <- Sys.getenv("AGENTGRAPH_DB_PATH", unset = "")
      if (!nzchar(db)) db <- file.path(Sys.getenv("USERPROFILE", tempdir()), "subscription_agent.sqlite")
      dir.create(dirname(db), showWarnings = FALSE, recursive = TRUE)
      con <- DBI::dbConnect(RSQLite::SQLite(), db)
      on.exit(DBI::dbDisconnect(con), add = TRUE)
      DBI::dbExecute(con, "CREATE TABLE IF NOT EXISTS users (username TEXT PRIMARY KEY, email TEXT UNIQUE NOT NULL, password_hash TEXT NOT NULL, plan TEXT NOT NULL DEFAULT 'basic', created_at TEXT NOT NULL)")

      args <- jsonlite::fromJSON(args_json, simplifyVector = FALSE)
      username <- if (is.null(args$username)) "" else trimws(as.character(args$username))
      if (!nzchar(username))
        return(jsonlite::toJSON(list(ok = FALSE, error = "username is required."), auto_unbox = TRUE))

      row <- DBI::dbGetQuery(con, "SELECT username, email, plan FROM users WHERE username = ?", params = list(username))
      if (nrow(row) == 0)
        return(jsonlite::toJSON(list(ok = FALSE, error = paste0("No account found for '", username, "'.")), auto_unbox = TRUE))

      jsonlite::toJSON(list(ok = TRUE, username = row$username[1], email = row$email[1], plan = row$plan[1]), auto_unbox = TRUE)
    }
  )

  # --- upgrade -------------------------------------------------------------
  upgrade_plan <- tool(
    name = "upgrade_plan",
    description = "Change a user's plan to 'monthly' ($300/month) or 'annual' ($1000/year).",
    parameters = list(
      username = param_string("Username"),
      plan     = param_enum("Target plan", values = c("monthly", "annual"))
    ),
    handler = function(args_json) {
      suppressPackageStartupMessages({
        library(jsonlite); library(DBI); library(RSQLite)
      })
      db <- Sys.getenv("AGENTGRAPH_DB_PATH", unset = "")
      if (!nzchar(db)) db <- file.path(Sys.getenv("USERPROFILE", tempdir()), "subscription_agent.sqlite")
      dir.create(dirname(db), showWarnings = FALSE, recursive = TRUE)
      con <- DBI::dbConnect(RSQLite::SQLite(), db)
      on.exit(DBI::dbDisconnect(con), add = TRUE)
      DBI::dbExecute(con, "CREATE TABLE IF NOT EXISTS users (username TEXT PRIMARY KEY, email TEXT UNIQUE NOT NULL, password_hash TEXT NOT NULL, plan TEXT NOT NULL DEFAULT 'basic', created_at TEXT NOT NULL)")

      args <- jsonlite::fromJSON(args_json, simplifyVector = FALSE)
      username <- if (is.null(args$username)) "" else trimws(as.character(args$username))
      plan     <- if (is.null(args$plan)) "" else trimws(tolower(as.character(args$plan)))
      if (!nzchar(username))
        return(jsonlite::toJSON(list(ok = FALSE, error = "username is required."), auto_unbox = TRUE))
      if (!plan %in% c("monthly", "annual"))
        return(jsonlite::toJSON(list(ok = FALSE, error = "plan must be 'monthly' or 'annual'."), auto_unbox = TRUE))

      row <- DBI::dbGetQuery(con, "SELECT username, plan FROM users WHERE username = ?", params = list(username))
      if (nrow(row) == 0)
        return(jsonlite::toJSON(list(ok = FALSE, error = paste0("No account found for '", username, "'.")), auto_unbox = TRUE))

      DBI::dbExecute(con, "UPDATE users SET plan = ? WHERE username = ?", params = list(plan, username))
      price_label <- if (plan == "monthly") "$300/month" else "$1000/year"
      jsonlite::toJSON(list(ok = TRUE, message = paste0(username, " has been upgraded to the ", plan, " plan (", price_label, ")."), username = username, plan = plan), auto_unbox = TRUE)
    }
  )

  # --- cancel --------------------------------------------------------------
  cancel_plan <- tool(
    name = "cancel_plan",
    description = "Cancel a user's active subscription, issue a refund, and return them to the 'basic' plan.",
    parameters = list(
      username = param_string("Username")
    ),
    handler = function(args_json) {
      suppressPackageStartupMessages({
        library(jsonlite); library(DBI); library(RSQLite)
      })
      db <- Sys.getenv("AGENTGRAPH_DB_PATH", unset = "")
      if (!nzchar(db)) db <- file.path(Sys.getenv("USERPROFILE", tempdir()), "subscription_agent.sqlite")
      dir.create(dirname(db), showWarnings = FALSE, recursive = TRUE)
      con <- DBI::dbConnect(RSQLite::SQLite(), db)
      on.exit(DBI::dbDisconnect(con), add = TRUE)
      DBI::dbExecute(con, "CREATE TABLE IF NOT EXISTS users (username TEXT PRIMARY KEY, email TEXT UNIQUE NOT NULL, password_hash TEXT NOT NULL, plan TEXT NOT NULL DEFAULT 'basic', created_at TEXT NOT NULL)")

      args <- jsonlite::fromJSON(args_json, simplifyVector = FALSE)
      username <- if (is.null(args$username)) "" else trimws(as.character(args$username))
      if (!nzchar(username))
        return(jsonlite::toJSON(list(ok = FALSE, error = "username is required."), auto_unbox = TRUE))

      row <- DBI::dbGetQuery(con, "SELECT username, plan FROM users WHERE username = ?", params = list(username))
      if (nrow(row) == 0)
        return(jsonlite::toJSON(list(ok = FALSE, error = paste0("No account found for '", username, "'.")), auto_unbox = TRUE))

      current <- row$plan[1]
      refund_map <- c(monthly = 300, annual = 1000)
      if (!current %in% names(refund_map))
        return(jsonlite::toJSON(list(ok = FALSE, message = paste0(username, " is already on the 'basic' plan (no active subscription)."), username = username, plan = "basic"), auto_unbox = TRUE))

      DBI::dbExecute(con, "UPDATE users SET plan = 'basic' WHERE username = ?", params = list(username))
      jsonlite::toJSON(list(ok = TRUE, message = paste0(username, "'s ", current, " subscription has been cancelled and a refund of $", refund_map[[current]], " has been issued. They are now on the 'basic' plan."), username = username, plan = "basic", refund = refund_map[[current]]), auto_unbox = TRUE)
    }
  )

  list(
    get_plans    = get_plans,
    register_user = register_user,
    login_user    = login_user,
    get_profile   = get_profile,
    upgrade_plan  = upgrade_plan,
    cancel_plan   = cancel_plan
  )
}
