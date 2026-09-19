# Prompt management (R/prompts.R). All tests are offline except the final
# integration test, which runs a rendered prompt through the mock LLM.

test_that("prompt_template builds and validates", {
  p <- agentgraph::prompt_template("Hello {name}, you are {age}",
                                   name = "greet", version = "1.0")
  expect_s3_class(p, "agentgraph_prompt")
  expect_identical(p$name, "greet")
  expect_identical(p$version, "1.0")
  expect_identical(p$role, "system")
  expect_identical(p$text, "Hello {name}, you are {age}")

  expect_error(agentgraph::prompt_template(""), "non-empty")
  expect_error(agentgraph::prompt_template(c("a", "b")), "single")
  expect_error(agentgraph::prompt_template(42), "single")
  expect_error(agentgraph::prompt_template("x", role = "wizard"), "role")
})

test_that("prompt_variables extracts placeholders", {
  expect_identical(
    agentgraph::prompt_variables(agentgraph::prompt_template("{a} then {b} then {a}")),
    c("a", "b")
  )
  expect_identical(
    agentgraph::prompt_variables("no placeholders here"),
    character(0)
  )
  expect_identical(
    agentgraph::prompt_variables("Hi {user.name}!"),
    "user.name"
  )
  # Non-identifier braces are literal, not variables.
  expect_identical(
    agentgraph::prompt_variables("set {1abc} and {} and {a-b}"),
    character(0)
  )
})

test_that("render_prompt substitutes, repeats, and ignores extras", {
  p <- agentgraph::prompt_template("Hi {name}! Hi {name}!")
  expect_identical(agentgraph::render_prompt(p, name = "Ada"), "Hi Ada! Hi Ada!")

  # plain string is used as-is
  expect_identical(agentgraph::render_prompt("plain text"), "plain text")

  # vars list + extra vars are both fine
  expect_identical(
    agentgraph::render_prompt(p, vars = list(name = "Bob"), unused = 1L),
    "Hi Bob! Hi Bob!"
  )
  # ... takes precedence over vars
  expect_identical(
    agentgraph::render_prompt(p, vars = list(name = "Bob"), name = "Eve"),
    "Hi Eve! Hi Eve!"
  )

  e <- err_msg(agentgraph::render_prompt(p))
  expect_true(grepl("missing value", e, fixed = TRUE))
  expect_true(grepl("name", e, fixed = TRUE))

  # all missing names reported at once
  p2 <- agentgraph::prompt_template("{x} {y} {z}")
  e2 <- err_msg(agentgraph::render_prompt(p2, y = 1))
  expect_true(grepl("x, z", e2, fixed = TRUE))

  # an unnamed positional argument is rejected
  e3 <- err_msg(agentgraph::render_prompt(p, list(name = "x")))
  expect_true(grepl("must be named", e3, fixed = TRUE))

  # vector values are rejected
  e4 <- err_msg(agentgraph::render_prompt(p, name = c("a", "b")))
  expect_true(grepl("single non-NA", e4, fixed = TRUE))

  # non-identifier braces pass through untouched
  lit <- agentgraph::prompt_template("set {1abc} and {} and {a-b}")
  expect_identical(agentgraph::render_prompt(lit), "set {1abc} and {} and {a-b}")
})

test_that("render_prompt values may contain regex/brace metacharacters", {
  p <- agentgraph::prompt_template("cost: {price}")
  out <- agentgraph::render_prompt(p, price = "$100 \\1 {wow} [end]")
  expect_identical(out, "cost: $100 \\1 {wow} [end]")

  # a value containing a placeholder-looking brace is not re-expanded
  p2 <- agentgraph::prompt_template("say {word}")
  out2 <- agentgraph::render_prompt(p2, word = "hello {name}")
  expect_identical(out2, "say hello {name}")
})

test_that("prompt_file and save_prompt round-trip", {
  dir <- tempfile(); dir.create(dir)
  f <- file.path(dir, "greeting.md")
  writeLines(c("You are {persona}.", "Answer briefly."), f)

  p <- agentgraph::prompt_file(f)
  expect_s3_class(p, "agentgraph_prompt")
  expect_identical(p$name, "greeting")
  expect_identical(p$text, "You are {persona}.\nAnswer briefly.")
  expect_identical(agentgraph::prompt_variables(p), "persona")

  out <- file.path(dir, "sub", "copy.txt")
  agentgraph::save_prompt(p, out)
  p2 <- agentgraph::prompt_file(out)
  expect_identical(p2$text, p$text)
  expect_identical(p2$name, "copy")

  e <- err_msg(agentgraph::prompt_file(file.path(dir, "nope.txt")))
  expect_true(grepl("no such file", e, fixed = TRUE))

  e2 <- err_msg(agentgraph::save_prompt("not a template", out))
  expect_true(grepl("prompt_template", e2, fixed = TRUE))
})

test_that("prompt_message renders with the template role", {
  p <- agentgraph::prompt_template("Answer about {topic}", role = "user")
  m <- agentgraph::prompt_message(p, topic = "cats")
  expect_identical(m, list(role = "user", content = "Answer about cats"))

  sys <- agentgraph::prompt_template("Be {style}", role = "system")
  expect_identical(agentgraph::prompt_message(sys, style = "kind")$role, "system")

  # raw strings default to the "user" role
  expect_identical(agentgraph::prompt_message("hi {x}", x = 1),
                   list(role = "user", content = "hi 1"))
})

test_that("prompt_registry loads a directory; add_prompt/save_registry round-trip", {
  dir <- tempfile(); dir.create(dir)
  writeLines("Greet {name} warmly.", file.path(dir, "greeter.txt"))
  writeLines("Summarize {text} in {words} words.", file.path(dir, "summarizer.md"))
  # non-prompt extensions are ignored
  writeLines("junk", file.path(dir, "notes.csv"))

  reg <- agentgraph::prompt_registry(dir)
  expect_s3_class(reg, "agentgraph_prompt_registry")
  expect_identical(sort(names(reg)), c("greeter", "summarizer"))

  expect_identical(agentgraph::render_prompt(reg$greeter, name = "Ada"),
                   "Greet Ada warmly.")

  added <- agentgraph::add_prompt(reg, agentgraph::prompt_template("Hi {who}", name = "hi"))
  expect_identical(sort(names(added)), c("greeter", "hi", "summarizer"))
  # functional style: the original registry is unchanged
  expect_identical(length(reg), 2L)

  dir2 <- tempfile()
  agentgraph::save_registry(added, dir2)
  reg2 <- agentgraph::prompt_registry(dir2)
  expect_identical(sort(names(reg2)), c("greeter", "hi", "summarizer"))
  expect_identical(reg2$summarizer$text, "Summarize {text} in {words} words.")

  # save_registry defaults to the registry's own directory
  dir3 <- tempfile(); dir.create(dir3)
  reg3 <- agentgraph::prompt_registry(dir3)
  reg3 <- agentgraph::add_prompt(reg3, agentgraph::prompt_template("A {b}", name = "a"))
  agentgraph::save_registry(reg3)
  expect_true(file.exists(file.path(dir3, "a.txt")))

  e <- err_msg(agentgraph::add_prompt(reg, agentgraph::prompt_template("x")))
  expect_true(grepl("must have a `name`", e, fixed = TRUE))

  e2 <- err_msg(agentgraph::save_registry(agentgraph::prompt_registry()))
  expect_true(grepl("no path", e2, fixed = TRUE))

  e3 <- err_msg(agentgraph::prompt_registry(tempfile()))
  expect_true(grepl("no such directory", e3, fixed = TRUE))
})

test_that("print methods show name, variables, and registry contents", {
  p <- agentgraph::prompt_template("Say {word}", name = "talk", version = "2")
  out <- capture.output(print(p))
  expect_true(any(grepl("'talk'", out, fixed = TRUE)))
  expect_true(any(grepl("v2", out, fixed = TRUE)))
  expect_true(any(grepl("word", out, fixed = TRUE)))
  expect_true(any(grepl("Say {word}", out, fixed = TRUE)))

  reg <- agentgraph::add_prompt(agentgraph::prompt_registry(), p)
  out2 <- capture.output(print(reg))
  expect_true(any(grepl("1 prompt", out2, fixed = TRUE)))
  expect_true(any(grepl("talk:", out2, fixed = TRUE)))
})

test_that("rendered prompts flow into agent system prompts (mock LLM)", {
  testthat::skip_if_not(python_available())
  m <- start_mock_llm(list(list(content = "ok")))
  on.exit(stop_py_mock(m), add = TRUE)

  provider <- agentgraph::provider_openai(
    api_key = "test", model = "mock-model",
    base_url = paste0("http://127.0.0.1:", m$port),
    max_retries = 0L
  )
  tpl <- agentgraph::prompt_template("You are a {persona} assistant.", name = "sys")
  agent <- agentgraph::chat_agent(
    provider,
    system_prompt = agentgraph::render_prompt(tpl, persona = "pirate")
  )
  r <- agentgraph::run_agent(agent, "hello")

  expect_identical(r$answer, "ok")
  Sys.sleep(0.3)
  expect_identical(sys_prompts(m$log)[1], "You are a pirate assistant.")
})
