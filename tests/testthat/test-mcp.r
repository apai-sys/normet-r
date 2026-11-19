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

test_that("the SCM diagnostics tools read a result table, and refuse without a cutoff", {
  a <- agent_in()
  # A small synthetic-control result table: date, observed, synthetic, effect.
  dates <- seq(as.Date("2023-01-01"), by = "day", length.out = 60)
  set.seed(3)
  syn <- data.frame(
    date = dates,
    observed = sin(seq_len(60) / 7) + rnorm(60, sd = 0.05),
    synthetic = sin(seq_len(60) / 7),
    stringsAsFactors = FALSE
  )
  syn$effect <- syn$observed - syn$synthetic
  tab <- file.path(a$store$home, "scm.csv")
  dir.create(dirname(tab), recursive = TRUE, showWarnings = FALSE)
  write.csv(syn, tab, row.names = FALSE)

  out <- .nm_mcp_call(a, "normet_scm_diagnostics", list(path = tab, cutoff = "2023-03-01"))
  expect_match(out$text, "Synthetic control, cutoff 2023-03-01 (nm_scm_diagnostics):", fixed = TRUE)
  expect_match(out$text, "ATT (mean effect after the cutoff)", fixed = TRUE)

  out2 <- .nm_mcp_call(a, "normet_pre_trend_test", list(path = tab, cutoff = "2023-03-01"))
  expect_match(out2$text, "Pre-trend test, cutoff 2023-03-01 (nm_pre_trend_test):", fixed = TRUE)
  expect_match(out2$text, "RMSPE drift", fixed = TRUE)

  out3 <- .nm_mcp_call(a, "normet_conformal_interval",
                       list(path = tab, cutoff = "2023-03-01", n_perm = 100))
  expect_match(out3$text, "Conformal effect interval, cutoff 2023-03-01", fixed = TRUE)
  expect_match(out3$text, "p-value (two-sided)", fixed = TRUE)

  # The refusals: the readings are against the cutoff the SCM was run with.
  expect_error(.nm_mcp_call(a, "normet_scm_diagnostics", list(path = tab)), "give cutoff=")
  expect_error(.nm_mcp_call(a, "normet_pre_trend_test", list(path = tab)), "give cutoff=")
  expect_error(.nm_mcp_call(a, "normet_conformal_interval", list(path = tab)), "give cutoff=")
})

test_that("the effect-bands tools read a placebo result", {
  a <- agent_in()
  dates <- seq(as.Date("2023-01-01"), by = "day", length.out = 60)
  set.seed(5)
  eff <- sin(seq_len(60) / 7) + rnorm(60, sd = 0.05)
  treated <- data.frame(date = dates, effect = eff, stringsAsFactors = FALSE)
  placebos <- lapply(1:5, function(i) {
    data.frame(date = dates, effect = eff + rnorm(60, sd = 0.1), unit = paste0("D", i),
               stringsAsFactors = FALSE)
  })
  rds <- file.path(a$store$home, "placebo_space.rds")
  dir.create(dirname(rds), recursive = TRUE, showWarnings = FALSE)
  saveRDS(list(treated = treated, placebos = placebos, p_value = 0.2, ref_band = NULL), rds)

  out <- .nm_mcp_call(a, "normet_effect_bands_space", list(path = rds))
  expect_match(out$text, "Effect bands from the donor placebos (nm_effect_bands_space, quantile, level 0.95):", fixed = TRUE)
  expect_match(out$text, "points outside the band", fixed = TRUE)

  # The time variant aligns to event time: its placebos are named by the fake cutoff.
  plc_time <- lapply(1:5, function(i) {
    data.frame(date = dates[1:20], effect = eff[1:20] + rnorm(20, sd = 0.1),
               stringsAsFactors = FALSE)
  })
  names(plc_time) <- paste0("2023-0", 1:5, "-15")
  saveRDS(list(treated = treated, placebos = plc_time, p_value = 0.2,
               ref_band_event_time = NULL, placebo_stats = numeric()),
          file.path(a$store$home, "placebo_time.rds"))
  out2 <- .nm_mcp_call(a, "normet_effect_bands_time", list(path = file.path(a$store$home, "placebo_time.rds")))
  expect_match(out2$text, "by event time (nm_effect_bands_time, quantile, level 0.95):", fixed = TRUE)
})

test_that("the new SCM and multisite tools write the R their jobs run", {
  a <- agent_in()
  # Queued behind one that is running, so none of these starts.
  blocker <- .nm_job_submit(a$store, "cv", "Sys.sleep(60)")
  on.exit(.nm_job_cancel(a$store, blocker$id), add = TRUE)

  start_and_check <- function(name, args, marker) {
    said <- .nm_mcp_call(a, name, args)
    id <- sub("^Started job (\\S+) .*", "\\1", strsplit(said$text, "\n")[[1]][1])
    script <- readLines(file.path(a$store$root, id, "job.R"))
    expect_true(any(grepl(marker, script, fixed = TRUE)))
    expect_silent(parse(text = script))
    expect_match(.nm_agent_cancel_job(a, id), ": cancelled.", fixed = TRUE)
    invisible(NULL)
  }

  start_and_check("normet_start_scm_all", list(
    cutoff = "2019-04-01", example = "scm", unit_col = "code", outcome_col = "NO2_dw"
  ), "nm_scm_all(df")

  start_and_check("normet_start_scm_staggered", list(
    treated_units = c("MY1", "ABD"), cutoff_dates = c("2019-04-01", "2020-04-01"),
    example = "scm", unit_col = "code", outcome_col = "NO2_dw"
  ), "nm_run_scm_staggered(df")

  start_and_check("normet_start_placebo_space", list(
    treated = "MY1", cutoff = "2019-04-01", example = "scm", unit_col = "code", outcome_col = "NO2_dw"
  ), "nm_placebo_in_space(df")

  start_and_check("normet_start_placebo_time", list(
    treated = "MY1", cutoff = "2019-04-01", example = "scm", unit_col = "code", outcome_col = "NO2_dw"
  ), "nm_placebo_in_time(df")

  start_and_check("normet_start_uncertainty_bands", list(
    treated = "MY1", cutoff = "2019-04-01", example = "scm", unit_col = "code", outcome_col = "NO2_dw",
    method = "bootstrap", b = 50
  ), "nm_uncertainty_bands(df")

  start_and_check("normet_start_loo_stability", list(
    treated = "MY1", cutoff = "2019-04-01", example = "scm", unit_col = "code", outcome_col = "NO2_dw"
  ), "nm_loo_weight_stability(df")

  start_and_check("normet_start_do_all_multisite", list(
    site_col = "site", target = "NO2", covariates = c("ws", "wd"), example = "my1"
  ), "nm_do_all_multisite(df")

  start_and_check("normet_start_decompose_multisite", list(
    site_col = "site", target = "NO2", covariates = c("ws", "wd"), example = "my1"
  ), "nm_decompose_multisite(df")

  start_and_check("normet_start_decompose_uncertainty", list(
    target = "NO2", covariates = c("ws", "wd"), example = "my1", n_models = 2, n_samples = 3
  ), "nm_decompose_uncertainty(df")
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
    "normet_start_scm", "normet_start_scm_all", "normet_start_scm_staggered",
    "normet_start_placebo_space", "normet_start_placebo_time", "normet_start_uncertainty_bands",
    "normet_start_loo_stability", "normet_start_do_all_multisite", "normet_start_decompose_multisite",
    "normet_start_decompose_uncertainty", "normet_scm_diagnostics", "normet_conformal_interval",
    "normet_pre_trend_test", "normet_effect_bands_space", "normet_effect_bands_time",
    "normet_start_cv", "normet_job_status", "normet_cancel_job",
    "normet_list_jobs", "normet_read_run", "normet_read_result", "normet_trend",
    "normet_trend_breaks", "normet_figure", "normet_write_report"
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
