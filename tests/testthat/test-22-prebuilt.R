test_that("pre-built tools construct with the expected names and schemas", {
  expect_identical(tool_web_search()$name, "web_search")
  expect_identical(tool_wikipedia()$name, "wikipedia_search")
  expect_identical(tool_arxiv()$name, "arxiv_search")
  expect_identical(tool_http_request()$name, "http_request")
  expect_identical(tool_code_exec()$name, "code_exec")
  expect_identical(tool_read_csv()$name, "read_csv")
  expect_identical(tool_read_pdf()$name, "read_pdf")
  expect_identical(tool_sql()$name, "sql_query")

  for (t in list(tool_web_search(), tool_wikipedia(), tool_arxiv(),
                 tool_http_request(), tool_code_exec(), tool_read_csv(),
                 tool_read_pdf(), tool_sql())) {
    pj <- jsonlite::fromJSON(t$parameters_json)
    expect_identical(pj$type, "object")
    expect_true(is.list(pj$properties))
  }

  h <- jsonlite::fromJSON(tool_http_request()$parameters_json)
  expect_identical(h$properties$method$enum, c("GET", "POST", "PUT", "DELETE"))
})

test_that("pre-built handlers reject missing required arguments without network", {
  expect_match(err_msg(tool_web_search()$handler("{}")), "query")
  expect_match(err_msg(tool_wikipedia()$handler("{}")), "query")
  expect_match(err_msg(tool_arxiv()$handler("{}")), "query")
  expect_match(err_msg(tool_http_request()$handler("{}")), "url")
  expect_match(err_msg(tool_code_exec()$handler("{}")), "code")
  expect_match(err_msg(tool_read_csv()$handler("{}")), "path")
})

test_that("code execution tool evaluates R and captures output", {
  t <- tool_code_exec()
  res <- jsonlite::fromJSON(t$handler(jsonlite::toJSON(list(code = "1 + 1"), auto_unbox = TRUE)))
  expect_true(res$ok)
  expect_match(res$output, "2")

  bad <- jsonlite::fromJSON(t$handler(jsonlite::toJSON(list(code = "stop('boom')"), auto_unbox = TRUE)))
  expect_false(bad$ok)
  expect_match(bad$error, "boom")
})

test_that("CSV reader returns column names and a bounded preview", {
  f <- tempfile(fileext = ".csv")
  writeLines("a,b\n1,2\n3,4\n5,6", f)
  on.exit(unlink(f))

  t <- tool_read_csv(max_rows = 2L)
  res <- jsonlite::fromJSON(t$handler(jsonlite::toJSON(list(path = f), auto_unbox = TRUE)))
  expect_identical(res$rows, 3L)
  expect_identical(res$columns, c("a", "b"))
  expect_identical(nrow(res$data), 2L)
})

test_that("SQL tool queries a SQLite database", {
  skip_if_not_installed("DBI")
  skip_if_not_installed("RSQLite")

  db <- tempfile(fileext = ".sqlite")
  con <- DBI::dbConnect(RSQLite::SQLite(), db)
  DBI::dbWriteTable(con, "t", data.frame(x = 1:3))
  DBI::dbDisconnect(con)

  t <- tool_sql(db_path = db)
  res <- jsonlite::fromJSON(t$handler(jsonlite::toJSON(list(query = "SELECT count(*) AS n FROM t"), auto_unbox = TRUE)))
  expect_identical(res$n, 3L)
})
