# Multimodal (video) support: video content parts flow end-to-end as the
# OpenAI-compatible "video_url" parts array.

test_that("video content parts serialize to the OpenAI video_url parts array", {
  chat <- agentgraph:::chat_native_cpp
  prov <- function(key, model, base) {
    list(name = "openai", api_key = key, model = model, base_url = base)
  }

  msg <- list(list(
    role = "user",
    content = list(
      list(type = "text", text = "Summarize this video."),
      list(
        type = "video_url",
        video_url = list(url = "https://example.com/clip.mp4")
      )
    )
  ))

  m <- start_mock_llm(list(list(finish_reason = "stop", content = "A summary")))
  on.exit(stop_py_mock(m), add = TRUE)
  base <- paste0("http://127.0.0.1:", m$port)
  r <- chat(prov("test-key", "mock-video", base), msg, "")
  expect_identical(r$content, "A summary")

  Sys.sleep(0.3)
  log <- paste(readLines(m$log, warn = FALSE), collapse = "\n")
  body <- jsonlite::fromJSON(log, simplifyVector = FALSE)
  idx <- which(vapply(body$messages, function(x) identical(x$role, "user"), logical(1)))[1]
  um <- body$messages[[idx]]
  expect_identical(um$content[[1]]$type, "text")
  expect_identical(um$content[[1]]$text, "Summarize this video.")
  expect_identical(um$content[[2]]$type, "video_url")
  expect_identical(um$content[[2]]$video_url$url, "https://example.com/clip.mp4")
})

test_that("video part round-trips through graph state", {
  gate <- function() {
    state_graph(entry = "gate") |>
      add_node("gate", interrupt_node()) |>
      add_edge("gate", "__end__")
  }
  res <- run(gate(), state = list(
    messages = list(user_msg(content_parts(
      text_part("analyze this"),
      video_part("https://example.com/movie.mp4")
    )))
  ))
  c <- res$messages[[1]]$content
  expect_identical(c[[1]]$type, "text")
  expect_identical(c[[1]]$text, "analyze this")
  expect_identical(c[[2]]$type, "video_url")
  expect_identical(c[[2]]$video_url$url, "https://example.com/movie.mp4")
})
