# Multimodal (audio) support: audio content parts flow end-to-end as the
# OpenAI/Azure "input_audio" parts array.

test_that("audio content parts serialize to the OpenAI input_audio parts array", {
  chat <- agentgraph:::chat_native_cpp
  prov <- function(key, model, base) {
    list(name = "openai", api_key = key, model = model, base_url = base)
  }

  msg <- list(list(
    role = "user",
    content = list(
      list(type = "text", text = "Transcribe this audio."),
      list(
        type = "input_audio",
        input_audio = list(data = "UklGRiQAAABXQVZF", format = "wav")
      )
    )
  ))

  m <- start_mock_llm(list(list(finish_reason = "stop", content = "A transcript")))
  on.exit(stop_py_mock(m), add = TRUE)
  base <- paste0("http://127.0.0.1:", m$port)
  r <- chat(prov("test-key", "mock-audio", base), msg, "")
  expect_identical(r$content, "A transcript")

  Sys.sleep(0.3)
  log <- paste(readLines(m$log, warn = FALSE), collapse = "\n")
  body <- jsonlite::fromJSON(log, simplifyVector = FALSE)
  idx <- which(vapply(body$messages, function(x) identical(x$role, "user"), logical(1)))[1]
  um <- body$messages[[idx]]
  expect_identical(um$content[[1]]$type, "text")
  expect_identical(um$content[[1]]$text, "Transcribe this audio.")
  expect_identical(um$content[[2]]$type, "input_audio")
  expect_identical(um$content[[2]]$input_audio$data, "UklGRiQAAABXQVZF")
  expect_identical(um$content[[2]]$input_audio$format, "wav")
})

test_that("audio part round-trips through graph state", {
  gate <- function() {
    state_graph(entry = "gate") |>
      add_node("gate", interrupt_node()) |>
      add_edge("gate", "__end__")
  }
  res <- run(gate(), state = list(
    messages = list(user_msg(content_parts(
      text_part("what is said here"),
      audio_part("UklGRiQAAABXQVZF", "wav")
    )))
  ))
  c <- res$messages[[1]]$content
  expect_identical(c[[1]]$type, "text")
  expect_identical(c[[1]]$text, "what is said here")
  expect_identical(c[[2]]$type, "input_audio")
  expect_identical(c[[2]]$input_audio$data, "UklGRiQAAABXQVZF")
  expect_identical(c[[2]]$input_audio$format, "wav")
})
