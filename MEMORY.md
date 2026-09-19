# Project Memory — agentgraph

> Read this FIRST before starting any new work. It records what is done and what is pending,
> so we never redo finished tasks. Update it whenever a task is completed.

## ⚠ Standing rule — never lose work to context compaction / NO COMPACTION
Conversation context gets compacted automatically and **cannot be disabled**. The user has
explicitly requested NO COMPACTION and to always rely on this file. This file is the only durable
memory. Therefore, at EVERY meaningful step (before ending a turn, after any file edit, after any
milestone), update this file with what was done and what remains. When a session is resumed after
compaction, re-read this file FIRST and continue from its "pending" section instead of re-reading
every source file from scratch. Treat "the summary is compacted" as a non-issue because the full
state lives here. NEVER redo work that this file marks DONE.

## What this project is
`agentgraph` is an R package over a C++20 agentic-orchestration engine.
- R is the primary (natural) API; C++ does the heavy lifting (concurrency, state, HTTP, tool calling).
- R <-> C++ bridge = Rcpp `.Call` (`src/RcppExports.cpp`, generated from `// [[Rcpp::export]]` tags).
- Error handling = `Result<T>` / `Result<void>` in `src/core/errors.hpp`.
- JSON = `nlohmann::json` aliased as `agentgraph::json`.

## Status overview (DONE unless marked PENDING)

### Core engine — DONE
`src/core/`, `src/graph/`: `GraphState`, `Executor`, `NodeRunner`, `ToolRegistry`, `Router`,
thread pools, interruption/resume, conditional/parallel/subgraph nodes, tool calling.

### LLM providers — DONE
`src/llm/llm_client.cpp`, `R/providers.R`: OpenAI, Anthropic, Ollama, Google Gemini, Mistral,
Groq, Cohere, AWS Bedrock (SigV4), Azure OpenAI. OpenAI-compatible fallback in factory.

### HTTP — DONE
`src/llm/http_client.cpp`: WinHTTP on Windows, libcurl on Linux/macOS. Methods `post`, `get`,
`post_stream`. Stream parsing in `sse_parser.cpp`.

### HTTP reliability (retry/backoff/rate-limit/pooling) — DONE
- `src/llm/http_client.cpp` `perform_with_retry()`: retries transient failures (429/5xx + network)
  with exponential backoff (`backoff_delay_ms`). `is_retryable_status` covers 429/500/502/503/504.
- `src/llm/rate_limiter.hpp`: thread-safe token bucket, `rate` = permits/minute (0 disables);
  `acquire()` sleeps on a condition variable. Wired via `HttpClient::set_rate_limit()`.
- Connection pooling: `CurlPool` + `pool_acquire/pool_release` reuse libcurl handles by host key
  (Unix). Windows uses WinHTTP session/handle reuse.
- `src/llm/llm_client.cpp`: wires `ProviderConfig.{max_retries,retry_base_delay_ms,retry_max_delay_ms,requests_per_minute}`
  into the shared HTTP transport so every LLM call is automatically retried + throttled.
- `src/core/config.hpp`: `ProviderConfig` fields `max_retries=3`, `retry_base_delay_ms=500`,
  `retry_max_delay_ms=8000`, `requests_per_minute=0`.
- `R/providers.R`: all 9 provider constructors expose `max_retries`, `retry_base_delay_ms`,
  `retry_max_delay_ms`, `requests_per_minute` (coerced with `as.integer()`).

### Observability / tracing — DONE
- `R/run.R` `run()`/`resume()`/`stream()` accept `log_path`. When set, every engine event
  (node_start/node_end/llm_start/llm_end/tool_call/tool_result/iteration/parallel_*/interrupt/
  checkpoint/complete) is appended as one JSON line.
- `src/rcpp_exports.cpp` has a dependency-free `TraceLogger` (writes `{ts_ms, event, data}` JSONL)
  and wires it into the event callback. (Deliberately NOT spdlog: a tiny JSONL logger avoids a
  heavy logging dependency and is directly consumable by LangSmith-style tooling.)
- `on_event` R callback still works and is additionally mirrored to the trace file.

### Local models (llama.cpp / OpenAI-compatible servers) — DONE
- `R/local.R` adds `provider_local()` (an OpenAI-compatible provider pointed at any local
  llama.cpp / LM Studio / vLLM / Ollama `/v1` endpoint), `llama_server()` (launches `llama-server`
  and waits for "listening"), and `llama_server_stop()` (safe no-op on NULL).
- No C++ rebuild needed: `create_llm_client()` always returns the OpenAI-compatible client, so
  `name = "openai"` + a custom `base_url` runs local models offline with no API key.

### CRAN submission prep — DONE
- `NEWS.md` created (0.1.0 feature list).
- `.Rbuildignore` already excludes `^src/.*\.dll$`; `.gitignore` excludes the compiled DLL.
- `DESCRIPTION` Suggests: curl, DBI, RSQLite, pdftools, shiny (Imports: Rcpp, jsonlite, processx).
- `R CMD check --no-manual` now passes with **Status: OK** (0 ERROR / 0 WARNING / 0 NOTE).
- Fixed during check pass: (1) hnswlib `-Wreorder` install warning in `inst/include/hnswlib/hnswalg.h`
  by reordering the ctor member-init list to match declaration order; (2) `setNames`/`tail`
  "no visible global function" NOTE by adding `importFrom(stats,setNames)` and
  `importFrom(utils,tail)` to `NAMESPACE` + `R/agentgraph-package.R` roxygen tags.
- Remaining (optional, non-blocking): build/check the PDF manual (needs LaTeX), and the
  one-time CRAN network index fetch (blocked only by this sandbox's offline CRAN mirror).

### Tools — DONE
`src/tools/`: native tool calling, builtin tools, RPC tool client/server (`R/tool_server.R`).

### Multimodal support — IMAGE DONE, VIDEO DONE, AUDIO DONE, RESPONSES FILE_ID DONE
Goal (user): the framework must handle all model types, not just text. User mandated
step-by-step delivery: IMAGE first (report + stop), then VIDEO (report + stop), then AUDIO
(report + stop), then RESPONSES-API `file_id` references. ALL are now implemented.

IMAGE / vision input — DONE:
- `src/core/types.hpp`: added `ImageUrl { url, detail }`, `ContentPart { type, text, image_url }`,
  free `content_to_string(const json&)` (collapses a response content array to plain text), and a
  `std::vector<ContentPart> parts` member on `Message`. `Message::to_json` emits `parts` when
  non-empty, else `content`; `from_json` parses array vs string.
- `src/llm/llm_client.cpp`: `build_request` emits the OpenAI vision parts array
  (`{"type":"text","text":...}` / `{"type":"image_url","image_url":{"url":...,"detail":...}}`) when
  `parts` is non-empty; `parse_response` uses `content_to_string` so array responses collapse to text.
- `src/rcpp_exports.cpp`: `parse_llm_response_cpp` uses `content_to_string` (handles array content).
- `src/type_converters.cpp`: `message_from_list` detects `STRSXP` (string content) vs `VECSXP`
  (parts list, parsing `type`/`text`/`image_url.url`/`image_url.detail`); `message_to_list` emits a
  parts list when present, else the string.
- `R/state.R`: added helpers `text_part(text)`, `image_part(url, detail=NULL)`, `content_parts(...)`.
- `NAMESPACE`: exports `text_part`, `image_part`, `content_parts`.
- Tests: `tests/testthat/test-25-vision.R` (parts-array wire format, detail omission, array response
  parsing, graph-state round-trip). ALL PASS along with test-14 and test-17 regression.

VIDEO / video input — DONE:
- `src/core/types.hpp`: added `VideoUrl { url }` and a `video_url` field on `ContentPart`;
  `ContentPart::to_json`/`from_json` now handle the `"video_url"` part type (wire form
  `{"type":"video_url","video_url":{"url":...}}`, matching vLLM / NVIDIA NIM / Qwen-VL OpenAI-compat).
- `src/type_converters.cpp`: `message_from_list` parses `video_url.url`; `message_to_list` emits it.
- `R/state.R`: added `video_part(url)` helper.
- `NAMESPACE`: exports `video_part`.
- Tests: `tests/testthat/test-26-video.R` (video_url wire format, graph-state round-trip).
  ALL PASS along with test-25/test-14/test-17 regression.

AUDIO — DONE:
- `src/core/types.hpp`: added `InputAudio { data, format }` and an `input_audio` field on `ContentPart`;
  `ContentPart::to_json`/`from_json` handle `{"type":"input_audio","input_audio":{"data":"<base64>","format":"wav"}}`.
- `src/type_converters.cpp`: `message_from_list` parses `input_audio.data`/`input_audio.format`; `message_to_list` emits it.
- `R/state.R`: added `audio_part(data, format="wav")` helper.
- `NAMESPACE`: exports `audio_part`.
- Tests: added `tests/testthat/test-27-audio.R` (input_audio wire format, graph-state round-trip). ALL PASS along with image/video regression.

RESPONSES API `file_id` (input_video / input_audio) — DONE:
- `src/core/types.hpp`: extended `InputAudio { data, format, file_id }` (file_id is empty for inline
  form); added `InputVideo { file_id }` and a `input_video` field on `ContentPart`. `to_json` emits
  flat `{"type":"input_audio","file_id":...}` when `file_id` is non-empty (else nested inline
  `{"input_audio":{data,format}}`), and flat `{"type":"input_video","file_id":...}`; `from_json`
  parses `input_audio`/`input_video` plus a flat part-level `file_id` routed by `type`.
- `src/type_converters.cpp`: `message_from_list` parses `input_audio.file_id` (nested or flat),
  `input_video.file_id`, and flat part-level `file_id`; `message_to_list` emits flat `file_id` for
  `input_audio` (when file_id non-empty) and `input_video`, else nested inline `input_audio`.
- `R/state.R`: added `video_file_part(file_id)` -> `{type:"input_video", file_id}` and
  `audio_file_part(file_id)` -> `{type:"input_audio", file_id}`.
- `NAMESPACE`: exports `video_file_part`, `audio_file_part`.
- Tests: `tests/testthat/test-28-responses-files.R` (flat wire format, graph-state round-trip, inline
  vs file_id audio coexistence). ALL PASS along with test-14/17/25/26/27 regression.

RESPONSES API `input_image` file_id — DONE:
- `src/core/types.hpp`: added `InputImage { file_id }` struct (with `to_json`/`from_json`) and an
  `input_image` field on `ContentPart`; `to_json` emits flat `{"type":"input_image","file_id":...}`,
  `from_json` parses `input_image` plus a flat part-level `file_id` routed by `type`.
- `src/type_converters.cpp`: `message_from_list` parses `input_image.file_id` (nested or flat);
  `message_to_list` emits flat `file_id` for `input_image`.
- `R/state.R`: added `image_file_part(file_id)` -> `{type:"input_image", file_id}`.
- `NAMESPACE`: exports `image_file_part`.
- Tests: `tests/testthat/test-29-input-image-file.R` (flat wire format, graph-state round-trip,
  image_url + input_image coexistence). ALL PASS along with test-14/17/25/26/27/28 regression.

### Console monitoring — DONE
`R/monitor.R`: `monitor_run()` live console view.

### UI helpers — DONE
`R/ui-helpers.R`.

### Vector stores / RAG — DONE
Full implementation exists:
- `src/vector/vector_store.hpp` — `VectorStoreConfig`, abstract `VectorStore` interface
  (`add`/`search`/`remove`/`clear`/`count`), `SearchHit`, backend enum.
- `src/vector/hnsw_store.hpp/.cpp` — hnswlib-backed in-process store. Cosine = L2-normalize
  vectors + `InnerProductSpace` (hnswlib has NO `CosineSpace`).
- `src/vector/rest_stores.hpp/.cpp` — Chroma, Qdrant, Pinecone via existing `HttpClient`.
- `src/vector/embedding_client.hpp/.cpp` — OpenAI-compatible `/embeddings`.
- `src/vector/vector_store_factory.cpp` — factory. FAISS and pgvector are COMPILE-GATED:
  they throw `runtime_error` unless built with `AGENTGRAPH_ENABLE_FAISS`/`AGENTGRAPH_ENABLE_PGVECTOR`.
- `src/vector_rcpp.cpp` — Rcpp exports (embed, embed_batch, create_vector_store,
  add/search/remove/clear/count/save/load). NOTE: this file lives in `src/` (NOT `src/vector/`)
  so `Rcpp::compileAttributes()` discovers it; `create_vector_store_cpp()` returns `SEXP` (not
  `Rcpp::XPtr<VectorStore>`) to keep `VectorStore` out of the generated wrapper.
- `R/vector.R` — R API: `embed()`, `embed_batch()`, `create_vector_store()`,
  `vector_store_add/search/count/remove/clear/save/load()`, `rag()`.
- hnswlib v0.7.0 vendored at `inst/include/hnswlib/`.
- `src/Makevars` and `src/Makevars.win` already list all vector sources.
- `src/RcppExports.cpp` and `R/RcppExports.R` regenerated and now expose all vector functions
  (`embed_cpp`, `embed_batch_cpp`, `create_vector_store_cpp`, `vector_store_*_cpp`).
- `src/agentgraph.dll` already compiled (Windows).

### Pre-built tools — DONE
`R/prebuilt.R` adds 8 ready-made R tool constructors (no C++ rebuild needed). Each returns a
`tool()` object whose handler runs in the isolated tool-server process:
- `tool_web_search()` — DuckDuckGo Instant Answer API (no key).
- `tool_wikipedia()` — Wikipedia search (titles + extracts).
- `tool_arxiv()` — arXiv API search (Atom XML parsed with regex).
- `tool_http_request()` — generic GET/POST/PUT/DELETE via curl.
- `tool_code_exec()` — evaluate R in an isolated process, capture output/errors.
- `tool_read_csv(max_rows)` — CSV loader/preview.
- `tool_read_pdf()` — PDF text extraction (requires pdftools).
- `tool_sql(db_path)` — SQLite queries (requires DBI + RSQLite).
Handlers are self-contained (base R + `pkg::fun` only) so they survive saveRDS/readRDS
into the tool server. `curl` was already a Suggests; `DBI`/`RSQLite`/`pdftools` added to
Suggests. All 8 exported in `NAMESPACE`, documented in `man/`, with an example
(`examples/10_prebuilt_tools.R`) and tests (`tests/testthat/test-22-prebuilt.R`).

### Crash-durable checkpoints — DONE
Goal: state/checkpoints that survive crashes (not just in-memory interrupt/resume).
Design: pass a `checkpoint_path` from R into C++; save `GraphState::to_json()` + a `resume_node`
marker after every node and on interrupt, with atomic file writes; `checkpoint_load()` /
`checkpoint_resume()` recover and continue. (Uses atomic JSON files, not SQLite, for zero-dependency
simplicity; the GraphState JSON serialization already provides the durable-state primitive.)

DONE:
- `src/graph/executor.hpp/.cpp`: `CheckpointCallback` type, new constructor param, `on_checkpoint_`
  member; `run_impl()` `save_checkpoint` lambda fires (a) on interrupt nodes, (b) when a subgraph
  pauses on an inner interrupt, and (c) after each normal node with the resolved `next` node.
  Emits `on_event("checkpoint", {resume_node})`.
- `src/rcpp_exports.cpp`: `atomic_write_file()` (temp + `MoveFileExA` on Windows / `rename`
  elsewhere), `write_checkpoint()` (JSON `{version, resume_node, state}`), `checkpoint_load_cpp()`
  (returns `state` + `resume_node`), and `run_graph_cpp()` now accepts `checkpoint_path`/`log_path`
  and wires the callback to `Executor`.
- `R/run.R`: `run()`/`resume()`/`stream()` accept `checkpoint_path` + `log_path`; exports
  `checkpoint_load()` and `checkpoint_resume()`. `checkpoint_resume()` clears the in-memory
  `__interrupted__`/`__resume_node__` markers before re-injecting state, and coerces `log_path`
  NULL -> "" (required because `run_graph_cpp` takes a non-nullable `std::string`).
- `NAMESPACE` + `man/*.Rd` regenerated for `checkpoint_load`/`checkpoint_resume` (and local fns).
- Tests: `tests/testthat/test-23-checkpoint.R` (interrupt -> resume -> complete, trace file check,
  missing-file error) and `tests/testthat/test-24-local.R` (provider_local, llama_server error,
  llama_server_stop NULL no-op). BOTH PASS.

Fixed this session: `checkpoint_resume()` failed with `Expecting a single string value:
[type=NULL; extent=0]` because `log_path` (default NULL) was passed straight to a non-nullable
`std::string` Rcpp arg. Fixed by coercing `log_path` to `""` at the top of `checkpoint_resume()`.

### Context-window memory management — DONE
Goal (user): prevent a long conversation from overflowing the model's context limit by adding
three memory primitives, applied before every LLM call:
- **Window buffer**: only send the last N messages to the LLM.
- **Summary memory**: compress evicted messages into a running summary automatically.
- **Entity memory**: track named facts (user name, preferences) across turns.

DONE:
- `src/core/config.hpp`: added `MemoryConfig { window_size=0, summarize=false,
  entity_memory=false, summary_system_prompt }` and a `memory` member on `NodeConfig`.
  All defaults are backward-compatible (windowing/summarization/entity off by default).
- `src/type_converters.cpp` `node_from_list`: parses an R `memory` list into `MemoryConfig`.
- `R/nodes.R` `llm_node()`: new args `window_size=0L`, `summarize=FALSE`, `entity_memory=FALSE`,
  `summary_system_prompt=""`, packaged into a `memory` list. Roxygen header updated.
- `man/llm_node.Rd`: updated to document the four new arguments (manual edit matching roxygen).
- `src/graph/node_runner.cpp` `run_llm_node`: the integration point. Before each LLM call it
  (a) evicts older messages when `window_size > 0`, (b) when `summarize` is on, calls the LLM to
  compress evicted messages into a running summary stored in `state["conversation_summary"]` and
  injected as a leading system message, and (c) when `entity_memory` is on, injects known facts
  from `state["entities"]` as a leading system message and, after the call, extracts new facts
  into `state["entities"]`. Summarization/entity extraction are **non-fatal**: an LLM failure
  preserves the previous summary/facts.
- Tests: `tests/testthat/test-05-memory.R` (4 tests / 14 assertions) covering window buffer,
  summary memory, entity extraction, and entity injection, using the mock LLM server.
  Memory-only run PASSES; full suite PASSES (only pre-existing live DeepSeek test skipped,
  `AGENTGRAPH_API_KEY` not set).

### Provider fallback chain — DONE
Goal (user): if the primary provider is down, transparently fail over to the next provider
(e.g. `provider_fallback(provider_openai(gpt-4o), provider_anthropic(claude-sonnet-4-6),
provider_local("models/mistral.gguf"))`). Retry already exists on a single provider; this adds
cross-provider failover for hard failures.

DONE:
- `src/core/config.hpp`: `ProviderConfig` gained `std::vector<ProviderConfig> fallbacks;`. When
  non-empty, the config represents a fallback chain (entry 0 = primary). Normal providers keep an
  empty `fallbacks`, so the old code path is fully backward-compatible.
- `src/type_converters.cpp` `provider_from_list`: parses an R `fallbacks` list recursively via
  `list_has(l, "fallbacks")` -> `provider_from_list(pl)` for each entry.
- `src/llm/llm_client.hpp`: declared `FallbackClient : public LLMClient` holding
  `std::vector<std::unique_ptr<LLMClient>> chain_`, and rewrote the `create_llm_client()` factory
  to build a `FallbackClient` recursively when `config.fallbacks` is non-empty, else the normal
  `OpenAIClient`.
- `src/llm/llm_client.cpp`: implemented `FallbackClient` `complete()`/`complete_stream()`. Each
  tries providers in order; returns the first `Result::ok`; catches `std::exception` and `...`;
  on total failure returns `err("all fallback providers failed: " + last_error)`.
- `R/providers.R`: added `provider_fallback(...)` (pure R). Validates >= 2 providers and that each
  is a list with a `name`. Returns `list(name="fallback", model=<primary model or "fallback">,
  fallbacks=providers)`.
- `NAMESPACE`: exported `provider_fallback`. `man/provider_fallback.Rd` created.
- Both integration points use the factory, so fallback applies automatically inside graph
  `run_llm_node` (LLM nodes) AND the standalone `chat_native_cpp`/`chat_parallel_cpp` helpers.
- Tests: `tests/testthat/test-30-fallback.R` (5 tests / 13 assertions): hard-failover to backup,
  primary short-circuit, combined error, fallback inside a graph node, and argument validation.
  ALL PASS; full suite 515 PASS / 0 FAIL / 1 SKIP (live DeepSeek, key not set).

Test-infra fix required this session (Windows only): the Python mock servers
(`tests/testthat/mock/{mock_llm_server,error_mock,latent_mock,stream_mock}.py`) were built on
`ThreadingHTTPServer`, whose `allow_reuse_address = True` (SO_REUSEADDR) lets two processes bind
the same port on Windows. Running a primary + backup mock simultaneously made BOTH bind port
18300, so the "backup" silently hit the primary and the fallback tests failed. Fixed by adding a
`SingleBindServer(ThreadingHTTPServer)` subclass with `allow_reuse_address = False` in all four
mock scripts and switching the bind loop to it. Reverted nothing in production code — the source
implementation was correct; the bug was only in the test harness.

### LLM exact cache — DONE
Goal (user): cache identical LLM completions in-memory so a repeated request (same provider, model,
system prompt, temperature, max_tokens, messages, tools) is served without a network call. Semantic
caching is intentionally deferred (will reuse the existing hnswlib vector store later).

DONE:
- `src/core/config.hpp`: `ProviderConfig` gained `int cache_ttl_seconds = 0` and
  `int cache_max_entries = 0`. When `cache_ttl_seconds > 0` the cache is enabled; defaults keep the
  old (uncached) path fully backward-compatible.
- `src/llm/llm_cache.hpp/.cpp`: thread-safe `LLMCache` (get/put/size/clear) + `LLMCacheRegistry`
  singleton (process-global, `std::mutex` + `std::unordered_map`). Entries carry a
  `steady_clock::time_point created_at`; `ttl_seconds <= 0` means never expire. Eviction purges
  expired entries and enforces `max_entries` (LRU by insertion). `snapshot()` returns
  `<namespace, entries>` pairs.
- `src/llm/llm_client.hpp`: declared `CachedLLMClient : public LLMClient` (wraps an inner client,
  holds `ProviderConfig` + namespace + `shared_ptr<LLMCache>`), and rewired the factory into two
  layers: `create_uncached_client(config)` (builds a `FallbackClient` chain if `fallbacks` is
  non-empty, else a plain `OpenAIClient`) and `create_llm_client(config)` (wraps the result in a
  `CachedLLMClient` when `cache_ttl_seconds > 0`). This is THE single integration point, so caching
  applies to graph LLM nodes, `chat_native_cpp`, and `chat_parallel_cpp` uniformly.
- `src/llm/llm_client.cpp`: implemented `CachedLLMClient`. Cache namespace =
  `name|base_url|model|api_version`. Cache key JSON = `{provider, base_url, model, api_version,
  max_tokens, temperature, system_prompt, messages, tools}` (via ADL `to_json`). `complete()` hits
  -> cached result; miss -> delegate, store the successful result, return. `complete_stream()` hit
  -> replay the full cached content as a single token (if non-empty); miss -> delegate and store
  the successful final response. Crucially, the cache wraps the WHOLE (possibly fallback) chain, not
  each fallback hop.
- `src/Makevars` + `src/Makevars.win`: SOURCES now include `llm/llm_cache.cpp`.
- `src/rcpp_exports.cpp`: added `cache_clear_cpp(ns="")` (empty ns -> clear all) and
  `cache_stats_cpp()` -> DataFrame(namespace, entries). Regenerated `src/RcppExports.cpp` /
  `R/RcppExports.R` / `NAMESPACE`.
- `R/providers.R`: `provider_cache(provider, ttl_seconds=300, max_entries=1000)` validates a
  provider list and sets `cache_ttl_seconds`/`cache_max_entries`; `cache_clear(namespace="")` ->
  `invisible(cache_clear_cpp(namespace))`; `cache_stats()` -> `cache_stats_cpp()`.
- `man/`: generated `provider_cache.Rd`, `cache_clear.Rd`, `cache_stats.Rd`; NAMESPACE exports all
  three.
- Tests: `tests/testthat/test-31-cache.R` (9 tests / 32 assertions): identical-request cache hit,
  different-message miss, system prompt/temperature/max_tokens in key, `cache_stats` entries,
  `cache_clear` re-fetch, TTL expiry, fallback-chain wrap, stream replay, and argument validation.
  ALL PASS; full suite PASS (1 gated live DeepSeek test skipped, `AGENTGRAPH_API_KEY` not set).

Test-infra note (Windows, no production change): the process-global cache namespace includes
`base_url` (which embeds the port), and all mock servers bind the same sequential port range
(starting 18300). So tests must pass distinct model names (`m1`..`m8`) — model is part of the
namespace — to avoid cross-test cache leakage. The C++ cache design itself is correct; only the
test fixtures needed unique namespaces.

### Prebuilt agent patterns — DONE
Goal (user): expose ready-made agent patterns (chat, ReAct, plan-and-execute, reflection, router)
composed from the existing graph/node/tool primitives, with a single `run_agent()` entry point.
Pure R — no C++ changes, only roxygenise + reinstall.

DONE:
- `R/agents.R` (new module) exports six constructors plus the runner:
  - `chat_agent(provider, system_prompt="")` — single LLM node `"agent"`, no tools.
  - `react_agent(provider, tools=list(), system_prompt="", max_iterations=25L)` — ReAct loop:
    `"agent"` (llm_node with tool names) -> conditional `route_on("has_tool_calls",
    c("true"="tools","false"="__end__"))` -> `"tools"` (tool_node) -> `"agent"`. Validates each
    tool has a non-empty `name`.
  - `plan_execute_agent(provider, system_prompt="", executor_system_prompt="")` —
    `"planner"` -> `"executor"` -> `"__end__"`; supplies default planner/executor prompts when empty.
  - `reflection_agent(provider, rounds=1L, system_prompt="", critic_system_prompt="",
    reviser_system_prompt="")` — `"draft"` then, for each round, dynamic nodes `critic_i` ->
    `revise_i`; validates `rounds >= 1`.
  - `router_agent(provider, routes, system_prompt="", default=NULL)` — R-level orchestrator (no
    graph); validates `routes` is a named list of agents; carries an R `run_fn` that classifies the
    input via standalone `chat()`, then dispatches `run_agent()` on the matched sub-agent (or
    `default`, or errors `"unknown route"`).
  - `run_agent(agent, input, ...)` — the single callable entry point. Validates `is_agent()`;
    calls `agent$run_fn(input, ...)` for routers, else `run(agent$graph, state=list(messages=
    list(user_msg(input))), tools=agent$tools, ...)` and returns `list(answer=final_answer(state),
    state=state)`.
- Agent object: internal `new_agent(graph, tools, run_fn, description)` -> class
  `"agentgraph_agent"`; `is_agent(x)` and `final_answer(state)` (last non-empty assistant message)
  are internal helpers. All graph-based agents share this shape so `run_agent()` is uniform.
- `NAMESPACE`: exports `chat_agent`, `react_agent`, `plan_execute_agent`, `reflection_agent`,
  `router_agent`, `run_agent`. Six new `man/*.Rd` generated.
- Tests: `tests/testthat/test-32-agents.R` (10 tests / 25 assertions) using the mock LLM server:
  chat answer, ReAct tool loop, tool validation, plan-execute chain, reflection single + multi round,
  router dispatch / fallback / unknown-route error, and `run_agent` argument validation.
  ALL PASS; full suite PASS (1 gated live DeepSeek test skipped, `AGENTGRAPH_API_KEY` not set).

Build note: no DLL rebuild was required (pure R). `regen.R` ran `Rcpp::compileAttributes()` +
`roxygen2::roxygenise()` and emitted non-fatal unresolved-topic warnings for the new cross-refs;
NAMESPACE/man were still written and `R CMD INSTALL --preclean` succeeded (`* DONE (agentgraph)`).

### Evaluation framework — DONE
Goal (user): run an agent (or any answer-producing function) over a dataset of examples and
score every answer with pluggable evaluators, LangSmith-style. Pure R (no C++ changes); LLM/embedding
evaluators go through the existing `chat()` / `embed()` and are testable against the Python mocks.

DONE:
- `R/eval.R` (new module). Exports:
  - `eval_dataset(input, expected = NULL)` — character vectors; `expected` "" or NA = no reference;
    errors on empty input, empty strings, or length mismatch (NO silent recycling — removed after a
    test caught the contradiction with the documented same-length contract).
  - Evaluators (each returns class `agentgraph_evaluator`, list(name, fn(prediction, example) ->
    list(score in [0,1], passed, reason)); `example` carries `input` + `expected`):
    - `eval_exact_match(case_sensitive = TRUE, trim = TRUE)` — needs expected.
    - `eval_contains(needles, all = TRUE, case_sensitive = FALSE)` — fixed substrings; score = fraction
      of needles found; `all = FALSE` means any one suffices.
    - `eval_regex(pattern, ignore_case = FALSE)` — pattern applied to the PREDICTION.
    - `eval_numeric(tolerance = 1e-6)` — extracts every number from expected + prediction; passes when
      each expected number appears in the prediction within tolerance.
    - `eval_llm_judge(provider, criteria = "", system_prompt = "")` — judges via standalone `chat()`;
      reply parsed as PASS / FAIL keyword (substring match, case-insensitive) -> 1/0; else a numeric
      in [0,1] -> fractional score; else score 0 with reason "unrecognized judge reply". Judge-call
      failures return score 0 with the error as reason (sentinel field `.judge_error`, never confused
      with a real response).
    - `eval_semantic(provider, threshold = 0.8)` — embeds prediction + expected via `embed()` and
      compares by cosine similarity; score = clamped similarity, reason reports the value.
    - `eval_custom(name, fn)` — fn may return a number in [0,1], a logical, or list(score, passed?,
      reason?); other return shapes error.
  - `evaluate(target, dataset, evaluators = list(), ...)` — the runner. `target` = agent (run through
    `run_agent()`; answer extracted) or a function(input, ...) returning a string / list with $answer.
    `dataset` = eval_dataset() | data.frame with `input` (+ optional `expected`) | character vector.
    Runs examples sequentially; records answer, error, elapsed per example; per-evaluator score
    columns + row-wise `passed` in `results` data frame; `summary` data frame (evaluator, mean_score,
    pass_rate via a passed matrix — per-evaluator pass flags are stored separately because pass can
    differ from score >= 0.5, e.g. contains with all = TRUE); `details[[i]][[ev]]` = reasons;
    `passed` = overall. Errors in the TARGET or in an EVALUATOR are contained per example (score 0,
    passed FALSE, message recorded) — the run always completes. Validates: evaluator objects, unique
    names, names not in the reserved set (i/input/expected/answer/error/elapsed/passed), target type,
    dataset shape.
  - `print.agentgraph_eval()` — S3 method (registered via `S3method(print, agentgraph_eval)`).
- `NAMESPACE`: exports `eval_dataset`, `eval_exact_match`, `eval_contains`, `eval_regex`,
  `eval_numeric`, `eval_llm_judge`, `eval_semantic`, `eval_custom`, `evaluate`, +
  `S3method(print,agentgraph_eval)`. Ten new `man/*.Rd` generated.
- Tests: `tests/testthat/test-33-eval.R` (15 tests / 61 assertions): dataset build/validation,
  exact-match scoring + summary math, character-vector dataset coercion, agent target with contains
  (mock), numeric extraction + tolerance, regex, judge PASS/FAIL/fractional/junk replies (4 mocks),
  semantic identical vs disjoint strings (mock /embeddings), custom numeric/logical/list forms,
  evaluator error containment, target error containment, input validation, print output.
  ALL PASS; full suite PASS (1 gated live DeepSeek test skipped, `AGENTGRAPH_API_KEY` not set).

Fixes made during validation: (1) removed the `expected`-length-1 silent recycle in eval_dataset;
(2) rewrote the runner's tryCatch to use an `err <<- ` sentinel (a returned error string was
indistinguishable from a valid answer) and a `passed_mat` matrix for true per-evaluator pass rates
(previously derived from score >= 0.5, wrong for `eval_contains(all = TRUE)`).

Test note: `eval_llm_judge` uses four simultaneously running mocks (ports 18300+), which works
because the mocks use `SingleBindServer` (distinct ports). Mock /embeddings ignores the chat
scenario order, so `eval_semantic` works with a single canned response.

### Prompt management — DONE
Goal (user): prompt templates with `{variable}` placeholders, file persistence, and a
directory-backed registry — LangChain PromptTemplate-style. Templates render to plain strings so
they plug into `llm_node(system_prompt=)`, `chat()`, and `*_agent()` constructors. Pure R.

DONE:
- `R/prompts.R` (new module). Exports:
  - `prompt_template(text, name = "", version = "", role = "system")` — class
    `agentgraph_prompt`; validates single non-empty string, role in {system,user,assistant}.
  - `prompt_variables(prompt)` — unique `{name}` placeholders in first-appearance order. Only
    identifier-like names (letters/digits/underscore/dot, not starting with a digit) count;
    `{1abc}`, `{}`, `{a-b}` stay literal.
  - `render_prompt(prompt, ..., vars = list())` — accepts a template or a raw string. `...` are
    named vars (take precedence over `vars`); extra vars ignored; ALL missing names reported at
    once; values must be single non-NA scalars. Substitution is done positionally via
    `regmatches(x, gregexpr(...)) <- list(vals)` — values are inserted VERBATIM (braces, `$`,
    `\1`, `[` pass through; no regex/backreference interpretation, no re-expansion of
    placeholder-looking values).
  - `prompt_message(prompt, ..., vars = list())` — renders and wraps as `list(role, content)`
    using the template's role (raw strings default to "user"); drop-in message for
    `run(state = list(messages = ...))`.
  - `prompt_file(path, name = NULL, version = "", role = "system")` — joins file lines with
    "\n"; name defaults to filename sans extension. `save_prompt(prompt, path)` writes the
    template TEXT only (creates parent dirs); round-trips via prompt_file.
  - `prompt_registry(path = NULL)` — named list of templates, class
    `agentgraph_prompt_registry`, `dir` attribute remembers the source dir; loads every
    `.txt`/`.md` file from `path`. `add_prompt(registry, prompt)` — functional (returns new
    registry, requires prompt `name`). `save_registry(registry, path = NULL)` — writes each
    prompt to `<path>/<name>.txt`, defaulting to the registry's own dir. Prompts accessed via
    `reg$name`, rendered with `render_prompt(reg$name, ...)`.
  - `print.agentgraph_prompt` / `print.agentgraph_prompt_registry` — S3 methods.
- `NAMESPACE`: exports `prompt_template`, `prompt_variables`, `render_prompt`, `prompt_message`,
  `prompt_file`, `save_prompt`, `prompt_registry`, `add_prompt`, `save_registry` + 2 S3method
  print registrations. Twelve new `man/*.Rd` generated.
- Tests: `tests/testthat/test-34-prompts.R` (10 tests / 55 assertions, 9 offline + 1 mock):
  build/validation, variable extraction (incl. literal braces), substitution/repeat/precedence/
  missing/unnamed/vector-value errors, metacharacter safety, file round-trip, prompt_message
  roles, registry load/add/save (incl. default-dir save and unchanged-input functional style),
  print output, and an end-to-end mock test proving a rendered template reaches the LLM as the
  system prompt (checked via the request log). ALL PASS first run; full suite PASS (1 gated live
  DeepSeek test skipped, `AGENTGRAPH_API_KEY` not set).

### Batch API — DONE
Goal (user): run a target (agent, graph, or function) over many inputs at once — synchronously or
as an async background job — with per-input error containment and optional parallelism. Pure R;
parallel/async modes use the already-Suggests `mirai` package (separate R processes), so no C++ changes.

DONE:
- `R/batch.R` (new module). Exports:
  - `batch(target, inputs, ..., concurrency = 1L, on_result = NULL)` — returns a data frame
    (class `agentgraph_batch`) with `i, input, answer, error, elapsed`. Target kinds (validated):
    agent (each input a single string -> `run_agent()`), graph (`state_graph()` result; each input a
    single string wrapped as a user message OR a full state list -> `run()`), or function
    (`target(input, ...)`, a list with `$answer` unwrapped). `...` is materialized into a list via
    `dots <- list(...)` and passed with `do.call(...)` so no promise objects leak into serialized
    worker closures. Per-input errors (target or the `.as_batch_state` state coercion) are contained
    per row. `on_result(row)` fires in input order after completion.
    - `concurrency = 1` (default): sequential in-process, no extra deps.
    - `concurrency > 1`: distributes over that many mirai daemons. Reuses existing daemons (detected
      via `mirai::status()$connections > 0`) and leaves them running; otherwise starts its own and
      tears them down with `on.exit(mirai::daemons(0))`. Worker closure is `function(.x)
      .batch_run_one(fn, .x)` — `.batch_run_one` itself tryCatch'es so a worker error is recorded as
      a row, never surfaced as a mirai error; the `mirai::is_error_value` branch in the collector is
      only a backstop.
  - `batch_submit(target, inputs, ..., concurrency = 1L)` — async job (class
    `agentgraph_batch_job`, list(mirai, inputs, concurrency, submitted)). Requires mirai even for
    concurrency 1 (the background eval runs in a daemon). Arguments validated EAGERLY (invalid jobs
    fail at submit). Ensures >= 1 daemon exists and leaves it running (tearing down would kill the
    in-flight job; mirai daemons exit with the R session). Uses the `mirai(.fn(), .args = list(.fn =
    job_fn))` pattern; `job_fn` calls `do.call(batch, ...)`.
  - `batch_status(job)` — "running" (mirai::unresolved) / "error" (mirai::is_error_value) / "complete".
  - `batch_collect(job, timeout = NULL)` — polls with `Sys.sleep(0.05)`; optional timeout raises
    "still running after N seconds" WITHOUT killing the job (a later collect still works); returns
    the batch data frame; errors if the job itself errored ("batch job failed: <msg>").
  - `print.agentgraph_batch` / `print.agentgraph_batch_job` — S3 methods.
- `NAMESPACE`: exports `batch`, `batch_submit`, `batch_status`, `batch_collect` + 2 S3method print
  registrations. Six new `man/*.Rd` generated.
- Tests: `tests/testthat/test-35-batch.R` (12 tests / 39 assertions): arg validation, sequential
  function target with error containment + on_result, `$answer` unwrap + `...` forwarding, agent
  target (mock), graph target with string + state + invalid-state inputs (invalid state contained
  per row), mirai parallel order/error preservation, mirai parallel agent vs mock, submit/status/
  collect round-trip, timeout-without-kill semantics, eager submit validation, print output.
  ALL PASS; full suite PASS (1 gated live DeepSeek test skipped, `AGENTGRAPH_API_KEY` not set).

mirai semantics verified this session (Windows, mirai 2.7.2): daemons spawn fine; `m$data` holds
the value; errors surface as `miraiError` with `$message` (checked via `mirai::is_error_value`);
`call_mirai` has NO timeout arg and returns a `recvAio` (value still at `$data`); `mirai::status()`
is a list with `$connections` = daemon count (0 when none); `mirai_map` preserves input order;
`mirai()` WITHOUT daemons still resolves (but `batch_submit` starts one anyway for predictability);
nested daemons (a job daemon running a parallel `mirai_map` for concurrency > 1) work when builtins
are referenced as `mirai::` (the daemon's global env is fresh, so bare names like `collect_mirai`
are unresolved). A function target's closure only serializes cleanly over package frames — a
closure over the GLOBAL env loses its bindings in the daemon (inherent mirai limitation, documented
in the `batch` roxygen: parallel/async function targets must be self-contained).

Test note: `c()` in R returns NULL, not an empty character vector — the "at least one input" branch
needs `character(0)` to trigger; `batch(f, NULL)` and `batch(f, c())` both hit the "character
vector or a list" branch.

### A2A (agent-to-agent) protocol — DONE
Goal (user): expose an agentgraph agent over HTTP so other agents (or any JSON-RPC 2.0 client)
can call it, and call remote agents the same way. A minimal Agent-to-Agent (A2A) implementation.
Server is a separate R process (httpuv); client is curl. No C++ changes.

DONE:
- `inst/tools/a2a_server.R` (new subprocess script, spawned by `a2a_server()` via processx):
  deserializes an agent + card from .rds, serves `GET /.well-known/agent.json` (and
  `/agent-card.json`) returning the card, and `POST /` handling JSON-RPC 2.0 `tasks/send` and
  `message/send`. `tasks/send` returns a completed `Task` (`id`, `contextId`, `status.state =
  "completed"`, `artifacts = [{name="answer", parts=[{type="text", text}]}]`); `message/send`
  returns a stateless `Message` (`role="agent"`, `parts`). Errors are proper JSON-RPC codes:
  -32600 invalid request, -32601 unknown method, -32602 no text, -32700 parse error, -32000 agent
  failure. Port = `httpuv::randomPort()`; the real bound port is written to a ready file after
  `startServer()`; the card's `url` is updated to the actual endpoint; then
  `while(TRUE) httpuv::service(1000)` serves forever (parent kills it via a2a_stop).
- `R/a2a.R` (new module). Exports:
  - `agent_card(name, description, url, version, protocol_version, skills, capabilities)` — the
    A2A agent card list (name, description, url, version, protocolVersion, capabilities,
    defaultInputModes/OutputModes = ["text/plain"], skills).
  - `a2a_server(agent, host="127.0.0.1", card=NULL, name=NULL, description=NULL, skills=list(),
    timeout=30)` — validates agent, REJECTS `router_agent()` (its R `run_fn` closure cannot
    serialize; only graph-based chat/react/plan-execute/reflection agents are supported), requires
    httpuv, saveRDS's agent+card to temp files, spawns the subprocess, waits for the ready file,
    returns a handle (class `agentgraph_a2a_server`) with `process, host, port, url, card, files`.
  - `a2a_stop(server)` — kills the subprocess + unlinks temp files; safe no-op on NULL.
  - `a2a_agent_card(url)` — GETs `<base>/.well-known/agent.json`, returns the parsed card.
  - `a2a_send(url, message, task_id=NULL)` — POSTs JSON-RPC `tasks/send`; `message` is a string or
    an A2A `list(role, parts)`; returns the final answer text (concatenated text parts); raises on
    JSON-RPC `error` or HTTP >= 400.
  - `a2a_agent(url, description="")` — wraps a remote endpoint as a local agent (`new_agent` with a
    `run_fn` calling `a2a_send`), so `run_agent()` composes remote agents.
  - `print.agentgraph_a2a_server` — S3 method.
- `NAMESPACE`: exports `agent_card`, `a2a_server`, `a2a_stop`, `a2a_agent_card`, `a2a_send`,
  `a2a_agent` + `S3method(print, agentgraph_a2a_server)`. Seven new `man/*.Rd` generated.
- Tests: `tests/testthat/test-36-a2a.R` (6 tests / 22 assertions): card structure, server validation
  (non-agent + router_agent rejected), full round-trip against a mock LLM (card fetch, tasks/send,
  a2a_agent + run_agent, print), raw JSON-RPC `message/send` + unknown-method -32601 error, dead
  endpoint errors, URL validation + a2a_stop(NULL). ALL PASS; full suite PASS (1 gated live
  DeepSeek test skipped, `AGENTGRAPH_API_KEY` not set).

httpuv/curl semantics verified this session (Windows, httpuv 1.6.17): `startServer` does NOT
auto-assign a port (port 0 -> getPort() returns 0), so the subprocess uses `httpuv::randomPort()`;
the request object exposes `req$rook.input` (an `InputStream` R6 with a `read()` method returning
the raw body) — `req$rook.input$read()` -> `rawToChar()` is the body-read idiom; `req$.bodyData` is
a `file` connection (NOT the body bytes). CRITICAL: httpuv callbacks run on the R MAIN thread, so a
blocking `curl_fetch_memory` in the SAME process deadlocks — hence the separate-process server.
agentgraph, httpuv, processx are all on the default `.libPaths()`, so the subprocess needs no
explicit libPaths.

### Security layer — PII scrubbing — DONE
Goal (user, item 1 of the security layer): redact common PII before it leaves the process, both as a
transparent provider option and a standalone helper. This is the first of the post-framework
"production hardening" items (follow-on items: prompt-injection defense, tool-call validation,
budget/kill switch, cost tracking, REST wrapper, async jobs, mock/replay, metrics, multi-tenancy,
compliance, versioning, feedback, voice, computer use, fine-tuning, plugins, SSE server, docs/Docker,
distributed execution).

DONE:
- `src/llm/pii.hpp` (new, header-only): `agentgraph::scrub_pii(input, redact)` uses std::regex in a
  canonical order — email -> API key (sk-/pk-/rk-/ghp_/AKIA/AIza) -> US SSN -> credit-card-like
  digit runs -> US phone -> IPv4. Each replace is wrapped in try/catch so a regex error can never
  abort an LLM call. Fixed during validation: the credit-card pattern is now
  `\b(?:\d[ -]?){12,18}\d\b` (the trailing `\d\b` stops it swallowing the following space) and the
  phone pattern is `(?:\+?1[-.\s]?)?\(?\d{3}\)?[-.\s]?\d{3}[-.\s]?\d{4}` (the optional country code
  carries its own separator, so a bare number no longer eats a leading space).
- `src/core/config.hpp`: `ProviderConfig` gained `bool pii_filter = false` and
  `std::string pii_redact = "[REDACTED]"` (defaults keep the old path).
- `src/type_converters.cpp` `provider_from_list`: parses `pii_filter` + `pii_redact`.
- `src/llm/llm_client.cpp` `build_request`: when `config_.pii_filter`, scrubs the system prompt,
  message content (user/assistant/system/tool), tool-call arguments, and text content parts (image/
  audio/video parts untouched) via a local `scrubbed` lambda. Applied uniformly because this is the
  single request-building point, so graph LLM nodes, `chat()`, and streaming all get it.
- `R/providers.R`: added `provider_pii(provider, redact = "[REDACTED]")` (mirrors `provider_cache()`:
  wraps any provider or fallback chain, sets `pii_filter = TRUE` + `pii_redact`). Chose the wrapper
  over adding two args to all nine provider constructors for DRY/consistency with provider_cache.
- `R/pii.R` (new): standalone `pii_scrub(text, redact, entities)` (pure R, `gsub(perl=TRUE)`) with the
  same patterns/order as C++ so behavior matches; `entities` restricts which of email/api_key/ssn/
  credit_card/phone/ipv4 are scrubbed (canonical order always applied); vectorized; validates args.
- `NAMESPACE`: exports `provider_pii`, `pii_scrub`. Two new `man/*.Rd`.
- Tests: `tests/testthat/test-37-pii.R` (8 tests / 31 assertions): per-entity redaction, ordinary text
  untouched, custom redact + entity subset, vectorization + validation, full-card-as-one-unit, wrapper
  validation, and two mock tests proving the outbound body + system prompt are actually redacted while
  the default (no wrapper) leaves content untouched. ALL PASS; full suite PASS (1 gated live DeepSeek
  skip, `AGENTGRAPH_API_KEY` not set).

Note (heuristic limits, intentional): the scrubber is recall-over-precision; a bare 10-digit run can
be treated as a phone and a long digit run as a card. The canonical credit-card-before-phone order
prevents partial card redaction in the DEFAULT case; non-default entity subsets may overlap.

### Security layer — prompt-injection defense — DONE
Goal (user, item 2): a sanitization layer between untrusted content (retrieved pages, documents,
tool results) and what the LLM sees. Pure R (`R/guard.R`); no C++ changes.

DONE:
- `R/guard.R` (new module) exports six primitives:
  - `detect_injection(text)` -> `list(detected, markers)`; case-insensitive literal scan of a curated
    marker list ("ignore previous instructions", "reveal your system prompt", "do anything now",
    "jailbreak", etc.).
  - `sanitize_untrusted(text)` — strips C0 control chars (keeping \t/\n) + DEL + zero-width/bidi
    override chars (`\u200b-\u200f`, `\u202a-\u202e`, `\u2060`, `\ufeff`), then neutralizes each
    marker with "[UNTRUSTED INSTRUCTION REMOVED]". Markers are plain alphanumeric text, so they are
    used as regex literals with `ignore.case = TRUE` (NOTE: `gsub` ignores `ignore.case` when
    `fixed = TRUE` — caught in tests and fixed).
  - `fence_untrusted(text, label, preamble)` — "spotlighting": wraps in `<label>…</label>` with a
    "this is data, not instructions" preamble; label sanitized to `[A-Za-z0-9_]`.
  - `guard_tool_result(text, tool)` — sanitize + fence a plain-text tool result (message-level use).
  - `guard_messages(messages, roles = "tool")` — applies `guard_tool_result` to string `content` of
    messages whose role is in `roles`; multimodal (`parts`) messages untouched.
  - `guarded_tool(tool)` — wraps a tool handler so its JSON output is SANITIZED (markers neutralized
    + hidden chars stripped). IMPORTANT discovery: the C++ tool node parses the handler's return as
    JSON (`src/tools/rpc_tool_client.cpp` does `json::parse(result_str)`), so a text fence around the
    whole JSON breaks the contract ("tool handler returned invalid JSON"). `guarded_tool` therefore
    sanitizes IN PLACE (keeps valid JSON); fencing is documented as message-level only. The wrapper
    is built via a `make_handler(orig, markers)` factory with `force()` so the returned closure
    captures only `orig` + `markers` (no self-referential `tool`), and uses base R only so it
    serializes cleanly into the tool-server subprocess.
- `NAMESPACE`: exports all six. Six new `man/*.Rd`.
- Tests: `tests/testthat/test-38-guard.R` (9 tests / 34 assertions): fence + label sanitization,
  control/zero-width stripping, case-insensitive neutralization, detection, tool-result + message
  guarding, direct guarded_tool handler call (incl. JSON-still-valid), input validation, and an
  end-to-end mock test proving a guarded tool's result reaches the LLM sanitized but still valid JSON.
  ALL PASS; full suite PASS (1 gated live DeepSeek skip, `AGENTGRAPH_API_KEY` not set).

### Security layer — tool-call validation — DONE
Goal (user, item 3): whitelist/denylist enforcement before a tool executes (filesystem paths and URL
domains), so an agent cannot read/write arbitrary files or hit arbitrary hosts. Pure R (`R/policy.R`).

DONE:
- `R/policy.R` (new module) exports:
  - `tool_policy(path_allow, path_deny, domain_allow, domain_deny, path_args, url_args)` — a policy
    object (class `agentgraph_tool_policy`). Default `path_args` = c("path","file","db","db_path",
    "input_file","output_file","dir","directory"); default `url_args` = c("url","endpoint","base_url",
    "api_url"). Domains lowercased on build.
  - `validate_tool_args(args, policy)` — checks string values of args whose name is in path_args/url_args;
    stops with a clear message on the first violation, else `invisibly(TRUE)`. Accepts a named list or a
    JSON string.
  - `restrict_tool(tool, policy)` — wraps a tool so its handler validates args first, then delegates.
    A violation raises (surfaced to the LLM as a failed tool result). Self-contained (base R only,
    built via a `make_handler(orig, p)` factory with `force()` so it captures only `orig` + `p` and
    serializes into the tool server). Composable with `guarded_tool()`.
  - `print.agentgraph_tool_policy` — S3 method.
- Semantics: path allow = must resolve under an allowed prefix (case-insensitive on Windows, separators
  normalized with `normalizePath(winslash="/", mustWork=FALSE)`); path deny = must NOT be under a
  denied prefix; domain allow/deny = exact host OR subdomain (`endsWith(".domain")`), host extracted by
  stripping scheme + path + port + userinfo, lowercased.
- `NAMESPACE`: exports `tool_policy`, `validate_tool_args`, `restrict_tool` + `S3method(print,
  agentgraph_tool_policy)`. Four new `man/*.Rd`.
- Tests: `tests/testthat/test-39-policy.R` (10 tests / 29 assertions): policy build/validation, path
  allow + deny, domain allow (incl. subdomain + port + bare host) + deny (incl. subdomain), non-path/
  url args ignored, JSON-string args, direct restrict_tool (allowed delegates + increments a counter,
  denied never calls the handler), input validation, and an end-to-end mock test proving a denied path
  surfaces as a "tool policy" error in the tool result. ALL PASS; full suite PASS (1 gated live
  DeepSeek skip, `AGENTGRAPH_API_KEY` not set).

### Security layer — budget / kill switch — DONE
Goal (user, item 4): abort a run when it exceeds a token or wall-clock budget (`max_total_tokens`,
`max_time_sec`). Requires C++ enforcement (R's on_event can't abort a blocked `.Call`). `max_cost_usd`
is intentionally deferred to the cost-tracking item (it needs a pricing table).

DONE:
- `src/core/config.hpp`: added `UsageTracker` (thread-safe `std::atomic<long long> total_tokens`,
  `using UsageTrackerPtr = std::shared_ptr<UsageTracker>`) and `BudgetConfig { int max_total_tokens;
  double max_time_sec; }` (0 = unlimited). Added `#include <atomic>`.
- `src/graph/node_runner.hpp/.cpp`: `NodeRunner` gained a `UsageTrackerPtr usage_` (ctor param);
  `run_llm_node` does `usage_->total_tokens.fetch_add(response.usage.total_tokens)` after the main
  completion. (Secondary summarization/entity-extraction LLM calls are NOT counted — noted limitation.)
- `src/graph/executor.hpp/.cpp`: `Executor` gained `BudgetConfig budget_` + `UsageTrackerPtr usage_`
  (ctor params; usage auto-created when null). `run_impl` holds a local `start` time and a
  `check_budget` lambda; after every node completes it aborts with "Budget exceeded: max_total_tokens
  (N)" or "Budget exceeded: max_time_sec (Ns)" when a limit is crossed. `run_parallel_node` passes
  `usage_` to worker NodeRunners; `run_subgraph_node` constructs the sub-Executor with the SAME
  `budget_` + `usage_` (so token totals accumulate across subgraphs; a subgraph's time window restarts
  — minor limitation, documented).
- `src/rcpp_exports.cpp` `run_graph_cpp`: added `int max_total_tokens = 0, double max_time_sec = 0.0`
  params; builds a `BudgetConfig` + fresh `UsageTracker` and passes both to the Executor.
- `R/run.R`: `run()`, `stream()`, `resume()`, `checkpoint_resume()` gained `max_total_tokens = 0L`,
  `max_time_sec = 0` and pass `as.integer(max_total_tokens)` / `as.numeric(max_time_sec)` to
  `run_graph_cpp`. `R/RcppExports.R` + `src/RcppExports.cpp` regenerated (compileAttributes).
- Tests: `tests/testthat/test-40-budget.R` (6 tests / 13 assertions): token limit aborts a 3-node
  graph at the 3rd call (45 > 30), token limit under-cap completes, no budget = unlimited, time limit
  aborts a 1s latent mock with max_time_sec=0.3, time limit allows a fast run, and token budget
  accumulates across a ReAct tool loop. ALL PASS; full suite PASS (1 gated live DeepSeek skip,
  `AGENTGRAPH_API_KEY` not set).

### Cost tracking — DONE
Goal (user, item 5): a pricing table, per-completion cost estimation, a session usage accumulator,
and a `max_cost_usd` budget wired into the kill switch (deferred from item 4). C++ + R.

DONE:
- `src/llm/usage_registry.hpp` (new, header-only): `UsageRegistry` singleton with atomic
  `prompt_tokens` / `completion_tokens` / `total_tokens` / `cost_usd`, `add(TokenUsage, cost)` and
  `reset()`. Cost is accumulated AT CALL TIME (each provider's own price) so multi-model sessions are
  priced correctly rather than blended later.
- `src/llm/llm_client.cpp`: in `complete()` (after parse_response) and `complete_stream()` (after the
  final response is assembled), computes `cost = (prompt*input + completion*output)/1e6` from
  `config_.input/output_price_per_1m` and calls `UsageRegistry::instance().add(...)`. Placed in the
  CLIENT (not the node runner) so it covers `chat()`, graph nodes, summarization, and entity
  extraction uniformly. Streaming responses have usage=0, so they contribute no cost (noted limitation).
- `src/core/config.hpp`: `ProviderConfig` gained `double input_price_per_1m = 0` /
  `output_price_per_1m = 0`; `UsageTracker` gained `std::atomic<double> cost_usd`; `BudgetConfig`
  gained `double max_cost_usd = 0`.
- `src/type_converters.cpp`: parses `input_price_per_1m` / `output_price_per_1m`.
- `src/graph/node_runner.cpp`: keeps per-run `usage_->total_tokens` + `usage_->cost_usd` accumulation
  (for the budget); global accumulation moved out to the client to avoid double counting.
- `src/graph/executor.cpp`: `check_budget` now also aborts on `usage_->cost_usd > max_cost_usd`.
- `src/rcpp_exports.cpp`: `run_graph_cpp` gained `double max_cost_usd = 0`; added `usage_reset_cpp()`
  and `usage_stats_cpp()` (returns prompt/completion/total tokens + cost_usd). Regenerated
  RcppExports.
- `R/run.R`: `run()`/`stream()`/`resume()`/`checkpoint_resume()` gained `max_cost_usd = 0`.
- `R/cost.R` (new module) exports:
  - `agentgraph_prices` — best-effort named list of model -> `c(input, output)` USD per 1M tokens
    (gpt-4o/mini, gpt-4.1*, o3-mini, claude-sonnet-4/opus-4, gemini-2.0-flash/1.5-pro, llama-3.3-70b);
    documented as a snapshot.
  - `estimate_cost(prompt_tokens, completion_tokens, model, prices)` — (in*pi + out*po)/1e6; errors on
    unknown model.
  - `provider_pricing(provider, input_per_1m, output_per_1m)` — attaches prices so max_cost_usd fires.
  - `agentgraph_usage()` — data.frame of the session's prompt/completion/total tokens + cost_usd.
  - `usage_reset()` — resets the accumulator.
- `NAMESPACE`: exports all five. Five new `man/*.Rd` (+ run/resume/checkpoint_resume/stream updated).
- Tests: `tests/testthat/test-41-cost.R` (6 tests / 20 assertions): estimate_cost math + unknown-model
  error, prices table shape, provider_pricing, session accumulation across two chat() calls with
  reset, unpriced providers contribute tokens but zero cost, and max_cost_usd aborting a 3-node graph
  at the 2nd call + completing under cap. ALL PASS; full suite PASS (1 gated live DeepSeek skip,
  `AGENTGRAPH_API_KEY` not set).

Fix during validation: the first cut accumulated usage in the node runner, so standalone `chat()`
(which bypasses the graph executor) reported 0. Moved the global accumulator into `llm_client.cpp`'s
`complete`/`complete_stream` and left only per-run budget accounting in the node runner.

### REST API wrapper — DONE
Goal (user, item 6): expose an agent/graph over a generic JSON REST API for production
(`GET /health`, `POST /run`, `POST /stream`, optional bearer auth). Pure R + a subprocess httpuv
server (no C++ changes); reuses the same subprocess/ready-file/randomPort pattern as a2a_server().

DONE:
- `inst/tools/serve_agent.R` (new subprocess, spawned via processx): deserializes an agent from .rds;
  serves `GET /health` -> `{"status":"ok"}` (open), `POST /run` -> `{"input":"..."}` -> `{"answer",
  "state"}` (auth), `POST /stream` -> `{"answer","tokens"}` where tokens are captured via `on_token`.
  Auth = `Authorization: Bearer <token>` (header at `req$HTTP_AUTHORIZATION`); 401 on mismatch,
  400 on missing/empty input, 404 otherwise, 500 on agent failure. `randomPort()` + `startServer` +
  ready file + `while(TRUE) httpuv::service(1000)`.
- `R/serve.R` (new module) exports:
  - `serve_agent(target, host="127.0.0.1", auth_token=NULL, name="agent", timeout=30)` — accepts an
    agent OR a graph (graphs are normalized via the internal `new_agent(graph=...)` so the subprocess
    only needs `run_agent`); rejects `router_agent()` (run_fn closure not serializable) and other
    targets; saveRDS's the agent, spawns the subprocess, waits for the ready file; returns a handle
    (class `agentgraph_serve`) with `process, host, port, url, name, files`.
  - `serve_stop(server)` — kills the subprocess + unlinks temp files; safe no-op on NULL.
  - `print.agentgraph_serve` — S3 method.
- `NAMESPACE`: exports `serve_agent`, `serve_stop` + `S3method(print, agentgraph_serve)`. Three new
  `man/*.Rd`.
- Tests: `tests/testthat/test-42-serve.R` (7 tests / 24 assertions): target validation (incl. router
  rejection + auth_token type), /health + /run for an agent, /run for a graph target, auth (health
  open, 401 without/wrong token, 200 with token), /stream capturing the token sequence from the
  stream mock, and 400/404/`serve_stop(NULL)`. ALL PASS; full suite PASS (1 gated live DeepSeek
  skip, `AGENTGRAPH_API_KEY` not set).

Note: `/stream` is "streaming capture" — it runs the agent with `on_token` and returns the full token
sequence + answer in one JSON response, NOT true Server-Sent Events (SSE). True SSE/browser push is a
separate later item.

### Async jobs — DONE
Goal (user, item 7): run an agent/graph/function in the background and poll/cancel it
(`run_async` -> `job_status`/`job_result`/`job_cancel`). Pure R on mirai (Suggests); generalizes
the async machinery first built for `batch_submit`.

DONE:
- `R/async.R` (new module) exports:
  - `run_async(target, input, ...)` — validates target kind (agent / graph / function) and input
    (agent needs a single string; graph a string or state list); builds a target fn via
    `do.call(run_agent | run | target, ...)`; ensures >= 1 mirai daemon; submits
    `mirai(.fn(), .args = list(.fn = job_fn))` where `job_fn` tryCatches the target and returns
    `list(.job_error = msg)` on error; stores the mirai in a session registry
    (`.agentgraph_jobs`, a namespace-level `new.env(parent=emptyenv())`); returns a job handle
    (class `agentgraph_job`) with `$id` (random `job_<hex>`).
  - `job_status(job)` — "running" (unresolved) / "failed" (mirai error value OR `.job_error`) / "done".
  - `job_result(job, timeout = NULL)` — polls `mirai::unresolved` with `Sys.sleep(0.05)`; optional
    timeout raises WITHOUT cancelling (a later call still works); raises "job failed: <msg>" for
    failed jobs; else returns the result (agent -> list(answer,state); graph -> state; function ->
    its return).
  - `job_cancel(job)` — best-effort `mirai::stop_mirai` on an unresolved job.
  - `print.agentgraph_job` — S3 method.
- `NAMESPACE`: exports `run_async`, `job_status`, `job_result`, `job_cancel` +
  `S3method(print, agentgraph_job)`. Five new `man/*.Rd`.
- Tests: `tests/testthat/test-43-async.R` (6 tests / 15 assertions): target/input validation, graph
  round-trip (status running->done, result messages), agent round-trip (result$answer), timeout
  without cancel, failing target -> "failed" + job_result raises "job failed", job_cancel no-op +
  unknown-job errors. ALL PASS; full suite PASS (1 gated live DeepSeek skip, `AGENTGRAPH_API_KEY`
  not set).

Note: jobs live in an in-memory registry for the session (mirai daemons exit with the session); no
persistence/restart. Function targets must be self-contained (mirai serializes closures; a closure
over the global env does not transfer) — same limitation as batch().

### Mock LLM provider + replay — DONE
Goal (user, item 8): a built-in offline mock provider (no Python) for CI/deterministic tests, plus
replay from a recorded JSONL trace. Pure R (an in-process httpuv mock server subprocess).

DONE:
- `inst/tools/mock_server.R` (new subprocess): serves an OpenAI-compatible `POST /chat/completions`
  endpoint from a serialized response set in two modes: "sequence" (in order, last repeats) and
  "keyed" (match the request's last user message against names, then `"*"`, then the first entry).
  Each response is a string (content) or a list with `content`/`finish_reason`/`tool_calls`/`usage`/
  `model`; `tool_calls` (simple `list(id,name,arguments)`) are converted to the OpenAI
  `{id,type,function:{name,arguments}}` form, with `arguments` auto-JSON-encoded if not already a
  string. `randomPort()` + `startServer` + ready file + `while(TRUE) httpuv::service(1000)`.
- `R/mock.R` (new module) exports:
  - `provider_mock(responses = list("*"="I don't know"), model="mock")` — normalizes responses
    (named list -> keyed; unnamed list/character -> sequence), spawns the mock server, returns an
    OpenAI provider (`base_url` = the mock, `max_retries=0`).
  - `provider_replay(trace_path, model="replay")` — reads a JSONL trace (`run(..., log_path=...)`),
    extracts `llm_response` events (data = LLMResponse JSON: content/tool_calls/finish_reason/usage/
    model), and re-serves them in sequence.
  - `mock_stop_all()` — kills all mock/replay subprocesses started this session.
  - Mutable state (server process registry + counter) lives in `new.env(parent=emptyenv())` — IMPORTANT:
    package namespace bindings are LOCKED, so `<<-` on a namespace-level variable raises "cannot change
    value of locked binding"; all mutable package state must live in an environment (also relevant to
    the async job registry, which already uses an environment).
- `NAMESPACE`: exports `provider_mock`, `provider_replay`, `mock_stop_all`. Three new `man/*.Rd`.
- Tests: `tests/testthat/test-44-mock.R` (7 tests / 18 assertions): keyed map + `*` fallback, sequence
  with last-repeat, tool_calls through a ReAct loop, response validation, replay of a recorded session,
  replay input validation (missing file + no llm_response events), `mock_stop_all()` no-op.
  ALL PASS; full suite PASS (1 gated live DeepSeek skip, `AGENTGRAPH_API_KEY` not set).

Fixes during validation: (1) `function = ...` in the mock server was a reserved-word parse error —
  must quote the list name as `"function" = ...`; (2) `<<-` on a namespace-level counter raised
  "cannot change value of locked binding" — moved the counter into an environment.

### Interactive graph visualization — DONE
Goal (user, item 9): upgrade graph visualization from a printed Mermaid snippet to include a static
plot and an interactive HTML rendering. Pure R, no new dependencies (Mermaid.js loads from a CDN).

DONE:
- `R/ui-helpers.R` (rewritten) exports:
  - `graph_mermaid(graph)` — pure function returning the Mermaid `graph TD` source as a character
    vector (one line per node/END/edge; node shape encodes type, conditional edges labeled with route
    values). Extracted from the old `visualize()` body so it is testable standalone.
  - `visualize(graph, file = NULL, open = FALSE)` — with `file=NULL` keeps the ORIGINAL behavior
    (prints Mermaid, returns `invisible(lines)`, so test-19 still passes); with `file` writes a
    self-contained HTML page (`<!DOCTYPE html>` + Mermaid.js CDN + `<div class="mermaid">`) that
    renders the graph in a browser, `open=TRUE` opens it; returns `invisible(file)`.
  - `plot.agentgraph(x, ...)` — S3 method printing the static Mermaid source.
- `NAMESPACE`: exports `graph_mermaid`, `visualize` + `S3method(plot, agentgraph)`. Three man pages.
- Tests: `tests/testthat/test-45-viz.R` (4 tests / 12 assertions): graph_mermaid nodes/edges, visualize
  writes an HTML file containing mermaid + "graph TD" + `<div class="mermaid">`, plot prints the
  source, input validation. test-19 (original visualize contract) still passes unchanged.
  ALL PASS; full suite PASS (1 gated live DeepSeek skip, `AGENTGRAPH_API_KEY` not set).

Note: the interactive rendering uses Mermaid.js from a CDN inside the generated HTML (zero R
dependencies); a fully offline build would vendor the JS. No live "currently-executing node"
highlighting — that would require instrumenting the executor; deferred.

### Metrics endpoint — DONE
Goal (user, item 10): expose a Prometheus-style `/metrics` endpoint tracking latency percentiles,
token throughput, error rates, tool-call counts, and cache hit/miss. C++ (cache counters) + R.

DONE:
- C++:
  - `src/llm/llm_cache.hpp`: `LLMCacheRegistry` gained atomic `hits_`/`misses_` + `record_hit()`/
    `record_miss()`/`hits()`/`misses()`.
  - `src/llm/llm_client.cpp`: `CachedLLMClient::complete()` and `complete_stream()` call
    `record_hit()` on a cache hit and `record_miss()` on a miss.
  - `src/rcpp_exports.cpp`: added `cache_hit_stats_cpp()` -> list(hits, misses).
- `R/metrics.R` (new module) exports:
  - `.agentgraph_metrics` (an environment; namespace bindings are locked) — the collector; mutated by
    `.metrics_collect(event, data)` which accumulates from `llm_end` (calls, errors, latency samples),
    `llm_response` (usage tokens), `tool_call`, `node_start`.
  - `.wrap_event_callback(user_on_event)` — returns a closure that always collects metrics AND calls
    the user's callback; used by run()/resume()/checkpoint_resume().
  - `metrics_snapshot()` — named list: llm_calls, llm_errors, error_rate, latency p50/p95/p99 +
    latency_count (via `stats::quantile`), prompt/completion/total tokens, tool_calls, node_runs,
    cache_hits/misses (from `cache_hit_stats_cpp()`).
  - `metrics_reset()` — resets the R collector (NOT the C++ cache counters, which are cumulative-global).
  - `start_metrics_server(port=9090, host, timeout)` — spawns `inst/tools/metrics_server.R` (serves
    `GET /metrics` text/plain + `GET /health`; port 0 -> randomPort); returns a handle.
  - `metrics_stop(server)` / `print.agentgraph_metrics_server`.
  - `.metrics_write()` writes the Prometheus text to a fixed temp file (`tempdir()/agentgraph_metrics.txt`)
    refreshed by `start_metrics_server()` at startup and by `run()`/`resume()`/`checkpoint_resume()`
    after each run; the metrics server subprocess reads that file per scrape.
- `R/run.R`: `run()`, `resume()`, `checkpoint_resume()` now ALWAYS wire `on_event_wrapped =
  .wrap_event_callback(on_event)` (so events always fire and metrics always collect, even without a
  user on_event/log_path) and call `.metrics_write()` after completing.
- `inst/tools/metrics_server.R` (new subprocess): serves the metrics text file verbatim.
- `NAMESPACE`: exports `metrics_snapshot`, `metrics_reset`, `start_metrics_server`, `metrics_stop` +
  `S3method(print, agentgraph_metrics_server)`. Five new `man/*.Rd`.
- Tests: `tests/testthat/test-46-metrics.R` (6 tests / 24 assertions): snapshot (calls/tokens/latency/
  nodes), error counts from a failing run, cache hit/miss DELTAS (counters are process-global, so the
  test measures before/after rather than exact values — caught as a test-isolation failure when run in
  the full suite), /metrics Prometheus text, reset + stop no-op. ALL PASS; full suite PASS (1 gated
  live DeepSeek skip, `AGENTGRAPH_API_KEY` not set).

Notes: latency percentiles come from `llm_end.duration_ms`; streaming runs report usage=0 (so token
metrics undercount streaming). The metrics server is a subprocess reading a snapshot file (not an
in-process server) to avoid the httpuv + blocking-client deadlock. Cache hit/miss are cumulative
process-global (not reset by metrics_reset).

### Multi-tenancy — DONE
Goal (user, item 11): per-tenant isolation with rate limits, usage caps, usage tracking, and audit
logs; `run(..., tenant = ...)`. Pure R.

DONE:
- `R/tenant.R` (new module) exports:
  - `tenant(tenant_id, requests_per_minute=0, max_requests=0, max_total_tokens=0, max_cost_usd=0,
    audit_path=NULL)` — a tenant config (class `agentgraph_tenant`), registered in a package env
    (`.agentgraph_tenants`).
  - `run(..., tenant = NULL)` — before running, `.tenant_check()` enforces: a 60s sliding-window rate
    limit (from `request_times`), and cumulative caps (max_requests / max_total_tokens / max_cost_usd);
    after running, `.tenant_record()` increments the tenant's usage and appends a JSONL audit line
    (`{ts_ms, tenant_id, tokens, cost_usd}`) to `audit_path`. This run's tokens/cost are computed as
    the `agentgraph_usage()` delta before/after the run.
  - `tenant_usage(tenant_id)` — data.frame of usage totals + limits.
  - `tenant_audit(tenant_id)` — data.frame of audit lines (ts_ms, tenant_id, tokens, cost_usd).
  - `tenant_reset(tenant_id = NULL)` — resets one or all tenants' usage counters.
  - `tenant_namespace(tenant_id, name)` — `"<tenant_id>::<name>"` for vector-store collection names.
  - `print.agentgraph_tenant` — S3 method.
- `R/run.R`: `run()` gained `tenant = NULL` (validated as a `tenant()`; wraps the run with
  check-before + record-after).
- `NAMESPACE`: exports `tenant`, `tenant_usage`, `tenant_audit`, `tenant_reset`, `tenant_namespace` +
  `S3method(print, agentgraph_tenant)`. Six new `man/*.Rd` (+ run.Rd updated).
- Tests: `tests/testthat/test-47-tenant.R` (6 tests / 20 assertions): tenant build/limits/usage/print,
  per-tenant usage recording, max_requests cap, rate-limit burst, audit log round-trip, namespace
  helper + run() tenant validation + tenant_usage unknown error + reset-all. ALL PASS; full suite PASS
  (1 gated live DeepSeek skip, `AGENTGRAPH_API_KEY` not set).

Notes: tenant usage state lives in package environments (namespace bindings are locked). Vector-store
namespacing is provided as a prefix helper (the user prefixes collection names) rather than deep C++
store isolation; full per-tenant vector isolation is deferred.

### Compliance & audit — DONE
Goal (user, item 12): tamper-evident hash-chained logs + a PII audit trail. Pure R. Data-residency
controls ("never send EU data to US endpoints") are deferred (they need region metadata on providers).

DONE:
- `R/audit.R` (new module) exports:
  - `audit_log(path)` — opens a JSONL audit log; handle (class `agentgraph_audit`) holds a nested
    `new.env(parent=emptyenv())` with `seq` + `last_hash` (mutable state).
  - `audit_record(log, event, data=list(), pii=list())` — appends an entry `{seq, ts_ms, event, data,
    pii, prev, hash}` where `hash = .audit_hash(paste0(prev, "|", toJSON(list(seq, ts_ms, event, data,
    pii))))` and `prev` is the previous entry's hash (or "genesis").
  - `audit_verify(log)` — recomputes each entry's hash from its stored content fields + `prev`, and
    checks the chain linkage; returns FALSE on modification/insertion/deletion/reordering.
  - `audit_read(log)` — data.frame of `seq, ts_ms, event, hash`.
  - `pii_report(text, entities)` — data.frame counting, per entity type, what `pii_scrub()` would redact
    (reuses the internal `.pii_patterns`/`.pii_canonical` from pii.R); usable as the `pii=` arg to
    `audit_record()`.
  - `print.agentgraph_audit` — S3 method.
  - `.audit_hash(x)` — deterministic non-cryptographic djb2-style 32-bit hash (integer arithmetic on
    doubles, mod 2^32; good for tamper-evidence, NOT cryptographic).
- `NAMESPACE`: exports `audit_log`, `audit_record`, `audit_verify`, `audit_read`, `pii_report` +
  `S3method(print, agentgraph_audit)`. Six new `man/*.Rd`.
- Tests: `tests/testthat/test-48-audit.R` (6 tests / 19 assertions): record/read/verify, tamper
  detection (modified field), deletion detection (broken chain), empty-log verify, pii_report counts,
  input validation. ALL PASS; full suite PASS (1 gated live DeepSeek skip, `AGENTGRAPH_API_KEY` not set).

Fixes during validation: (1) the first cut stored a separate `body` string as the hashed payload, so
tampering with the DISPLAY fields (event/data/pii) was undetectable — now the hash is computed over the
content fields themselves and recomputed from the stored fields on verify (JSON round-trip is
deterministic for these field types); (2) `audit_verify`/`audit_read` now return TRUE/empty when the
file does not exist yet.

### Agent versioning & A/B — DONE
Goal (user, item 13): save/load versioned agents/graphs and A/B-compare them; "rollback" = load the
older (better) version. Pure R on saveRDS + the eval framework.

DONE:
- `R/versioning.R` (new module) exports:
  - `agent_registry_dir()` — default registry dir (`~/.agentgraph/agents`, overridable via
    `options(agentgraph.registry_dir=...)`).
  - `save_agent(agent, name, version="1.0.0", dir=NULL)` — saveRDS to `<dir>/<name>/<version>.rds`;
    accepts graph-based agents or graphs; rejects `router_agent()` (run_fn closure not serializable).
  - `load_agent(name, version=NULL, dir=NULL)` — loads a version; NULL version loads the HIGHEST
    (sorted via `numeric_version`, falling back to lexicographic).
  - `agent_versions(name, dir=NULL)` — sorted version tags.
  - `ab_evaluate(a, b, dataset, evaluators=list(), ...)` — runs both through `evaluate()` (graphs are
    normalized to agents via the internal `new_agent(graph=...)`), returns a comparison (class
    `agentgraph_ab`) with `score_a`, `score_b` (mean of summary mean_score), and `winner`.
  - `print.agentgraph_ab` — S3 method.
- `NAMESPACE`: exports `agent_registry_dir`, `save_agent`, `load_agent`, `agent_versions`,
  `ab_evaluate` + `S3method(print, agentgraph_ab)`. Six new `man/*.Rd`.
- Tests: `tests/testthat/test-49-versioning.R` (6 tests / 17 assertions): graph round-trip + version
  list + latest + missing-version error, agent round-trip, validation (non-target, router rejection,
  empty name), unknown-name empty list + load error, ab_evaluate with function targets (scores +
  winner), ab_evaluate with graph targets (mock). ALL PASS; full suite PASS (1 gated live DeepSeek
  skip, `AGENTGRAPH_API_KEY` not set).

Note: `is_agent` is an INTERNAL helper (not exported) — tests must use `inherits(x, "agentgraph_agent")`
(initial test used `agentgraph::is_agent()` and errored; fixed).

### RLHF / feedback loop — DONE
Goal (user, item 14): collect thumbs up/down + corrections on run results to build a dataset for
fine-tuning / prompt optimization. Pure R.

DONE:
- `R/feedback.R` (new module) exports:
  - `record_feedback(result=NULL, rating, correction=NULL, input=NULL, output=NULL, comment=NULL)` —
    extracts input (last user message) + output (last assistant message, or `$answer`) from a run()
    state or run_agent() result (or uses explicit input/output), normalizes the rating (good/bad/up/
    down/thumbs_up/thumbs_down/1/-1/TRUE/FALSE -> "good"/"bad"), and appends a record
    `{seq, ts_ms, input, output, rating, correction, comment}` to a package environment
    (`.agentgraph_feedback`, with a nested `records` list + `seq` counter).
  - `feedback_dataset()` — data.frame of all records.
  - `feedback_stats()` — data.frame `good`, `bad`, `total`.
  - `feedback_export(path)` — writes one JSON object per record (JSONL) for a fine-tuning pipeline.
  - `feedback_reset()` — clears.
- `NAMESPACE`: exports `record_feedback`, `feedback_dataset`, `feedback_stats`, `feedback_export`,
  `feedback_reset`. Five new `man/*.Rd`.
- Tests: `tests/testthat/test-50-feedback.R` (6 tests / 18 assertions): extraction from a run result,
  explicit input/output + correction, rating normalization, stats + reset, JSONL export, validation.
  ALL PASS; full suite PASS (1 gated live DeepSeek skip, `AGENTGRAPH_API_KEY` not set).

### Voice pipeline (STT / TTS) — DONE
Goal (user, item 15): complete the audio loop — transcribe (STT), synthesize (TTS), and a
`voice_run()` convenience. Audio *input* parts already existed (`audio_part()`/`audio_file_part()`);
this adds output. Pure R (curl, Suggests); STT/TTS are standalone REST calls, not graph nodes.

DONE:
- `R/voice.R` (new module) exports:
  - `provider_whisper(api_key, model="whisper-1", base_url)` — STT provider config.
  - `provider_elevenlabs(api_key, voice_id=NULL, model, base_url)` — TTS provider config.
  - `transcribe(audio_file, provider, language=NULL)` — multipart POST (`curl::handle_setform` +
    `curl::form_file`) to `<base_url>/audio/transcriptions` with `Authorization: Bearer`; returns
    `json$text`.
  - `synthesize(text, provider, output_file=NULL)` — JSON POST to `<base_url>/text-to-speech/<voice_id>`
    with `xi-api-key`; writes the returned audio bytes to a file; returns the path.
  - `voice_run(graph, state=NULL, text=NULL, audio_file=NULL, stt_provider=NULL, tts_provider=NULL,
    output_file=NULL, ...)` — transcribes audio (if given) -> injects text as a user message -> `run()`
    -> `final_answer()` -> synthesizes (if tts_provider given); returns `list(text, answer, audio, state)`.
- `tests/testthat/mock/voice_mock.py` (new) + `helper-mocks.R` `start_voice_mock()` — a Python mock
  serving `POST /audio/transcriptions` -> `{"text":"hello from stt"}` and `POST /text-to-speech/<voice>`
  -> raw `b"FAKE_AUDIO_MP3"` (audio/mpeg).
- `NAMESPACE`: exports `provider_whisper`, `provider_elevenlabs`, `transcribe`, `synthesize`,
  `voice_run`. Five new `man/*.Rd`.
- Tests: `tests/testthat/test-51-voice.R` (6 tests / 15 assertions): provider configs, transcribe vs
  voice mock, synthesize writes audio bytes, voice_run (graph via provider_mock + TTS via voice mock),
  voice_run with STT (transcribe then run, no TTS), input validation. ALL PASS; full suite PASS (1
  gated live DeepSeek skip, `AGENTGRAPH_API_KEY` not set).

Note: STT/TTS are generic Whisper-/ElevenLabs-compatible HTTP calls; no graph-node integration (a
voice node would be a follow-up). Real audio input via microphone is not captured (files only).

### Computer use / desktop automation — DONE
Goal (user, item 16): a computer-use tool (screenshot -> model sees it -> clicks/types). Frontier
feature; implemented as a validated action set with a safe dry-run default + a Windows PowerShell
backend. Pure R.

DONE:
- `R/computer.R` (new module) exports:
  - `computer_use(action, ..., dry_run=TRUE)` — validates the action ("screenshot", "move", "click",
    "type", "key", "scroll") and its required args (screenshot->path, move/click->x,y, type->text,
    key->keys, scroll->dy); with dry_run=TRUE echoes `{action, dry_run:true, ...args}` as JSON; with
    dry_run=FALSE runs a Windows PowerShell backend (System.Drawing CopyFromScreen for screenshots;
    user32.dll SetCursorPos/mouse_event for mouse; System.Windows.Forms.SendKeys for typing/keys) and
    returns `{action, dry_run:false, ok:true, ...}`.
  - `tool_computer_use(dry_run=TRUE)` — a `tool()` named "computer" with an action enum + optional
    x/y/text/keys/path/dy/button params; its handler is SELF-CONTAINED (base R + jsonlite + system2),
    built via a `make_handler(dry_run)` factory so it serializes into the tool server.
- `NAMESPACE`: exports `computer_use`, `tool_computer_use`. Two new `man/*.Rd`.
- Tests: `tests/testthat/test-52-computer.R` (4 tests / 8 assertions): dry-run echo, validation
  (unknown action, missing required args), tool handler dry-run echo + validation. Real OS control
  (dry_run=FALSE) is NOT auto-tested (it would move the real mouse); screenshot pairs with the
  existing vision/image input. ALL PASS; full suite PASS (1 gated live DeepSeek skip,
  `AGENTGRAPH_API_KEY` not set).

Note: desktop automation is Windows-only (PowerShell); a cross-platform or virtual-display backend
would be a follow-up.

### Fine-tuning integration — DONE
Goal (user, item 17): create an OpenAI-compatible fine-tuning job from input/output examples and get
the fine-tuned model ID. Pure R (curl, Suggests).

DONE:
- `R/finetune.R` (new module) exports:
  - `fine_tune(provider, examples, model="gpt-4o-mini", suffix=NULL, n_epochs=NULL)` — converts
    examples to OpenAI chat JSONL (`.to_finetune_jsonl`), uploads via multipart `POST /files`
    (`purpose="fine-tune"`), then `POST /fine_tuning/jobs` with `{model, training_file[, suffix,
    hyperparameters.n_epochs]}`; returns the job ID.
  - `fine_tune_status(job_id, provider)` — `GET /fine_tuning/jobs/<id>`; returns the job list object
    (`fine_tuned_model` set once `status=="succeeded"`).
  - `fine_tune_list(provider)` — `GET /fine_tuning/jobs` -> the `data` array.
  - `fine_tune_cancel(job_id, provider)` — `POST /fine_tuning/jobs/<id>/cancel`.
  - `fine_tune_wait(job_id, provider, timeout=600, poll_interval=5)` — polls until a terminal state.
  - `.to_finetune_jsonl(examples)` — accepts a data.frame OR named list (`input` + `output`/`expected`/
    `correction`) or a list of `list(input, output)` pairs; emits one `{"messages":[user,assistant]}`
    JSON line per example.
- `tests/testthat/mock/fine_tune_mock.py` (new) + `helper-mocks.R` `start_fine_tune_mock()`.
- `NAMESPACE`: exports `fine_tune`, `fine_tune_status`, `fine_tune_list`, `fine_tune_cancel`,
  `fine_tune_wait`. Five new `man/*.Rd`.
- Tests: `tests/testthat/test-53-finetune.R` (4 tests / 13 assertions): full create/status/list/cancel
  round-trip vs the mock, list-pairs + eval_dataset examples, JSONL format, validation. ALL PASS; full
  suite PASS (1 gated live DeepSeek skip, `AGENTGRAPH_API_KEY` not set).

Fix during validation: `eval_dataset()` returns a named list (input/expected vectors), not a list of
pairs, so `.to_finetune_jsonl` now detects the "vector form" (`input` atomic) and converts it.

### Plugin / extension system — DONE
Goal (user, item 18): a registration hook so third-party packages can extend agentgraph from their
`.onLoad()`. Pure R. Vector-store backends are deferred (they are C++ XPtr objects; a C++ callback
backend would be needed).

DONE:
- `R/plugin.R` (new module) exports:
  - `register_plugin(kind, name, factory, overwrite=FALSE)` — registers a factory in a package env
    (`.agentgraph_plugins`, key `kind::name`); errors on duplicate unless overwrite; validates kind/
    name (single non-empty, no `::`) and that factory is a function.
  - `call_plugin(kind, name, ...)` — invokes the factory; errors "plugin not found".
  - `has_plugin(kind, name)`, `list_plugins(kind=NULL)` (data.frame kind/name), `unregister_plugin`.
  - `register_provider(name, factory)` / `provider(name, ...)` — provider extension point (factory
    returns a provider config list).
  - `register_tool(name, tool)` / `get_tool(name)` — tool extension point (registers a ready-made
    `tool()` object via a zero-arg factory).
- `NAMESPACE`: exports `register_plugin`, `call_plugin`, `has_plugin`, `list_plugins`,
  `unregister_plugin`, `register_provider`, `provider`, `register_tool`, `get_tool`. Nine `man/*.Rd`.
- Tests: `tests/testthat/test-54-plugin.R` (6 tests / 16 assertions): register/call/list/unregister,
  duplicate + overwrite, validation, provider dispatch, tool round-trip, tool validation. ALL PASS;
  full suite PASS (1 gated live DeepSeek skip, `AGENTGRAPH_API_KEY` not set).

Note: the generic `provider(name, ...)` is a NEW dispatcher distinct from `provider_openai()` etc.

### SSE (Server-Sent Events) server — DONE
Goal (user, item 19): a server that streams an agent's tokens to a browser as `text/event-stream`.
Pure R + a subprocess httpuv server (same pattern as a2a_server/serve_agent).

DONE:
- `inst/tools/sse_server.R` (new subprocess): serves `GET /health` (open) and `GET|POST /stream` (auth).
  For `/stream` it runs `run_agent(agent, input, on_token=...)`, emitting each token as
  `data: <token>\n\n` and finishing with `data: [DONE]\n\n`, returned with
  `Content-Type: text/event-stream` + `Cache-Control: no-cache`. Input via POST JSON body
  `{"input":"..."}` or GET `?input=...` (URL-decoded). `randomPort()` + ready file + service loop.
- `R/sse.R` (new module) exports:
  - `start_sse_server(target, host="127.0.0.1", port=0, auth_token=NULL, name="agent", timeout=30)` —
    accepts an agent or graph (graphs normalized via `new_agent`); rejects `router_agent()`.
  - `sse_stop(server)` / `print.agentgraph_sse_server`.
- `NAMESPACE`: exports `start_sse_server`, `sse_stop` + `S3method(print, agentgraph_sse_server)`.
  Three new `man/*.Rd`.
- Tests: `tests/testthat/test-55-sse.R` (4 tests / 11 assertions): target validation, POST SSE stream
  (tokens + `[DONE]` + `text/event-stream` content-type), GET query-string stream, auth (401/200).
  ALL PASS; full suite PASS (1 gated live DeepSeek skip, `AGENTGRAPH_API_KEY` not set).

Fixes during validation: (1) httpuv's `req$QUERY_STRING` INCLUDES the leading `?`, so the GET parser
must `sub("^\\?", "", qs)` first; (2) `start_stream_mock()` uses `jsonlite::toJSON(auto_unbox=TRUE)`,
which unboxes a length-1 token vector to a scalar and breaks the Python mock — tests must pass >= 2
tokens.

Note: the SSE body is delivered as one complete response after the run (tokens are captured then
emitted), not truly token-by-token live; genuine incremental streaming would require httpuv's
connection-streaming or WebSocket (follow-up).

### Phase: DeepSeek live testing + break-the-framework + bug fixes (2026-09-16)
Live DeepSeek testing (25/25 relevant test types passed) and adversarial robustness pass
(55 malformed-constructor probes, 17 isolated-subprocess crash probes — all graceful, no
segfault/hang; 4 stress tests OK; secret scan clean; golden master OK) are recorded in
`test.md` sections 1-4. Findings triaged into 2 genuine bugs, both FIXED:

1. `is_agent()` not exported — defined in `R/agents.R`, used by 10 internal call sites, but missing
   from NAMESPACE (external `agentgraph::is_agent()` failed). Fixed: `@export` roxygen tag added,
   `roxygen2::roxygenise()` run, `man/is_agent.Rd` generated, NAMESPACE now has `export(is_agent)`.
2. Cryptic deferred validation — malformed constructor args were accepted at build time and only
   failed at run time with Rcpp errors like `Not compatible with STRSXP: [type=NULL].`.
   Fixed with fail-fast validation in pure R (no C++/DLL rebuild needed):
   - `R/graph.R` `state_graph()`: entry must be single non-empty string; max_iterations >= 1.
   - `R/graph.R` `add_node()`: id non-empty string; node must be a list with `$type`
     (all 6 node constructors set `type`, verified).
   - `R/graph.R` `route_on()`: field non-empty string.
   - `R/nodes.R` `llm_node()`: provider not NULL.
   - `R/state.R` `user_msg()/system_msg()/assistant_msg()`: content not NULL (multimodal content
     lists from `content_parts()` stay legal).
   - `R/tools.R` `tool()`: name non-empty string; handler must be an R function.
   - `R/providers.R` `provider_openai()`: max_tokens/temperature/max_retries must be non-negative
     (0 max_tokens stays legal = provider default).
   Deliberately NOT changed: duplicate `add_node` IDs (standard R list overwrite), edge endpoints
   (run-time validated because edges may be added before the nodes they reference), `window_size`
   (<= 0 = disabled), empty `param_*` names.

   Verification: 36/36 targeted checks passed (each validation fires with the intended message;
   all valid construction paths incl. react_agent/chat_agent/golden mermaid unchanged). Full
   offline suite re-run after fixes: PASS (56 files, 1 gated live skip).

Harness gotchas hit during this phase (NOT framework bugs): testthat `test_dir()` does NOT
auto-attach the package (unlike `R CMD check`) — runner scripts need `library(agentgraph)`;
`graph_mermaid()` returns a character vector (paste-collapse before grepl); PowerShell `2>&1`
piping can break `make`'s stdout during `R CMD INSTALL` (exit 1, "make: write error: stdout") —
redirect install output to a file with `*>` instead; `processx` `proc$wait()` returns non-logical,
use `proc$is_alive()` + `proc$get_exit_status()` for crash probes.

## Key file map
- Build config: `src/Makevars` (unix), `src/Makevars.win` (windows), `DESCRIPTION`.
- R API: `R/run.R`, `R/providers.R`, `R/local.R`, `R/graph.R`, `R/nodes.R`, `R/tools.R`, `R/prebuilt.R`,
  `R/agents.R`, `R/eval.R`, `R/prompts.R`, `R/batch.R`, `R/a2a.R`, `R/pii.R`, `R/guard.R`,
  `R/policy.R`, `R/cost.R`, `R/serve.R`, `R/async.R`, `R/mock.R`, `R/metrics.R`, `R/tenant.R`,
  `R/audit.R`, `R/versioning.R`, `R/feedback.R`, `R/voice.R`, `R/computer.R`, `R/finetune.R`,
  `R/plugin.R`, `R/sse.R`, `R/vector.R`, `R/monitor.R`, `R/ui-helpers.R`, `R/state.R`,
  `R/tool_server.R`.
- C++ core: `src/core/`, `src/llm/`, `src/graph/`, `src/tools/`, `src/vector/`.
- Bridge: `src/rcpp_exports.cpp`, `src/type_converters.cpp/.h`.
- Vendored libs: `inst/include/{hnswlib,nlohmann,spdlog,stduuid,concurrentqueue,httplib.h}`.

## Build & test notes
- C++20 required. Unix links `-lcurl -lpthread`; Windows links `-lwinhttp -lws2_32`.
- `Rscript` / `R` are NOT on the shell PATH in this environment; use the user's R/Positron
  to rebuild and run tests, or locate `R.exe` explicitly.
- Real tests (not mocks) are preferred. hnswlib search is the fastest thing to test first
  (no API key or server needed).

## Demo apps
- `subscription-agent/`: console ReAct agent (`main.R`). Fixed 2026-09-18: `main.R` is now
  self-locating (if `config.R` is not in the wd, it setwd()s to the app dir — mirrors
  `support-agent/app.R`), so `source("main.R")` / `Rscript main.R` work from any directory.
  Live test turn against DeepSeek (model `deepseek-flash`) verified OK 2026-09-18.
  Also guards `AGENTGRAPH_DB_PATH`: if inherited from another app's session (support-agent
  uses the same env var), it is unset so subscription data lands in its own sqlite file.
  NOTE: the self-locating preamble only runs AFTER source() opens the file, so bare
  `source("main.R")` still requires the app dir. Added repo-root launcher
  `start_subscription_agent.R` (sources main.R by absolute path) so
  `source("start_subscription_agent.R")` works from the repo root.
  main.R now prints an explanatory message when stdin closes (EOF) instead of exiting
  silently — the silent exit made it look like the agent was running when it wasn't,
  so a message typed at the R prompt raised "object 'hello' not found" (2026-09-18).
  2026-09-18: console wd keeps resetting to the repo root between sessions, so a root-level
  `main.R` forwarder was added (relative `subscription-agent/main.r` first, then absolute) making
  the habitual `source("main.R")` work from both the repo root and the app dir.
- `support-agent/`: Shiny dashboard (`app.R`); launch from anywhere via
  `shiny::runApp("c:/Users/berry/Desktop/langgraphc++/support-agent/app.R")`.

## User preferences
- Keep R as the primary API; C++ for heavy work.
- Take large tasks step-by-step; write files one at a time if output is long.
- Prefer real tests over mocks.
- The user is building a movie subscription/ticketing agent app (monthly $300 / annual $1000 plans)
  with registration, plan upgrade/cancel, and database persistence.
- Default output language: English.
- Do not let context compaction lose work: always persist progress to this file at every step.
  The user expects MEMORY.md to be the durable record, so update it before ending any turn that
  changed files or made decisions.
