# Computer use / desktop automation ------------------------------------------
#
# computer_use() performs one desktop action (screenshot, move, click, type,
# key, scroll). The default dry_run = TRUE validates + echoes the action (safe,
# no real input); dry_run = FALSE runs a Windows PowerShell backend. The
# screenshot action pairs with the existing vision/image input so a model can
# "see" the screen and act.

.computer_actions <- c("screenshot", "move", "click", "type", "key", "scroll")
.computer_required <- c(screenshot = "path", move = "x,y", click = "x,y",
                        type = "text", key = "keys", scroll = "dy")

# Validate an action + its args. Returns the action (or stops).
.validate_computer <- function(action, args) {
  if (!is.character(action) || length(action) != 1L || !action %in% .computer_actions) {
    stop("computer_use(): `action` must be one of: ",
         paste(.computer_actions, collapse = ", "), ".")
  }
  req <- strsplit(.computer_required[[action]], ",", fixed = TRUE)[[1L]]
  missing <- req[!vapply(req, function(k) !is.null(args[[k]]), logical(1L))]
  if (length(missing) > 0L) {
    stop("computer_use(): action '", action, "' requires: ", paste(missing, collapse = ", "), ".")
  }
  invisible(action)
}

# Build a PowerShell command string for an action (Windows).
.ps_screenshot <- function(path) {
  paste0(
    "Add-Type -AssemblyName System.Windows.Forms,System.Drawing;",
    "$b=New-Object System.Drawing.Bitmap([System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Width,",
    "[System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Height);",
    "$g=[System.Drawing.Graphics]::FromImage($b);",
    "$g.CopyFromScreen(0,0,0,0,$b.Size);",
    "$b.Save('", gsub("'", "''", path), "');$g.Dispose();$b.Dispose()")
}

.ps_mouse <- function(x, y, down, up) {
  sprintf(
    "Add-Type 'using System;using System.Runtime.InteropServices;public class M{[DllImport(\"user32.dll\")]public static extern bool SetCursorPos(int X,int Y);[DllImport(\"user32.dll\")]public static extern void mouse_event(int f,int dx,int dy,int c,int e);}';[M]::SetCursorPos(%d,%d);[M]::mouse_event(%d,0,0,0,0);[M]::mouse_event(%d,0,0,0,0)",
    as.integer(x), as.integer(y), down, up)
}

.ps_type <- function(text, keys = FALSE) {
  txt <- if (keys) text else gsub("([{}()+^%~])", "{\\$1}", text, perl = TRUE)
  sprintf("Add-Type -AssemblyName System.Windows.Forms;[System.Windows.Forms.SendKeys]::SendWait('%s')",
          gsub("'", "''", txt))
}

.computer_windows <- function(action, args) {
  cmd <- switch(action,
    screenshot = .ps_screenshot(args$path),
    move = .ps_mouse(args$x, args$y, 0, 0),
    click = .ps_mouse(args$x, args$y, 2, 4),
    type = .ps_type(args$text),
    key = .ps_type(args$keys, keys = TRUE),
    scroll = sprintf(
      "Add-Type 'using System;using System.Runtime.InteropServices;public class M{[DllImport(\"user32.dll\")]public static extern void mouse_event(int f,int dx,int dy,int c,int e);}';[M]::mouse_event(2048,0,%d,0,0)",
      as.integer(args$dy))
  )
  system2("powershell", c("-NoProfile", "-Command", cmd))
}

#' Perform one desktop action
#'
#' Validates and (when `dry_run = FALSE`) executes a desktop action on Windows:
#' screenshot, move, click, type, key, or scroll. With `dry_run = TRUE` (the
#' default) the action is validated and echoed without any real input.
#'
#' @param action One of "screenshot", "move", "click", "type", "key", "scroll"
#' @param ... Action arguments (`path`, `x`, `y`, `text`, `keys`, `dy`, `button`)
#' @param dry_run If TRUE (default), echo the action instead of executing
#' @return A JSON string describing the (would-be) action
#' @export
computer_use <- function(action, ..., dry_run = TRUE) {
  args <- list(...)
  .validate_computer(action, args)
  if (dry_run) {
    return(jsonlite::toJSON(c(list(action = action, dry_run = TRUE), args),
                            auto_unbox = TRUE))
  }
  if (.Platform$OS.type != "windows") {
    stop("computer_use(): real desktop control is only supported on Windows.")
  }
  .computer_windows(action, args)
  jsonlite::toJSON(c(list(action = action, dry_run = FALSE, ok = TRUE), args),
                   auto_unbox = TRUE)
}

#' Create a computer-use tool
#'
#' Returns a tool the agent can call to take desktop actions. With
#' `dry_run = TRUE` (default) actions are validated + echoed without real input;
#' set `dry_run = FALSE` for real Windows control.
#'
#' @param dry_run If TRUE (default), echo actions instead of executing
#' @return A tool definition (see [tool()])
#' @export
tool_computer_use <- function(dry_run = TRUE) {
  make_handler <- function(dry_run) {
    force(dry_run)
    function(args_json) {
      args <- jsonlite::fromJSON(args_json, simplifyVector = FALSE)
      action <- args$action
      valid <- c("screenshot", "move", "click", "type", "key", "scroll")
      if (is.null(action) || length(action) != 1L || !action %in% valid) {
        stop("computer_use: action must be one of: ", paste(valid, collapse = ", "))
      }
      req <- switch(action,
                    screenshot = "path", move = "x,y", click = "x,y",
                    type = "text", key = "keys", scroll = "dy")
      need <- strsplit(req, ",", fixed = TRUE)[[1L]]
      miss <- need[!vapply(need, function(k) !is.null(args[[k]]), logical(1L))]
      if (length(miss) > 0L) {
        stop("computer_use: action '", action, "' requires: ", paste(miss, collapse = ", "))
      }
      if (isTRUE(dry_run)) {
        return(jsonlite::toJSON(c(list(action = action, dry_run = TRUE), args),
                                auto_unbox = TRUE))
      }
      if (.Platform$OS.type != "windows") {
        stop("computer_use: real desktop control is only supported on Windows.")
      }
      cmd <- switch(action,
        screenshot = paste0(
          "Add-Type -AssemblyName System.Windows.Forms,System.Drawing;",
          "$b=New-Object System.Drawing.Bitmap([System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Width,",
          "[System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Height);",
          "$g=[System.Drawing.Graphics]::FromImage($b);$g.CopyFromScreen(0,0,0,0,$b.Size);",
          "$b.Save('", gsub("'", "''", args$path), "');$g.Dispose();$b.Dispose()"),
        move = sprintf(
          "Add-Type 'using System;using System.Runtime.InteropServices;public class M{[DllImport(\"user32.dll\")]public static extern bool SetCursorPos(int X,int Y);}';[M]::SetCursorPos(%d,%d)",
          as.integer(args$x), as.integer(args$y)),
        click = "Add-Type 'using System;using System.Runtime.InteropServices;public class M{[DllImport(\"user32.dll\")]public static extern void mouse_event(int f,int dx,int dy,int c,int e);}';[M]::mouse_event(2,0,0,0,0);[M]::mouse_event(4,0,0,0,0)",
        type = sprintf("Add-Type -AssemblyName System.Windows.Forms;[System.Windows.Forms.SendKeys]::SendWait('%s')",
                       gsub("'", "''", gsub("([{}()+^%~])", "{\\$1}", args$text, perl = TRUE))),
        key = sprintf("Add-Type -AssemblyName System.Windows.Forms;[System.Windows.Forms.SendKeys]::SendWait('%s')",
                      gsub("'", "''", args$keys)),
        scroll = sprintf(
          "Add-Type 'using System;using System.Runtime.InteropServices;public class M{[DllImport(\"user32.dll\")]public static extern void mouse_event(int f,int dx,int dy,int c,int e);}';[M]::mouse_event(2048,0,%d,0,0)",
          as.integer(args$dy))
      )
      system2("powershell", c("-NoProfile", "-Command", cmd))
      jsonlite::toJSON(c(list(action = action, dry_run = FALSE, ok = TRUE), args),
                       auto_unbox = TRUE)
    }
  }
  tool(
    name = "computer",
    description = paste(
      "Take a desktop action: screenshot, move, click, type, key, or scroll.",
      "Use screenshot to see the screen (vision), then act on it."
    ),
    parameters = list(
      action = param_enum("Action", c("screenshot", "move", "click", "type", "key", "scroll")),
      path = param_string("Screenshot output path", required = FALSE),
      x = param_integer("X coordinate", required = FALSE),
      y = param_integer("Y coordinate", required = FALSE),
      text = param_string("Text to type", required = FALSE),
      keys = param_string("Key combination to press", required = FALSE),
      dy = param_integer("Vertical scroll delta", required = FALSE),
      button = param_enum("Mouse button", c("left", "right", "middle"), required = FALSE)
    ),
    handler = make_handler(dry_run)
  )
}
