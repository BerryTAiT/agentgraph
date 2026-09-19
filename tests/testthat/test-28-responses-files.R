# OpenAI Responses API file-reference content parts: input_video / input_audio
# carry a flat "file_id" (not nested url/data) and flow end-to-end.

test_that("input_video / input_audio file_id parts serialize flat", {
  chat <- agentgraph:::chat_native_cpp
  prov <- function(key, model, base) {
    list(name = "openai", api_key = key, model = model, base_url = base)
  }

  msg <- list(list(
    role = "user",
    content = list(
      list(type = "text", text = "Review this clip and transcript."),
      list(type = "input_video", file_id = "file-video-123"),
      list(type = "input_audio", file_id = "file-audio-456")
    )
  ))

  m <- start_mock_llm(list(list(finish_reason = "stop", content = "ok")))
  on.exit(stop_py_mock(m), add = TRUE)
  base <- paste0("http://127.0.0.1:", m$port)
  r <- chat(prov("test-key", "mock-files", base), msg, "")
  expect_identical(r$content, "ok")

  Sys.sleep(0.3)
  log <- paste(readLines(m$log, warn = FALSE), collapse = "\n")
  body <- jsonlite::fromJSON(log, simplifyVector = FALSE)
  idx <- which(vapply(body$messages, function(x) identical(x$role, "user"), logical(1)))[1]
  um <- body$messages[[idx]]
  expect_identical(um$content[[1]]$type, "text")
  expect_identical(um$content[[1]]$text, "Review this clip and transcript.")
  expect_identical(um$content[[2]]$type, "input_video")
  expect_identical(um$content[[2]]$file_id, "file-video-123")
  expect_null(um$content[[2]]$input_video)
  expect_identical(um$content[[3]]$type, "input_audio")
  expect_identical(um$content[[3]]$file_id, "file-audio-456")
  expect_null(um$content[[3]]$input_audio)
})

test_that("video_file_part / audio_file_part round-trip through graph state", {
  gate <- function() {
    state_graph(entry = "gate") |>
      add_node("gate", interrupt_node()) |>
      add_edge("gate", "__end__")
  }
  res <- run(gate(), state = list(
    messages = list(user_msg(content_parts(
      text_part("analyze these files"),
      video_file_part("file-video-123"),
      audio_file_part("file-audio-456")
    )))
  ))
  c <- res$messages[[1]]$content
  expect_identical(c[[1]]$type, "text")
  expect_identical(c[[1]]$text, "analyze these files")
  expect_identical(c[[2]]$type, "input_video")
  expect_identical(c[[2]]$file_id, "file-video-123")
  expect_identical(c[[3]]$type, "input_audio")
  expect_identical(c[[3]]$file_id, "file-audio-456")
})

test_that("inline audio_part still round-trips alongside file_id audio", {
  gate <- function() {
    state_graph(entry = "gate") |>
      add_node("gate", interrupt_node()) |>
      add_edge("gate", "__end__")
  }
  res <- run(gate(), state = list(
    messages = list(user_msg(content_parts(
      audio_part("UklGRiQAAABXQVZF", "wav"),
      audio_file_part("file-audio-456")
    )))
  ))
  c <- res$messages[[1]]$content
  expect_identical(c[[1]]$type, "input_audio")
  expect_identical(c[[1]]$input_audio$data, "UklGRiQAAABXQVZF")
  expect_identical(c[[1]]$input_audio$format, "wav")
  expect_identical(c[[2]]$type, "input_audio")
  expect_identical(c[[2]]$file_id, "file-audio-456")
})
