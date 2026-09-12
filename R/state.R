#' Create a user message
#' @param content Message content
#' @return A message list
#' @export
user_msg <- function(content) {
  list(role = "user", content = content)
}

#' Create a system message
#' @param content Message content
#' @return A message list
#' @export
system_msg <- function(content) {
  list(role = "system", content = content)
}

#' Create an assistant message
#' @param content Message content
#' @return A message list
#' @export
assistant_msg <- function(content) {
  list(role = "assistant", content = content)
}

#' Create a tool result message
#' @param tool_call_id The tool call ID this result is for
#' @param content The result content
#' @return A message list
#' @export
tool_msg <- function(tool_call_id, content) {
  list(role = "tool", content = content, tool_call_id = tool_call_id)
}

#' Reducer: append messages
#' @param existing Existing messages
#' @param new New messages to append
#' @return Combined messages
#' @export
append_messages <- function(existing, new) {
  c(existing, new)
}

#' Reducer: overwrite value
#' @param existing Existing value (ignored)
#' @param new New value
#' @return The new value
#' @export
overwrite <- function(existing, new) {
  new
}

#' Reducer: merge state lists
#' @param existing Existing state list
#' @param new New values to merge
#' @return Merged state
#' @export
merge_state <- function(existing, new) {
  modifyList(existing, new)
}
