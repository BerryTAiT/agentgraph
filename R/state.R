#' Create a user message
#' @param content Message content
#' @return A message list
#' @export
user_msg <- function(content) {
  if (is.null(content)) {
    stop("user_msg(): `content` must be a character string or a list of content parts, not NULL.")
  }
  list(role = "user", content = content)
}

#' Create a system message
#' @param content Message content
#' @return A message list
#' @export
system_msg <- function(content) {
  if (is.null(content)) {
    stop("system_msg(): `content` must be a character string or a list of content parts, not NULL.")
  }
  list(role = "system", content = content)
}

#' Create an assistant message
#' @param content Message content
#' @return A message list
#' @export
assistant_msg <- function(content) {
  if (is.null(content)) {
    stop("assistant_msg(): `content` must be a character string or a list of content parts, not NULL.")
  }
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

#' Create a text content part (for multimodal messages)
#' @param text The text content
#' @return A content part list
#' @export
text_part <- function(text) {
  list(type = "text", text = text)
}

#' Create an image content part (for vision models)
#' @param url Image URL or base64 data URL
#' @param detail Optional detail level ("auto", "low", or "high")
#' @return A content part list
#' @export
image_part <- function(url, detail = NULL) {
  image_url <- list(url = url)
  if (!is.null(detail)) image_url$detail <- detail
  list(type = "image_url", image_url = image_url)
}

#' Create a video content part (for multimodal video models)
#' @param url Video URL or base64 data URL
#' @return A content part list
#' @export
video_part <- function(url) {
  list(type = "video_url", video_url = list(url = url))
}

#' Create an audio content part (for multimodal audio models)
#' @param data Base64-encoded audio data
#' @param format Audio encoding (e.g. "wav", "mp3")
#' @return A content part list
#' @export
audio_part <- function(data, format = "wav") {
  input_audio <- list(data = data)
  if (!is.null(format)) input_audio$format <- format
  list(type = "input_audio", input_audio = input_audio)
}

#' Create a video content part referencing an uploaded file (Responses API)
#' @param file_id The uploaded file ID (e.g. "file-...")
#' @return A content part list
#' @export
video_file_part <- function(file_id) {
  list(type = "input_video", file_id = file_id)
}

#' Create an image content part referencing an uploaded file (Responses API)
#' @param file_id The uploaded file ID (e.g. "file-...")
#' @return A content part list
#' @export
image_file_part <- function(file_id) {
  list(type = "input_image", file_id = file_id)
}

#' Create an audio content part referencing an uploaded file (Responses API)
#' @param file_id The uploaded file ID (e.g. "file-...")
#' @return A content part list
#' @export
audio_file_part <- function(file_id) {
  list(type = "input_audio", file_id = file_id)
}

#' Combine content parts into a multimodal message body
#' @param ... One or more content parts (from \code{text_part()} / \code{image_part()})
#' @return A list of content parts
#' @export
content_parts <- function(...) {
  list(...)
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
