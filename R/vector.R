#' Embed a single text into a numeric vector
#'
#' Uses an OpenAI-compatible `/embeddings` endpoint through any configured
#' provider (OpenAI, Azure, Ollama, Gemini-compatible, etc.).
#'
#' @param text The text to embed
#' @param provider A provider configuration (e.g. \code{provider_openai()})
#' @return A numeric vector (the embedding)
#' @export
embed <- function(text, provider) {
  embed_cpp(provider = provider, text = as.character(text))
}

#' Embed multiple texts in a single request
#'
#' @param texts Character vector of texts to embed
#' @param provider A provider configuration
#' @return A list of numeric vectors
#' @export
embed_batch <- function(texts, provider) {
  embed_batch_cpp(provider = provider, texts = as.character(texts))
}

#' Create a vector store for RAG
#'
#' @param backend One of "hnswlib" (default, in-process), "chroma", "qdrant",
#'   "pinecone", "faiss", or "pgvector". REST backends need a running server.
#' @param dim Vector dimension (required)
#' @param distance Distance metric: "cosine" (default), "l2", or "ip"
#' @param path For hnswlib: optional file path to persist the index
#' @param M hnswlib max out-degree (default 16)
#' @param ef_construction hnswlib build-time search width (default 200)
#' @param ef_search hnswlib query-time search width (default 50)
#' @param max_elements hnswlib initial capacity (default 10000)
#' @param url REST base URL (chroma/qdrant/pinecone)
#' @param api_key API key (pinecone, or authenticated chroma/qdrant)
#' @param collection Collection / index name (REST backends)
#' @param connection_string PostgreSQL connection string (pgvector)
#' @param table Table name (pgvector)
#' @return An external pointer to the C++ vector store
#' @export
create_vector_store <- function(backend = "hnswlib", dim = NULL,
                                distance = "cosine", path = NULL,
                                M = 16L, ef_construction = 200L,
                                ef_search = 50L, max_elements = 10000L,
                                url = NULL, api_key = NULL, collection = NULL,
                                connection_string = NULL, table = NULL) {
  if (is.null(dim)) stop("create_vector_store(): `dim` is required")
  cfg <- list(
    backend = backend,
    dim = as.integer(dim),
    distance = distance,
    path = if (is.null(path)) "" else path,
    M = as.integer(M),
    ef_construction = as.integer(ef_construction),
    ef_search = as.integer(ef_search),
    max_elements = as.numeric(max_elements),
    url = if (is.null(url)) "" else url,
    api_key = if (is.null(api_key)) "" else api_key,
    collection = if (is.null(collection)) "" else collection,
    connection_string = if (is.null(connection_string)) "" else connection_string,
    table = if (is.null(table)) "" else table
  )
  create_vector_store_cpp(config = cfg)
}

#' Add a vector (with optional text/metadata) to a vector store
#'
#' @param store A vector store from \code{create_vector_store()}
#' @param id Unique string ID for this document chunk
#' @param vector Numeric vector (the embedding)
#' @param metadata Named list of metadata (optional)
#' @param text Optional document text; stored in metadata as "text"
#' @return The store (invisibly)
#' @export
vector_store_add <- function(store, id, vector, metadata = list(), text = NULL) {
  meta <- metadata
  if (!is.null(text)) meta$text <- as.character(text)
  meta_json <- if (length(meta) == 0) "{}" else jsonlite::toJSON(meta, auto_unbox = TRUE)
  vector_store_add_cpp(store = store, id = as.character(id),
                       vec = as.numeric(vector), metadata_json = meta_json)
  invisible(store)
}

#' Search a vector store for the k most similar vectors
#'
#' @param store A vector store from \code{create_vector_store()}
#' @param query Numeric query vector (the embedding)
#' @param k Number of results to return
#' @return A data.frame with columns id, score, text, metadata
#' @export
vector_store_search <- function(store, query, k = 5L) {
  res <- vector_store_search_cpp(store = store, query = as.numeric(query), k = as.integer(k))
  if (length(res) == 0) {
    return(data.frame(id = character(), score = numeric(),
                      text = character(), metadata = I(list())))
  }
  ids <- vapply(res, function(h) h$id %||% "", character(1))
  scores <- vapply(res, function(h) h$score %||% NA_real_, numeric(1))
  texts <- vapply(res, function(h) h$text %||% "", character(1))
  metas <- lapply(res, function(h) {
    jsonlite::fromJSON(h$metadata, simplifyVector = FALSE)
  })
  data.frame(id = ids, score = scores, text = texts,
             metadata = I(metas), stringsAsFactors = FALSE)
}

#' Count vectors in a store
#'
#' @param store A vector store
#' @return Number of stored vectors
#' @export
vector_store_count <- function(store) {
  vector_store_count_cpp(store = store)
}

#' Remove a vector by ID
#'
#' @param store A vector store
#' @param id The ID to remove
#' @return The store (invisibly)
#' @export
vector_store_remove <- function(store, id) {
  vector_store_remove_cpp(store = store, id = as.character(id))
  invisible(store)
}

#' Remove all vectors from a store
#'
#' @param store A vector store
#' @return The store (invisibly)
#' @export
vector_store_clear <- function(store) {
  vector_store_clear_cpp(store = store)
  invisible(store)
}

#' Persist an hnswlib-backed store to disk
#'
#' @param store An hnswlib vector store
#' @return The store (invisibly)
#' @export
vector_store_save <- function(store) {
  vector_store_save_cpp(store = store)
  invisible(store)
}

#' Load an hnswlib-backed store from disk
#'
#' @param store An hnswlib vector store (created with the same path/dim)
#' @return The store (invisibly)
#' @export
vector_store_load <- function(store) {
  vector_store_load_cpp(store = store)
  invisible(store)
}

#' Retrieval-Augmented Generation (RAG)
#'
#' Embeds the query, retrieves the k most similar chunks from the store, and
#' asks the LLM to answer using those chunks as context.
#'
#' @param query The user's question
#' @param store A vector store containing embedded document chunks
#' @param provider A provider configuration (used for both embedding and chat)
#' @param system_prompt System prompt; retrieved context is appended to it
#' @param k Number of chunks to retrieve
#' @return A list with \code{answer} (LLM response) and \code{context}
#'   (data.frame of retrieved chunks)
#' @export
rag <- function(query, store, provider, system_prompt = "", k = 5L) {
  qv <- embed(query, provider)
  hits <- vector_store_search(store, qv, k = k)

  if (nrow(hits) == 0) {
    warning("rag(): no chunks found in the vector store")
    context_text <- ""
  } else {
    context_text <- paste0(
      paste0("[Chunk ", seq_len(nrow(hits)), "]\n", hits$text, collapse = "\n\n")
    )
  }

  prompt <- system_prompt
  if (nzchar(context_text)) {
    prompt <- paste0(
      system_prompt,
      if (nzchar(system_prompt)) "\n\n" else "",
      "Use the following retrieved context to answer the user's question.\n\n",
      context_text
    )
  }

  answer <- chat(message = query, provider = provider, system_prompt = prompt)
  list(answer = answer, context = hits)
}

`%||%` <- function(a, b) if (is.null(a)) b else a
