# OpenAI Responses API image file-reference content parts: input_image carries a
# flat "file_id" (distinct from the Chat-Completions "image_url" url form).

test_that("input_image file_id part serializes flat", {
  chat <- agentgraph:::chat_native_cpp
  prov <- function(key, model, base) {
    list(name = "openai", api_key = key, model = model, base_url = base)
  }

  msg <- list(list(
    role = "user",
    content = list(
      list(type = "text", text = "Describe this image."),
      list(type = "input_image", file_id = "file-image-789")
    )
  ))

  m <- start_mock_llm(list(list(finish_reason = "stop", content = "ok")))
  on.exit(stop_py_mock(m), add = TRUE)
  base <- paste0("http://127.0.0.1:", m$port)
  r <- chat(prov("test-key", "mock-image-file", base), msg, "")
  expect_identical(r$content, "ok")

  Sys.sleep(0.3)
  log <- paste(readLines(m$log, warn = FALSE), collapse = "\n")
  body <- jsonlite::fromJSON(log, simplifyVector = FALSE)
  idx <- which(vapply(body$messages, function(x) identical(x$role, "user"), logical(1)))[1]
  um <- body$messages[[idx]]
  expect_identical(um$content[[1]]$type, "text")
  expect_identical(um$content[[1]]$text, "Describe this image.")
  expect_identical(um$content[[2]]$type, "input_image")
  expect_identical(um$content[[2]]$file_id, "file-image-789")
  expect_null(um$content[[2]]$input_image)
})

test_that("image_file_part round-trips through graph state", {
  gate <- function() {
    state_graph(entry = "gate") |>
      add_node("gate", interrupt_node()) |>
      add_edge("gate", "__end__")
  }
  res <- run(gate(), state = list(
    messages = list(user_msg(content_parts(
      text_part("analyze this image"),
      image_file_part("file-image-789")
    )))
  ))
  c <- res$messages[[1]]$content
  expect_identical(c[[1]]$type, "text")
  expect_identical(c[[1]]$text, "analyze this image")
  expect_identical(c[[2]]$type, "input_image")
  expect_identical(c[[2]]$file_id, "file-image-789")
})

test_that("image_url and input_image coexist in one message", {
  gate <- function() {
    state_graph(entry = "gate") |>
      add_node("gate", interrupt_node()) |>
      add_edge("gate", "__end__")
  }
  res <- run(gate(), state = list(
    messages = list(user_msg(content_parts(
      image_part("https://example.com/a.png"),
      image_file_part("file-image-789")
    )))
  ))
  c <- res$messages[[1]]$content
  expect_identical(c[[1]]$type, "image_url")
  expect_identical(c[[1]]$image_url$url, "https://example.com/a.png")
  expect_identical(c[[2]]$type, "input_image")
  expect_identical(c[[2]]$file_id, "file-image-789")
})
