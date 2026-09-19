# agentgraph

Build agentic AI applications in R with a graph orchestration engine written in C++20.

Define agents, tools, and workflows in R. The C++ engine handles graph execution, state management, tool calling, conditional routing, parallel fan-out, and streaming token output — with a native WinHTTP client (no R HTTP involvement).

## What it does

`agentgraph` lets you build the classic agent loop — **LLM thinks → calls a tool → tool runs → LLM sees the result → repeats** — plus arbitrary multi-node workflows (including parallel multi-agent fan-out and real-time streaming), all defined declaratively in R and executed by a C++ engine.

## Status

**Phases 0-7 (working)**: package skeleton, C++ core types, graph engine, tool registry, built-in tools, the R↔C++ bridge, a **native C++ HTTP client** (WinHTTP/Schannel on Windows), **true parallel LLM calls** via a C++ thread pool, **parallel fan-out/fan-in** (multi-agent), **streaming token output** (SSE → R callback), **subgraphs** (graphs embedded as nodes, arbitrary nesting), **human-in-the-loop** (`interrupt_node()` + `resume()` with resume-path checkpointing through nested subgraphs), and **thread-safe custom R tools** (isolated R tool-server process). The agent loop, parallel multi-agent execution, live streaming, subgraphs, interrupt/resume, and custom-tool execution all run end-to-end.

## Requirements

- R >= 4.1.0
- Rtools45 (Windows) or a C++20 compiler (macOS/Linux)
- R packages: `Rcpp`, `jsonlite`, `processx` (managed automatically as Imports)

## Quick start

```r
library(agentgraph)

# 1. Configure a provider (uses OPENAI_API_KEY env var by default)
provider <- provider_openai(model = "gpt-4o")

# 2. Build a graph: agent -> tools -> agent -> end
graph <- state_graph(entry = "agent") |>
  add_node("agent", llm_node(
    provider = provider,
    system_prompt = "You are a helpful assistant.",
    tools = "calculator"
  )) |>
  add_node("tools", tool_node()) |>
  add_conditional_edge("agent", route_on(
    field = "has_tool_calls",
    rules = c("true" = "tools", "false" = "__end__")
  )) |>
  add_edge("tools", "agent")

# 3. Run it
result <- run(
  graph,
  state = list(messages = list(user_msg("What is 3 + 4?"))),
  tools = list()
)

# The assistant's final answer
tail(result$messages, 1)[[1]]$content
```

## Parallel LLM calls

Fire many LLM requests at once on a native C++ thread pool:

```r
provider <- provider_openai(model = "gpt-4o")

# 10 prompts, 5 concurrent requests
prompts <- lapply(1:10, function(i) list(user_msg(paste0("Summarize topic ", i))))
responses <- chat_parallel(prompts, provider, n_threads = 5)

responses[[1]]$content  # first answer
```

## Multi-agent (parallel fan-out)

Run several specialized agents concurrently inside the graph:

```r
provider <- provider_openai(model = "gpt-4o")

graph <- state_graph(entry = "fan_out") |>
  add_node("fan_out", parallel_node(c("researcher", "critic", "writer"))) |>
  add_node("researcher", llm_node(provider, system_prompt = "You research facts.")) |>
  add_node("critic",    llm_node(provider, system_prompt = "You critique claims.")) |>
  add_node("writer",    llm_node(provider, system_prompt = "You write the report.")) |>
  add_edge("fan_out", "__end__")

result <- run(graph, state = list(messages = list(user_msg("Analyze X."))),
              n_threads = 3)
```

The three agents run simultaneously on the C++ thread pool and their outputs
merge into the shared state.

## Subgraphs

Embed a whole graph as a single node. Nested graphs share the parent state,
so values set inside are visible after it returns. Nesting is arbitrary (a
subgraph can itself contain subgraphs).

```r
review <- state_graph(entry = "ask") |>
  add_node("ask", llm_node(provider, system_prompt = "Review the draft.")) |>
  add_edge("ask", "__end__")

pipeline <- state_graph(entry = "review") |>
  add_node("review", subgraph_node(review)) |>
  add_edge("review", "__end__")
```

## Human-in-the-loop (interrupt / resume)

Pause a graph at an `interrupt_node()` and hand control back to R; resume later
with the full state preserved (including through nested subgraphs).

```r
gate <- state_graph(entry = "approve") |>
  add_node("approve", interrupt_node()) |>
  add_edge("approve", "__end__")

state <- run(gate, list(user_msg("draft v1")))
is_interrupted(state)          # TRUE — waiting for a human

state <- resume(gate, state, inject = list(approved = TRUE))  # human decides
is_interrupted(state)          # FALSE — done
```

## Built-in tools

| Tool | Description |
|------|-------------|
| `calculator` | Evaluate a math expression |
| `read_file` | Read a file's contents |
| `write_file` | Write content to a file |

> **Security:** the native `read_file`/`write_file` tools run in-process and
> accept any path the model produces. Sandbox them with
> `file_tools_policy(allow = "...")` (or the `AGENTGRAPH_FS_ALLOW` /
> `AGENTGRAPH_FS_DENY` env vars) before exposing them to untrusted input, and
> see [SECURITY.md](SECURITY.md) for the full threat model.

## Custom tools

```r
weather_tool <- tool(
  name = "get_weather",
  description = "Get the weather for a city",
  parameters = list(
    city = param_string("City name")
  ),
  handler = function(args_json) {
    args <- jsonlite::fromJSON(args_json)
    jsonlite::toJSON(list(temp = 22, condition = "sunny"), auto_unbox = TRUE)
  }
)
```

### Thread-safe execution (isolated tool server)

While a graph runs, the main R thread is blocked inside the C++ engine, so the
engine cannot call R tool handlers directly — especially not from its worker
threads during parallel fan-out. Instead, whenever `run()` or `resume()` is
given custom tools, the package:

1. serializes the handlers into a fresh **isolated R process** (the *tool
   server*, `inst/tools/tool_server.R`),
2. binds a local TCP port, and
3. lets the C++ engine call handlers over a newline-framed JSON protocol
   (`src/tools/rpc_tool_client.cpp`) — a single shared connection guarded by a
   mutex, so concurrent worker threads are safe.

Handlers receive the same `args_json` string and return the same JSON string
as before, so tool definitions don't change. Handler errors surface as
`{"error": ...}` tool messages, exactly like in-process failures. The server
process is started and stopped automatically per `run()`/`resume()` call.


## Architecture

```
R (defines graph, tools, prompts)
  │
  ├── run()/resume() spawns tool server (isolated R process, TCP)
  │       ▲                    │
  │       └── JSON RPC ────────┘
  ▼
Rcpp bridge (graph config + state handoff)
  │
  ▼
C++ engine (graph scheduler, tool registry, state store)
  │
  ├── Native HTTP client (WinHTTP/Schannel on Windows)
  │     └── LLM provider (OpenAI-compatible, Anthropic, Ollama)
  │
  ├── Tool server client (custom R tools, thread-safe)
  │
  └── C++ thread pool (parallel fan-out, multi-agent)
```

## Directory layout

- `R/` — user-facing R API (graph, nodes, tools, providers, run, chat)
- `src/core/` — C++ types, config, state, errors
- `src/graph/` — graph structure, executor, node runner, router
- `src/tools/` — tool registry and built-in tools
- `src/llm/` — native HTTP client (WinHTTP) and LLM clients
- `inst/include/` — vendored header-only libraries (nlohmann/json, BS::thread_pool)

## Streaming output

Stream tokens to R in real time (ChatGPT-style):

```r
graph <- state_graph(entry = "agent") |>
  add_node("agent", llm_node(provider)) |>
  add_edge("agent", "__end__")

stream(graph,
  state = list(messages = list(user_msg("Write a haiku about autumn."))),
  on_token = function(token) cat(token))
```

`on_token` is called from C++ as each SSE chunk arrives — no R HTTP round-trip.

## Roadmap

All planned phases (0-7) are complete. Possible future work:

- Persistence / checkpointing of graph state across sessions
- More provider-specific clients (native Anthropic API, tool-use schemas)
- Third-party R UI libraries for agent interfaces
