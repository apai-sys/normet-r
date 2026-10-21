# How far a long call has come (nm_utils_progress.r): what the GUI's task clock hears.

test_that("nothing is heard without a listener", {
  expect_silent(normet:::.nm_progress_report(1, 2))
})

test_that("a part reports within its share of the whole", {
  heard <- numeric(0)
  listen <- function(share) heard <<- c(heard, share)
  normet:::.nm_progress_listening(listen, {
    normet:::.nm_progress_report(1, 4)
    normet:::.nm_progress_part(2, 4, {          # the third quarter
      normet:::.nm_progress_report(0, 2)
      normet:::.nm_progress_report(1, 2)
      normet:::.nm_progress_part(1, 2,          # its second half
        normet:::.nm_progress_report(1, 1))
    })
    normet:::.nm_progress_report(5, 4)          # past the end: the whole, no more
  })
  expect_equal(heard, c(0.25, 0.5, 0.625, 0.75, 1.0))
  normet:::.nm_progress_report(1, 2)            # the listener is gone with its block
  expect_length(heard, 5)
})

test_that("a part's span is put back when its call fails", {
  heard <- numeric(0)
  normet:::.nm_progress_listening(function(share) heard <<- c(heard, share), {
    try(normet:::.nm_progress_part(1, 2, stop("no")), silent = TRUE)
    normet:::.nm_progress_report(1, 4)
  })
  expect_equal(heard, 0.25)
})

test_that("nm_rolling reports its windows, each window's batches inside its share", {
  skip_if_not_installed("lightgbm")

  set.seed(42)
  n <- 60
  df <- data.frame(
    date = seq(as.POSIXct("2020-01-01", tz = "UTC"), by = "day", length.out = n),
    value = 10 + 2 * sin(2 * pi * 1:n / 30) + rnorm(n, 0, 0.5),
    temp = 15 + 5 * sin(2 * pi * 1:n / 30) + rnorm(n, 0, 1),
    ws = 3 + 2 * sin(2 * pi * 1:n / 30) + rnorm(n, 0, 0.5)
  )
  res <- nm_build_model(df, target = "value", covariates = c("temp", "ws"),
                        model_config = list(n_trials = 2, cv_folds = 2),
                        seed = 42, verbose = FALSE)
  heard <- numeric(0)
  rolled <- normet:::.nm_progress_listening(function(share) heard <<- c(heard, share),
    nm_rolling(res$df_prep, model = res$model, covariates = c("temp", "ws"),
               resample_vars = c("temp", "ws"), window_days = 30, rolling_every = 15,
               n_samples = 10, verbose = FALSE))
  # Each window heard as it starts; what its normalisation reports stays inside the
  # window's share, and the share never goes back.
  n_windows <- length(grep("^window_", names(rolled)))
  expect_gte(n_windows, 2)
  expect_true(all(round((seq_len(n_windows) - 1) / n_windows, 10) %in% round(heard, 10)))
  expect_false(is.unsorted(heard))
  expect_true(all(heard >= 0 & heard < 1))
})
