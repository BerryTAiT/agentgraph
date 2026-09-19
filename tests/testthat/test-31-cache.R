# LLM exact caching: identical requests are served from an in-process cache.
#
# provider_cache() wraps a provider (or fallback chain) so that a request whose
# messages + tools + system prompt + provider/model/sampling identity matches a
# previous successful completion is replayed from memory instead of hitting the
# HTTP API. The cache is process-global and shared across chat()/stream()/graph
# calls. cache_stats() reports per-provider entry counts and cache_clear()
# empties it.
#
# NOTE: every test here gives its mock a distinct `model` name. The process-wide
# cache is keyed by namespace = name|base_url|model|api_version, and the Python
# mocks all bind the same sequential port (18300), so without a unique model the
# namespaces would collide and tests would leak cached entries into each other.

mk_provider <- function(m, model, max_retries = 0L, ...) {
  agentgraph::provider_openai(
    api_key = "test", model = model,
    base_url = paste0("http://127.0.0.1:", m$port),
    max_retries = max_retries, ...
  )
}

count_requests <- function(m) {
  f <- m$log
  if (!file.exists(f)) return(0L)
  length(readLines(f, warn = FALSE))
}

chat <- function(provider, msg = list(list(role = "user", content = "hello")),
                 system_prompt = "") {
  agentgraph:::chat_native_cpp(provider, msg, system_prompt)
}

test_that("identical requests are served from the cache", {
  testthat::skip_if_not(python_available())
  m <- start_mock_llm(list(list(content = "cached answer")))
  on.exit(stop_py_mock(m), add = TRUE)

  provider <- agentgraph::provider_cache(mk_provider(m, "m1"))

  r1 <- chat(provider)
  r2 <- chat(provider)
  expect_identical(r1$content, "cached answer")
  expect_identical(r2$content, "cached answer")

  Sys.sleep(0.1)
  expect_identical(count_requests(m), 1L)
})

test_that("different messages bypass the cache", {
  testthat::skip_if_not(python_available())
  m <- start_mock_llm(list(list(content = "a"), list(content = "b")))
  on.exit(stop_py_mock(m), add = TRUE)

  provider <- agentgraph::provider_cache(mk_provider(m, "m2"))
  r1 <- chat(provider, list(list(role = "user", content = "one")))
  r2 <- chat(provider, list(list(role = "user", content = "two")))
  expect_identical(r1$content, "a")
  expect_identical(r2$content, "b")

  Sys.sleep(0.1)
  expect_identical(count_requests(m), 2L)
})

test_that("system prompt, temperature, and max_tokens are part of the key", {
  testthat::skip_if_not(python_available())
  m <- start_mock_llm(list(list(content = "a"), list(content = "b"),
                           list(content = "c"), list(content = "d")))
  on.exit(stop_py_mock(m), add = TRUE)

  p <- agentgraph::provider_cache(mk_provider(m, "m3"))
  expect_identical(chat(p)$content, "a")
  # different system prompt -> miss
  expect_identical(chat(p, list(list(role = "user", content = "hi")), "be terse")$content, "b")
  # different temperature -> miss
  p2 <- agentgraph::provider_cache(mk_provider(m, "m3", temperature = 0.1))
  expect_identical(chat(p2)$content, "c")
  # different max_tokens -> miss
  p3 <- agentgraph::provider_cache(mk_provider(m, "m3", max_tokens = 100L))
  expect_identical(chat(p3)$content, "d")

  Sys.sleep(0.1)
  expect_identical(count_requests(m), 4L)
})

test_that("cache_stats reports cached entries", {
  testthat::skip_if_not(python_available())
  m <- start_mock_llm(list(list(content = "x")))
  on.exit(stop_py_mock(m), add = TRUE)

  provider <- agentgraph::provider_cache(mk_provider(m, "m4"))
  chat(provider)

  st <- agentgraph::cache_stats()
  expect_true(is.data.frame(st))
  expect_true(all(c("namespace", "entries") %in% names(st)))
  idx <- grepl("m4", st$namespace, fixed = TRUE)
  expect_true(any(idx))
  expect_true(any(st$entries[idx] >= 1L))
})

test_that("cache_clear empties the cache so the next call re-fetches", {
  testthat::skip_if_not(python_available())
  m <- start_mock_llm(list(list(content = "x"), list(content = "y")))
  on.exit(stop_py_mock(m), add = TRUE)

  provider <- agentgraph::provider_cache(mk_provider(m, "m5"))
  expect_identical(chat(provider)$content, "x")

  agentgraph::cache_clear()
  expect_identical(chat(provider)$content, "y")

  Sys.sleep(0.1)
  expect_identical(count_requests(m), 2L)
})

test_that("entries expire after ttl_seconds", {
  testthat::skip_if_not(python_available())
  m <- start_mock_llm(list(list(content = "x"), list(content = "y")))
  on.exit(stop_py_mock(m), add = TRUE)

  provider <- agentgraph::provider_cache(mk_provider(m, "m6"), ttl_seconds = 1)
  expect_identical(chat(provider)$content, "x")

  Sys.sleep(1.2)
  expect_identical(chat(provider)$content, "y")

  Sys.sleep(0.1)
  expect_identical(count_requests(m), 2L)
})

test_that("caching wraps the whole fallback chain", {
  testthat::skip_if_not(python_available())
  primary <- start_mock_llm(list(list(status = 500L)))
  backup  <- start_mock_llm(list(list(content = "fallback cached")))
  on.exit(stop_py_mock(primary), add = TRUE)
  on.exit(stop_py_mock(backup), add = TRUE)

  chain <- agentgraph::provider_fallback(mk_provider(primary, "m7"), mk_provider(backup, "m7"))
  provider <- agentgraph::provider_cache(chain)

  r1 <- chat(provider)
  r2 <- chat(provider)
  expect_identical(r1$content, "fallback cached")
  expect_identical(r2$content, "fallback cached")

  Sys.sleep(0.1)
  expect_identical(count_requests(primary), 1L)
  expect_identical(count_requests(backup), 1L)
})

test_that("streamed calls replay the cached content", {
  testthat::skip_if_not(python_available())
  s <- start_stream_mock(c("Hel", "lo"))
  on.exit(stop_py_mock(s), add = TRUE)

  provider <- agentgraph::provider_cache(mk_provider(s, "m8"))
  graph <- state_graph(entry = "gen") |>
    add_node("gen", llm_node(provider = provider, system_prompt = "STREAM")) |>
    add_edge("gen", "__end__")

  run_once <- function() {
    received <- character(0)
    res <- run(graph, state = list(messages = list(user_msg("write hello"))),
               on_token = function(t) { received <<- c(received, t) })
    list(tokens = received, content = tail(res$messages, 1)[[1]]$content)
  }

  first <- run_once()
  expect_identical(first$tokens, c("Hel", "lo"))
  expect_identical(first$content, "Hello")

  second <- run_once()
  expect_identical(second$content, "Hello")
  # the cache hit replays the full cached content as a single token
  expect_identical(second$tokens, "Hello")

  Sys.sleep(0.1)
  expect_identical(count_requests(s), 1L)
})

test_that("provider_cache validates its argument", {
  e <- err_msg(agentgraph::provider_cache("not a provider"))
  expect_false(is.null(e))
  expect_true(grepl("provider configuration", e, fixed = TRUE))
})
