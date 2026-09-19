# Vector stores (hnswlib backend), embeddings, and RAG.
# The mock LLM server serves /embeddings with deterministic hash-based
# vectors, so similarity ordering is assertable without a real model.

mk_store <- function(dim = 4L, ...) {
  agentgraph::create_vector_store(backend = "hnswlib", dim = dim, ...)
}

test_that("hnswlib store round-trips add/search/remove/clear/count", {
  s <- mk_store()
  expect_equal(vector_store_count(s), 0L)

  vector_store_add(s, "a", c(1, 0, 0, 0), metadata = list(tag = "x"), text = "first doc")
  vector_store_add(s, "b", c(0, 1, 0, 0))
  vector_store_add(s, "c", c(0, 0, 1, 0))
  expect_equal(vector_store_count(s), 3L)

  hits <- vector_store_search(s, c(1, 0, 0, 0), k = 2)
  expect_equal(nrow(hits), 2)
  expect_identical(hits$id[1], "a")
  expect_gt(hits$score[1], 0.99)
  expect_identical(hits$text[1], "first doc")
  expect_identical(hits$metadata[[1]]$tag, "x")

  # Upsert by the same id keeps the count stable.
  vector_store_add(s, "a", c(0, 0, 0, 1))
  expect_equal(vector_store_count(s), 3L)
  hits <- vector_store_search(s, c(0, 0, 0, 1), k = 1)
  expect_identical(hits$id[1], "a")

  vector_store_remove(s, "b")
  expect_equal(vector_store_count(s), 2L)
  expect_equal(nrow(vector_store_search(s, c(0, 1, 0, 0), k = 3)), 2L)

  err <- err_msg(vector_store_remove(s, "missing"))
  expect_true(grepl("id not found", err, fixed = TRUE))

  vector_store_clear(s)
  expect_equal(vector_store_count(s), 0L)
  expect_equal(nrow(vector_store_search(s, c(1, 0, 0, 0), k = 3)), 0L)
})

test_that("hnswlib store validates vector dimensions", {
  s <- mk_store(dim = 3L)
  expect_error(vector_store_add(s, "a", c(1, 2)), "dim mismatch")
  expect_error(vector_store_search(s, c(1, 2, 3, 4), k = 1), "dim mismatch")
})

test_that("hnswlib store persists and reloads via a sidecar file", {
  path <- file.path(tempdir(), paste0("ag_idx_", as.integer(Sys.time()), "_",
                                      sample.int(.Machine$integer.max, 1)))
  on.exit(unlink(c(path, paste0(path, ".meta.json")), force = TRUE), add = TRUE)

  s <- mk_store(dim = 4L, path = path)
  vector_store_add(s, "a", c(1, 0, 0, 0), text = "alpha")
  vector_store_add(s, "b", c(0, 1, 0, 0))
  vector_store_save(s)

  s2 <- mk_store(dim = 4L, path = path)
  expect_equal(vector_store_count(s2), 2L)
  hits <- vector_store_search(s2, c(1, 0, 0, 0), k = 1)
  expect_identical(hits$id[1], "a")
  expect_identical(hits$text[1], "alpha")
})

test_that("a corrupt index file degrades to an empty store", {
  path <- file.path(tempdir(), paste0("ag_corrupt_", as.integer(Sys.time()), "_",
                                      sample.int(.Machine$integer.max, 1)))
  on.exit(unlink(c(path, paste0(path, ".meta.json")), force = TRUE), add = TRUE)
  writeBin(charToRaw("this is not an hnswlib index"), path)

  # The constructor used to leave a dangling pointer here.
  s <- mk_store(dim = 4L, path = path)
  expect_equal(vector_store_count(s), 0L)

  # And the store still works after recovering.
  vector_store_add(s, "a", c(1, 0, 0, 0))
  expect_equal(vector_store_count(s), 1L)
})

test_that("embed and embed_batch hit the /embeddings endpoint", {
  testthat::skip_if_not(python_available())
  m <- start_mock_llm(list(list(content = "ok")))
  on.exit(stop_py_mock(m), add = TRUE)
  provider <- mock_provider(m, model = "mock-embed")

  v <- embed("paris france city", provider)
  expect_type(v, "double")
  expect_true(all(is.finite(v)))

  vs <- embed_batch(c("paris france", "cats"), provider)
  expect_length(vs, 2)
  expect_length(vs[[1]], length(v))
  # Same text yields the same deterministic vector.
  expect_equal(embed("paris france", provider), vs[[1]])
})

test_that("rag() retrieves the most similar chunks and answers", {
  testthat::skip_if_not(python_available())
  m <- start_mock_llm(list(list(content = "Paris is the capital of France.")))
  on.exit(stop_py_mock(m), add = TRUE)
  provider <- mock_provider(m)

  store <- mk_store(dim = 64L)
  texts <- c(
    geo   = "Paris France city capital europe",
    pets  = "cats dogs animals pets home"
  )
  vecs <- embed_batch(unname(texts), provider)
  for (i in seq_along(texts)) {
    vector_store_add(store, names(texts)[i], vecs[[i]], text = texts[[i]])
  }

  res <- rag("paris france capital", store, provider, k = 2)
  expect_identical(res$context$id[1], "geo")
  expect_gte(res$context$score[1], res$context$score[2])
  expect_identical(res$answer$content, "Paris is the capital of France.")
})
