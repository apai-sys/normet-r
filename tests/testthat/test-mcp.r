# normet for an AI agent: the readings, the tools, the jobs and the MCP server.

agent_in <- function() {
  home <- tempfile("normet-mcp-")
  .nm_agent(home, roots = c(home, tempdir()))
}

test_that("numbers and tables are written as normet-py writes them", {
  expect_equal(.nm_num(3160000), "3.160e+06")
  expect_equal(.nm_num(104000), "1.04e+05")
  expect_equal(.nm_num(0.002885), "0.002885")
  expect_equal(.nm_num(0.0001801), "1.801e-04")
  expect_equal(.nm_num(NA), "—")
  expect_equal(.nm_num(0), "0")
  tab <- .nm_text_table(c("set", "R²"), list(list("testing", 0.5), list("all", NA)))
  expect_equal(strsplit(tab, "\n")[[1]], c("set      R²", "-------  ---", "testing  0.5", "all      —"))
})

test_that("a table's reading says its span, its step and each column's role", {
  a <- agent_in()
  said <- .nm_agent_inspect_data(a, example = "my1", target = "NO2")
  expect_match(said, "my1.csv: 5,793 rows × 11 columns.", fixed = TRUE)
  expect_match(said, "Usual step 1h; 5,793 of 5,856 timestamps at that step present (63 missing).", fixed = TRUE)
  expect_match(said, "NO2         pollutant (target)", fixed = TRUE)
  expect_match(said, "ws          met                 0 (0.0%)  0.1032     4.001      14.23      0.002885",
               fixed = TRUE)
  panel <- .nm_agent_inspect_data(a, example = "scm")
  expect_match(panel, "A panel: 104 units in column 'code'", fixed = TRUE)
})

test_that("files outside the folders allowed are refused", {
  a <- agent_in()
  expect_error(.nm_agent_path(a, "/definitely/not/allowed.csv"), "outside the folders normet may use")
  expect_error(.nm_agent_inspect_data(a), "give one of data=")
  expect_error(nm_agent_tool("normet_inspect_data", list(example = "nope"), home = a$store$home),
               "no example 'nope'")
})

test_that("a job's script is the R it runs", {
  a <- agent_in()
  # Queued behind one that is running, so this one does not start.
  blocker <- .nm_job_submit(a$store, "cv", "Sys.sleep(60)")
  on.exit(.nm_job_cancel(a$store, blocker$id), add = TRUE)
  said <- .nm_agent_start_do_all(a, "NO2", c("ws", "wd"), example = "my1", n_samples = 5)
  id <- sub("^Started job (\\S+) .*", "\\1", strsplit(said, "\n")[[1]][1])
  expect_match(said, "queued, 1 ahead of it", fixed = TRUE)
  script <- readLines(file.path(a$store$root, id, "job.R"))
  expect_true("library(normet)" %in% script)
  expect_true(any(grepl('covariates = c("ws", "wd", "date_unix", "day_julian", "weekday", "hour")',
                        script, fixed = TRUE)))
  expect_true(any(grepl('resample_vars = c("ws", "wd")', script, fixed = TRUE)))
  expect_silent(parse(text = script))
  # Cancelled while it waits: it never starts.
  expect_match(.nm_agent_cancel_job(a, id), ": cancelled.", fixed = TRUE)
  expect_equal(.nm_job_state(a$store, id), "cancelled")
})

test_that("a running job is stopped, and the next starts", {
  a <- agent_in()
  first <- .nm_job_submit(a$store, "cv", "Sys.sleep(60)")
  second <- .nm_job_submit(a$store, "cv", "writeLines('ran', 'out.txt')")
  deadline <- Sys.time() + 30
  while (is.null(.nm_read_json(file.path(first$folder, "started.json"))) && Sys.time() < deadline) {
    Sys.sleep(0.2)
  }
  expect_equal(.nm_job_state(a$store, first$id), "running")
  expect_equal(.nm_job_cancel(a$store, first$id)$state, "cancelled")
  done <- .nm_job_wait(a$store, second$id, timeout = 60)
  expect_equal(done$state, "done")
  expect_equal(readLines(file.path(second$folder, "out.txt")), "ran")
})

test_that("a do-all job runs, and its status reads the model and the series", {
  skip_if_not_installed("lightgbm")
  a <- agent_in()
  data <- file.path(a$store$home, "my1_short.csv")
  dir.create(dirname(data), recursive = TRUE, showWarnings = FALSE)
  data.table::fwrite(my1[1:1500, ], data)
  said <- .nm_agent_start_do_all(a, "NO2", c("ws", "wd", "temp"), data = data, n_samples = 3)
  id <- sub("^Started job (\\S+) .*", "\\1", strsplit(said, "\n")[[1]][1])
  job <- .nm_job_wait(a$store, id, timeout = 600)
  status <- .nm_agent_job_status(a, id)
  expect_equal(job$state, "done", info = status)
  expect_match(status, "Model fit (nm_modStats; 'testing' is the rows held out of training):", fixed = TRUE)
  expect_match(status, "Means by month:", fixed = TRUE)
  run <- file.path(job$folder, "run.rds")
  fig <- .nm_agent_figure(a, run, "importance")
  expect_identical(fig$png[1:4], as.raw(c(0x89, 0x50, 0x4e, 0x47)))
  expect_match(.nm_agent_figure(a, file.path(job$folder, "normalised.csv"), "normalised")$caption, "daily means")
  expect_match(.nm_agent_write_report(a, run), "^Wrote .*run_report.html")
  # The run's metadata as JSON beside it (normet_version a version, written as text).
  meta <- jsonlite::fromJSON(file.path(job$folder, "run.meta.json"))
  expect_equal(meta$normet_version, as.character(utils::packageVersion("normet")))
  expect_match(.nm_agent_list_jobs(a), id, fixed = TRUE)
})

test_that("the trend tools read a result table, with py's defaults and refusals", {
  a <- agent_in()
  df <- read.csv(test_path("nm_trend_demo.csv"))
  df$date <- as.POSIXct(df$date, tz = "UTC")
  names(df)[2] <- "observed"
  tab <- file.path(a$store$home, "tab.csv")
  dir.create(dirname(tab), recursive = TRUE, showWarnings = FALSE)
  write.csv(df, tab, row.names = FALSE)
  out <- .nm_mcp_call(a, "normet_trend", list(path = tab, n_bootstrap = 50))
  expect_match(out$text, "Trend test on observed (nm_trend):", fixed = TRUE)
  expect_match(out$text, "Mann-Kendall S", fixed = TRUE)

  # breaks: 'long-term' is the default, computed natively from the decomposition's
  # date_unix + emi_base, so the table goes to the test as it is.
  set.seed(11)
  dec <- df
  dec$date_unix <- as.numeric(dec$date)
  dec$emi_base <- rnorm(nrow(dec))
  dtab <- file.path(a$store$home, "decomp.csv")
  write.csv(dec, dtab, row.names = FALSE)
  out2 <- .nm_mcp_call(a, "normet_trend_breaks", list(path = dtab, n_bootstrap = 50))
  expect_match(out2$text, "Segmented trend test on long-term (nm_trend_breaks):", fixed = TRUE)

  # The refusals, in py's wording.
  expect_error(.nm_mcp_call(a, "normet_trend", list(path = dtab, column = "nope")),
               "has no 'nope' column")
  raw <- dec[, c("date", "observed")]
  names(raw)[2] <- "value"
  rtab <- file.path(a$store$home, "raw.csv")
  write.csv(raw, rtab, row.names = FALSE)
  expect_error(.nm_mcp_call(a, "normet_trend", list(path = rtab)),
               "no trendable column")
  expect_error(.nm_mcp_call(a, "normet_trend_breaks", list(path = rtab, column = "emission")),
               "has no 'emi_total' column")
})

test_that("the server speaks MCP over stdio", {
  home <- tempfile("normet-mcp-")
  msgs <- c(
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}',
    '{"jsonrpc":"2.0","method":"notifications/initialized"}',
    '{"jsonrpc":"2.0","id":2,"method":"tools/list"}',
    '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"normet_inspect_data","arguments":{"example":"my1","target":"NO2"}}}',
    '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"normet_inspect_data","arguments":{"example":"nope"}}}',
    '{"jsonrpc":"2.0","id":5,"method":"prompts/get","params":{"name":"deweather_workflow","arguments":{"data":"my1"}}}',
    '{"jsonrpc":"2.0","id":6,"method":"no/such"}',
    'not json'
  )
  input <- tempfile(fileext = ".jsonl")
  writeLines(msgs, input)
  out <- textConnection("said", "w", local = TRUE)
  nm_mcp_server(home = home, roots = home, input = file(input), output = out)
  close(out)
  replies <- lapply(said, jsonlite::fromJSON, simplifyVector = FALSE)
  expect_length(replies, 7)  # the notification is not answered
  expect_equal(replies[[1]]$result$protocolVersion, "2025-06-18")
  expect_equal(replies[[1]]$result$serverInfo$name, "normet")
  names <- vapply(replies[[2]]$result$tools, `[[`, "", "name")
  expect_setequal(names, c(
    "normet_list_examples", "normet_inspect_data", "normet_start_do_all", "normet_start_decompose",
    "normet_start_scm", "normet_start_cv", "normet_job_status", "normet_cancel_job", "normet_list_jobs",
    "normet_read_run", "normet_read_result", "normet_trend", "normet_trend_breaks",
    "normet_figure", "normet_write_report"
  ))
  status <- replies[[2]]$result$tools[[which(names == "normet_job_status")]]$inputSchema
  expect_equal(status$required, list("job_id"))
  expect_false(replies[[3]]$result$isError)
  expect_match(replies[[3]]$result$content[[1]]$text, "5,793 rows", fixed = TRUE)
  expect_true(replies[[4]]$result$isError)
  expect_match(replies[[5]]$result$messages[[1]]$content$text, "De-weathering my1 with normet", fixed = TRUE)
  expect_equal(replies[[6]]$error$code, -32601)
  expect_equal(replies[[7]]$error$code, -32700)
})
