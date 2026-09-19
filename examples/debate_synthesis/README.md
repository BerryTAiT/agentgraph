# debate_synthesis

A standalone example project built **on top of** the `agentgraph` R package. It
exists to stress-test the framework under realistic use and double as living
documentation of its graph API.

A question is debated by three specialist agents running **concurrently**, then
a synthesizer merges their positions into a verdict. A human approval gate can
interrupt the run and resume it.

```
(entry: lead --web_search) -> (lead_tools -> loop) -> (fan_out parallel)
      +--- debater_pro   \
      +--- debater_con    +--> (synthesize  --optional human gate) -> __end__
      +--- debater_neutral/
```

## What this project exercises in the framework

| Capability               | API used                                  | Proved by |
|--------------------------|-------------------------------------------|-----------|
| Graph construction       | `state_graph()` / `add_node()` / `add_edge()` | 7 nodes, 7 edges build |
| Parallel fan-out         | `parallel_node()`                          | 3 debaters run concurrently on the C++ thread pool |
| Shared-state merging     | one message history                        | 3 *distinct* debater turns land in state |
| Conditional routing      | `add_conditional_edge()` + `route_on()`    | lead loops through its tool, then fans out |
| Built-in tools           | `llm_node(tools="web_search")` + `tool_node()` | tool call resolves to a tool node |
| Evaluation               | `evaluate()` + `eval_dataset()` + `eval_contains()` | synthesis scored against criteria |
| Interrupt / resume (HITL)| `interrupt_node()` + `resume(inject=)`     | graph pauses at gate, resumes with injected review |
| Kill-switch guardrails   | `run(max_total_tokens=, max_time_sec=, max_cost_usd=)` | documented in `run_debate()` |
| Offline determinism       | `provider_mock()` (sequence mode)         | whole demo runs with **no API key** |

## Files

- `run_debate.R` — the graph builder, evaluator, runner, and CLI. The core is
  `build_debate_graph()`; the `main()` function is a thin driver.
- `self_test.R` — offline test (17 assertions) proving the graph builds, the
  fan-out writes distinct shared-state turns, evaluation scores PASS, and the
  interrupt/resume round-trip works. No key or network needed.

## Usage

```bash
# Deterministic offline run (mock provider, no API key)
Rscript run_debate.R
Rscript run_debate.R --eval            # also run the evaluator

# Real provider
Rscript run_debate.R --live --topic="Should homework be banned?"

# Offline verification
Rscript self_test.R
```

Example offline output (sequence-mode mock):

```
graph : nodes = 7 , edges = 7 , fan-out targets = 3
  [node_start] lead
  [parallel_end] fan_out
  [node_start] synthesize
  [complete]

---- assistant turns ----
[ 1] I am the coordinator. I will open the debate and then hand off...
[ 2] I argue FOR the proposition. Reason one, reason two, reason three.
[ 3] I argue AGAINST the proposition. Objection one, objection two, ...
[ 4] I take a NEUTRAL stance. Consideration one, consideration two, ...
[ 5] Verdict: weighing the arguments for and against, the balanced...

agentgraph evaluation: 2 examples, 1 evaluator
overall: PASS
```

## Notes

- `evaluate()`'s target for scoring is `debate_answer()`, which returns only the
  synthesizer's verdict text; that is what `eval_contains(c("for","against",
  "verdict"))` scores.
- Interrupt/resume uses the identical pattern to the framework's own
  `test-07-interrupt.R`: run to the `interrupt_node`, then `resume(..., inject=)`.
- The mock provider keys on the **last user message**; since every node shares
  the same topic, use **sequence mode** (an unnamed character vector) when you
  want each concurrent debater to return distinct canned content.