# Retrieval-Augmented Generation: embed documents into a vector store,
# then answer questions grounded in the retrieved chunks.
library(agentgraph)

provider <- provider_openai(model = "gpt-4o")  # used for embeddings AND chat

# 1. Create a store. "hnswlib" runs in-process; pass `path` to persist it.
store <- create_vector_store(backend = "hnswlib", dim = 1536)

# 2. Embed your documents and add them with their text.
docs <- c(
  "agentgraph runs graph workflows in C++ with an R API.",
  "The executor supports parallel fan-out and subgraphs.",
  "Custom R tools run in an isolated tool-server process.",
  "The interrupt node pauses a graph for human approval."
)
vecs <- embed_batch(docs, provider)
for (i in seq_along(docs)) {
  vector_store_add(store, paste0("doc", i), vecs[[i]], text = docs[i])
}
vector_store_count(store)

# 3. Ask a question — rag() embeds it, retrieves the top chunks, and hands
#    them to the LLM as context.
res <- rag(
  "How does agentgraph run custom R tools safely?",
  store, provider, k = 2
)
res$answer$content       # the grounded answer
res$context              # retrieved chunks: id, score, text, metadata

# REST backends work the same way, e.g. Qdrant:
# store <- create_vector_store(
#   backend = "qdrant", dim = 1536,
#   url = "http://localhost:6333", collection = "docs"
# )
