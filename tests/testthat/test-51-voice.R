# Voice pipeline (R/voice.R). STT/TTS are tested against the voice mock.

test_that("provider_whisper and provider_elevenlabs build configs", {
  w <- agentgraph::provider_whisper(api_key = "k", model = "whisper-1", base_url = "http://x")
  expect_identical(w$name, "whisper")
  expect_identical(w$model, "whisper-1")

  e <- agentgraph::provider_elevenlabs(api_key = "k", voice_id = "abc123")
  expect_identical(e$name, "elevenlabs")
  expect_identical(e$voice_id, "abc123")
})

test_that("transcribe sends audio and returns the transcript", {
  testthat::skip_if_not(python_available())
  testthat::skip_if_not_installed("curl")
  m <- start_voice_mock()
  on.exit(stop_py_mock(m), add = TRUE)

  f <- tempfile(fileext = ".wav")
  writeBin(charToRaw("fake wav"), f)

  p <- agentgraph::provider_whisper(api_key = "test",
                                    base_url = paste0("http://127.0.0.1:", m$port))
  txt <- agentgraph::transcribe(f, provider = p)
  expect_identical(txt, "hello from stt")
})

test_that("synthesize writes audio bytes to a file", {
  testthat::skip_if_not(python_available())
  testthat::skip_if_not_installed("curl")
  m <- start_voice_mock()
  on.exit(stop_py_mock(m), add = TRUE)

  p <- agentgraph::provider_elevenlabs(api_key = "test", voice_id = "v1",
                                       base_url = paste0("http://127.0.0.1:", m$port))
  out <- tempfile(fileext = ".mp3")
  res <- agentgraph::synthesize("hello", provider = p, output_file = out)
  expect_identical(res, out)
  expect_true(file.exists(out))
  expect_identical(rawToChar(readBin(out, "raw", n = file.info(out)$size)),
                   "FAKE_AUDIO_MP3")
})

test_that("voice_run chains graph -> TTS (mock)", {
  testthat::skip_if_not(python_available())
  testthat::skip_if_not_installed("curl")

  # LLM via the built-in mock; TTS via the voice mock
  vm <- start_voice_mock()
  on.exit(stop_py_mock(vm), add = TRUE)

  llm <- agentgraph::provider_mock(list("*" = "the answer is 42"))
  g <- agentgraph::state_graph(entry = "n") |>
    agentgraph::add_node("n", agentgraph::llm_node(provider = llm)) |>
    agentgraph::add_edge("n", "__end__")

  tts <- agentgraph::provider_elevenlabs(api_key = "test", voice_id = "v1",
                                         base_url = paste0("http://127.0.0.1:", vm$port))
  r <- agentgraph::voice_run(g, text = "what is 6 times 7", tts_provider = tts)

  expect_identical(r$answer, "the answer is 42")
  expect_true(file.exists(r$audio))
})

test_that("voice_run transcribes audio then runs (mock)", {
  testthat::skip_if_not(python_available())
  testthat::skip_if_not_installed("curl")

  vm <- start_voice_mock()
  on.exit(stop_py_mock(vm), add = TRUE)

  llm <- agentgraph::provider_mock(list("*" = "ok"))
  g <- agentgraph::state_graph(entry = "n") |>
    agentgraph::add_node("n", agentgraph::llm_node(provider = llm)) |>
    agentgraph::add_edge("n", "__end__")

  stt <- agentgraph::provider_whisper(api_key = "test",
                                      base_url = paste0("http://127.0.0.1:", vm$port))
  f <- tempfile(fileext = ".wav")
  writeBin(charToRaw("fake wav"), f)

  r <- agentgraph::voice_run(g, audio_file = f, stt_provider = stt)
  expect_identical(r$text, "hello from stt")
  expect_identical(r$answer, "ok")
  expect_null(r$audio)  # no TTS provider
})

test_that("transcribe/synthesize validate their input", {
  testthat::skip_if_not_installed("curl")
  e <- err_msg(agentgraph::transcribe("no-such-file.wav"))
  expect_true(grepl("existing file", e, fixed = TRUE))

  p <- agentgraph::provider_elevenlabs(api_key = "k", voice_id = NULL)
  e2 <- err_msg(agentgraph::synthesize("hi", provider = p))
  expect_true(grepl("voice_id", e2, fixed = TRUE))
})
