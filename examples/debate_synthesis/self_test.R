# Offline self-test for the debate_synthesis example project.
# Verifies the graph runs, parallel fan-out writes distinct shared-state
# turns, evaluation scores PASS, and checkpoint/resume round-trips.
# No API key or network required.
#
# Run:   Rscript self_test.R
# Exit:  0 = all passed, 1 = any failure

library(agentgraph)

`%||%` <- function(a, b) if (is.null(a)) b else a
source("run_debate.R")  # reuses build_debate_graph/run_debate/debate_answer

pass <- 0L; fail <- 0L
ok <- function(label, cond) {
  if (isTRUE(cond)) { pass <<- pass + 1L; cat("PASS |", label, "\n") }
  else             { fail <<- fail + 1L; cat("FAIL |", label, "\n") }
}

mock <- function() provider_mock(responses = c(
  "Open the debate and hand off.",
  "FOR: reason one. FOR: reason two.",
  "AGAINST: objection one. AGAINST: objection two.",
  "NEUTRAL: consideration one.",
  "FINAL VERDICT: balanced conclusion weighing both sides."))

## 1. graph builds with expected topology
g <- build_debate_graph(mock(), "Test topic")
ok("graph has 7 nodes", length(g$nodes) == 7L)
ok("graph has 7 edges", length(g$edges) == 7L)
ok("fan_out targets 3 debaters",
   length(g$nodes[["fan_out"]]$sub_node_ids) == 3L)
id_ok <- all(c("debater_pro","debater_con","debater_neutral") %in% names(g$nodes))
ok("all three debaters registered", id_ok)

## 2. run produces 5 assistant turns, 3 distinct fan-out turns
st <- run_debate(g, "Should homework be banned?")
as_msgs <- Filter(function(m) m$role == "assistant", st$messages)
ok("5 assistant turns", length(as_msgs) == 5L)
ok("synthesizer verdict is last",
   grepl("FINAL VERDICT|verdict", tail(as_msgs, 1)[[1]]$content, ignore.case = TRUE))
fan_texts <- vapply(as_msgs[2:4], function(m) m$content, "")
ok("3 distinct fan-out turns",
   length(unique(fan_texts)) == 3L)
ok("pro turn present", any(grepl("FOR", fan_texts)))
ok("con turn present", any(grepl("AGAINST", fan_texts)))
ok("neutral turn present", any(grepl("NEUTRAL", fan_texts)))

## 3. evaluation passes
ev <- evaluate(
  function(input) debate_answer(
    provider_mock(responses = c(
      "Open the debate.",
      "FOR: reason. AGAINST: counter. NEUTRAL: middle.",
      "Verdict: the conclusion weighs arguments for and against."
    )), input),
  dataset = eval_dataset(c("Should homework be banned?",
                           "Should remote work be the default?")),
  evaluators = list(
    eval_contains(needles = c("for", "against", "verdict"), all = TRUE)
  )
)
ok("evaluation overall PASS", isTRUE(ev$passed))
ok("evaluation mean_score = 1", ev$summary$mean_score[1] == 1)

## 4. interrupt + resume round-trip (human-in-the-loop checkpointing)
# A human approval gate interrupts the debate before the verdict, then
# resume() continues with injected review values.
gm <- provider_mock(responses = list(
  "Write the FINAL verdict for and against and a conclusion."
))
gi <- state_graph(entry = "gate") |>
  add_node("gate", interrupt_node()) |>
  add_node("synthesize", llm_node(provider = gm, system_prompt = "finalize")) |>
  add_edge("gate", "synthesize") |>
  add_edge("synthesize", "__end__")

interrupted <- run(gi, state = list(messages = list(user_msg("Interrupt test"))))
ok("graph interrupts for human approval", isTRUE(is_interrupted(interrupted)))
ok("resume node recorded",
   identical(jsonlite::fromJSON(interrupted$data[["__resume_node__"]]), "synthesize"))

final <- resume(gi, interrupted, inject = list(approved = TRUE, reviewer = "alice"))
ok("resume completes (no longer interrupted)", !isTRUE(is_interrupted(final)))
ok("injected review value reached state", identical(final$data[["approved"]], "true"))
last_turn <- tail(Filter(function(m) m$role == "assistant", final$messages), 1)[[1]]
ok("resumed run produced a verdict",
   grepl("verdict|conclusion", last_turn$content, ignore.case = TRUE))

cat(sprintf("\nSELF-TEST RESULT: %d passed, %d failed\n", pass, fail))
if (fail > 0L) quit(status = 1L)
cat("ALL PASS\n")