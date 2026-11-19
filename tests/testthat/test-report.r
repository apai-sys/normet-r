# Mirrors normet-py's PR #63 addition to tests/test_report.py: the
# log-scale note in the HTML report.

test_that("nm_generate_html: the log-scale note appears only when the flag is on", {
  # A run whose config carries log_transform = TRUE gets a scale note with
  # the low-value share; a linear run's report is exactly what it was before.
  dates <- seq(as.Date("2024-01-01"), by = "day", length.out = 20)
  observed <- c(seq(0.1, 0.9, length.out = 10), seq(2.0, 80.0, length.out = 10))
  result <- data.frame(date = dates, observed = observed, normalised = observed * 1.1)

  log_run <- nm_make_run(result = result, kind = "normalise", seed = 7,
    config = list(log_transform = TRUE)
  )
  f_log <- file.path(tempdir(), "nm_log_report.html")
  nm_generate_html(log_run, f_log)
  content <- paste(readLines(f_log, warn = FALSE), collapse = "")
  expect_true(grepl("Log-scale fit", content, fixed = TRUE))
  expect_true(grepl("log1p(value)", content, fixed = TRUE))
  expect_true(grepl("50%", content, fixed = TRUE))  # 10 of 20 observations sit below 1

  lin_run <- nm_make_run(result = result, kind = "normalise", seed = 7,
    config = list(backend = "lightgbm")
  )
  f_lin <- file.path(tempdir(), "nm_lin_report.html")
  nm_generate_html(lin_run, f_lin)
  lin <- paste(readLines(f_lin, warn = FALSE), collapse = "")
  expect_false(grepl("Log-scale fit", lin, fixed = TRUE))
  expect_false(grepl("nm-note", lin, fixed = TRUE))

  f_zh <- file.path(tempdir(), "nm_log_zh_report.html")
  nm_generate_html(log_run, f_zh, lang = "zh")
  zh <- paste(readLines(f_zh, warn = FALSE), collapse = "")
  expect_true(grepl("对数尺度拟合", zh, fixed = TRUE))
  unlink(c(f_log, f_lin, f_zh))
})
