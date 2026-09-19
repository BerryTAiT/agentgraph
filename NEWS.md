# agentgraph 0.1.0

## Security hardening

* The native `read_file`/`write_file` tools now honour a process-wide
  filesystem policy: set `AGENTGRAPH_FS_ALLOW` / `AGENTGRAPH_FS_DENY` (or call
  the new `file_tools_policy()` helper) to confine them to specific
  directories. Paths are canonicalized (`..`, symlinks) before the check.
* The isolated tool server now requires a random per-run auth token on every
  request; other processes (local or network) can no longer invoke tool
  handlers on its port.
* `serve_agent()` / `start_sse_server()` compare bearer tokens in constant
  time, rate-limit the authenticated endpoints (120 req/min), and refuse to
  bind a non-loopback interface without an `auth_token` unless
  `allow_unauthenticated = TRUE` is passed explicitly.
* HTTP redirects are now capped at 3 and HTTPS responses never downgrade to
  HTTP (both the WinHTTP and libcurl backends), so credentials and payloads
  can't be leaked by a redirect.
* Prompt-injection detection (`detect_injection()`, `sanitize_untrusted()`,
  `guarded_tool()`) now tolerates extra whitespace/hyphenation between words
  and covers more phrasings. `pii_scrub()`/`provider_pii()` additionally
  redact PEM private-key headers, JWTs, and AWS secret-access-key-shaped
  strings.

## New features

* Graph-based agentic orchestration engine written in C++20, driven from R.
* Concurrent node execution with thread pools, conditional edges, parallel,
  subgraph, router, function, tool, and interrupt nodes.
* LLM providers: OpenAI, Anthropic (OpenAI-compatible), Ollama, Google Gemini,
  Mistral, Groq, Cohere, AWS Bedrock (SigV4), and Azure OpenAI.
* Local models via `provider_local()` and `llama_server()` (llama.cpp's
  OpenAI-compatible `llama-server`), plus LM Studio, vLLM, and Ollama.
* Streaming token output with R callbacks.
* Crash-durable checkpoints: `run()`/`resume()` accept a `checkpoint_path`, with
  `checkpoint_load()` and `checkpoint_resume()` to recover and continue a
  long-running graph after a crash or interruption.
* Structured observability: pass a `log_path` to `run()`, `resume()`, or
  `stream()` to write one JSON object per line (timestamp, event, payload)
  covering every node, LLM call, tool call, and checkpoint.
* Production-grade HTTP behavior: automatic retry with exponential backoff on
  transient failures (429/5xx), token-bucket rate limiting, and persistent
  connection reuse (WinHTTP session reuse on Windows, libcurl connection pool
  elsewhere). All tunable per provider.
* Vector stores and RAG: in-process hnswlib store plus Chroma, Qdrant, and
  Pinecone backends; OpenAI-compatible embeddings; `rag()` end-to-end helper.
* Isolated tool execution: custom R tool handlers run in a separate R process
  over a local TCP protocol so they never block the engine's worker threads.
* Eight pre-built tools: web search (DuckDuckGo), Wikipedia, arXiv, generic HTTP,
  R code execution, CSV reader, PDF extractor, and SQLite query.
* Live console monitoring via `monitor_run()`.
