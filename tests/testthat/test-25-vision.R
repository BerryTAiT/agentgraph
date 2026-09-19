# Multimodal (vision) support: image content parts flow end-to-end as the
# OpenAI vision parts array, while plain string content keeps working.

test_that("vision content parts serialize to the OpenAI parts array", {
  chat <- agentgraph:::chat_native_cpp
  prov <- function(key, model, base) {
    list(name = "openai", api_key = key, model = model, base_url = base)
  }

  msg <- list(list(
    role = "user",
    content = list(
      list(type = "text", text = "What is in this image?"),
      list(
        type = "image_url",
        image_url = list(url = "https://example.com/cat.png", detail = "low")
      )
    )
  ))

  m <- start_mock_llm(list(list(finish_reason = "stop", content = "A cat")))
  on.exit(stop_py_mock(m), add = TRUE)
  base <- paste0("http://127.0.0.1:", m$port)
  r <- chat(prov("test-key", "mock-vision", base), msg, "")
  expect_identical(r$content, "A cat")

  Sys.sleep(0.3)
  log <- paste(readLines(m$log, warn = FALSE), collapse = "\n")
  body <- jsonlite::fromJSON(log, simplifyVector = FALSE)
  idx <- which(vapply(body$messages, function(x) identical(x$role, "user"), logical(1)))[1]
  um <- body$messages[[idx]]
  expect_identical(um$content[[1]]$type, "text")
  expect_identical(um$content[[1]]$text, "What is in this image?")
  expect_identical(um$content[[2]]$type, "image_url")
  expect_identical(um$content[[2]]$image_url$url, "https://example.com/cat.png")
  expect_identical(um$content[[2]]$image_url$detail, "low")
})

test_that("image detail is omitted when not provided", {
  chat <- agentgraph:::chat_native_cpp
  prov <- function(key, model, base) {
    list(name = "openai", api_key = key, model = model, base_url = base)
  }
  msg <- list(list(
    role = "user",
    content = list(
      list(type = "image_url", image_url = list(url = "https://example.com/a.png"))
    )
  ))

  m <- start_mock_llm(list(list(content = "ok")))
  on.exit(stop_py_mock(m), add = TRUE)
  base <- paste0("http://127.0.0.1:", m$port)
  invisible(chat(prov("k", "mm", base), msg, ""))
  Sys.sleep(0.3)
  log <- paste(readLines(m$log, warn = FALSE), collapse = "\n")
  body <- jsonlite::fromJSON(log, simplifyVector = FALSE)
  um <- body$messages[[which(vapply(body$messages, function(x) identical(x$role, "user"), logical(1)))[1]]]
  expect_null(um$content[[1]]$image_url$detail)
})

test_that("parse_llm_response_cpp joins array content into text", {
  parse <- agentgraph:::parse_llm_response_cpp
  arr <- '{"model":"m","choices":[{"message":{"role":"assistant","content":[{"type":"text","text":"Hello "},{"type":"text","text":"world"}]},"finish_reason":"stop"}]}'
  r <- parse(arr)
  expect_identical(r$content, "Hello world")
  expect_identical(r$finish_reason, "stop")
})

test_that("multimodal messages round-trip through graph state", {
  gate <- function() {
    state_graph(entry = "gate") |>
      add_node("gate", interrupt_node()) |>
      add_edge("gate", "__end__")
  }
  res <- run(gate(), state = list(
    messages = list(user_msg(content_parts(
      text_part("describe this"),
      image_part("https://example.com/x.png", "high")
    )))
  ))
  c <- res$messages[[1]]$content
  expect_identical(c[[1]]$type, "text")
  expect_identical(c[[1]]$text, "describe this")
  expect_identical(c[[2]]$type, "image_url")
  expect_identical(c[[2]]$image_url$url, "https://example.com/x.png")
  expect_identical(c[[2]]$image_url$detail, "high")
})
