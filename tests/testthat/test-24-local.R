test_that("provider_local returns an OpenAI-compatible local config", {
  p <- provider_local(model = "mistral-7b", base_url = "http://127.0.0.1:8080/v1")
  expect_identical(p$name, "openai")
  expect_identical(p$api_key, "local")
  expect_identical(p$model, "mistral-7b")
  expect_identical(p$base_url, "http://127.0.0.1:8080/v1")
  expect_identical(p$max_retries, 3L)
  expect_identical(p$requests_per_minute, 0L)
})

test_that("llama_server errors cleanly when the model file is missing", {
  expect_error(
    llama_server(model_path = tempfile(fileext = ".gguf")),
    "model file not found"
  )
})

test_that("llama_server_stop is a no-op on a NULL handle", {
  expect_null(llama_server_stop(NULL))
})
