# Mirrors normet-py's PR #63 additions to tests/test_pipeline_do_all_unc.py:
# do_all / do_all_unc with log_transform -- fit on log1p(value), report in
# the original units.

test_that("nm_do_all: log_transform keeps the result in the original units and trains on the log scale", {
  skip_if_not_installed("lightgbm")

  # A target with multiplicative noise spanning roughly 1 to 15: the level of
  # the noise grows with the level of the signal, the regime a log-scale fit
  # exists for.
  set.seed(7)
  n <- 720
  t <- seq_len(n) - 1
  df <- data.frame(
    date = seq(as.POSIXct("2024-01-01", tz = "UTC"), by = "hour", length.out = n),
    t2m = 10 + 8 * sin(2 * pi * t / (24 * 30)) + rnorm(n, 0, 1),
    blh = 800 + 400 * sin(2 * pi * t / 24) + rnorm(n, 0, 50)
  )
  df[["PM2.5"]] <- expm1(1.5 + 0.004 * (df$t2m - 10) + 0.0004 * (df$blh - 800) + rnorm(n, 0, 0.3)) *
    exp(rnorm(n, 0, 0.5))

  common <- list(
    target = "PM2.5", backend = "lightgbm", covariates = c("t2m", "blh"),
    split_method = "ts", train_fraction = 0.8,
    model_config = list(n_trials = 1, cv_folds = 2, nrounds = 10, early_stopping_rounds = 5),
    n_samples = 5, verbose = FALSE
  )
  lin <- do.call(nm_do_all, c(list(df = df), common))
  logr <- do.call(nm_do_all, c(list(df = df), common, list(log_transform = TRUE)))

  # The prepared frame is the frame the model trained on: log1p of the
  # linear one, same rows, same split.
  expect_equal(logr$df_prep$value, log1p(lin$df_prep$value), tolerance = 1e-12)
  expect_equal(logr$df_prep$set, lin$df_prep$set)

  # The result is in the original units: observed is exactly the input
  # target, and the back-transform keeps normalised non-negative.
  expect_equal(logr$res$observed, df[["PM2.5"]], tolerance = 1e-12)
  expect_true(all(logr$res$normalised >= 0))
})

test_that("nm_do_all: the default log_transform path is identical to the legacy call", {
  skip_if_not_installed("lightgbm")

  set.seed(7)
  n <- 720
  t <- seq_len(n) - 1
  df <- data.frame(
    date = seq(as.POSIXct("2024-01-01", tz = "UTC"), by = "hour", length.out = n),
    t2m = 10 + 8 * sin(2 * pi * t / (24 * 30)) + rnorm(n, 0, 1),
    blh = 800 + 400 * sin(2 * pi * t / 24) + rnorm(n, 0, 50)
  )
  df[["PM2.5"]] <- expm1(1.5 + 0.004 * (df$t2m - 10) + 0.0004 * (df$blh - 800) + rnorm(n, 0, 0.3)) *
    exp(rnorm(n, 0, 0.5))

  common <- list(
    target = "PM2.5", backend = "lightgbm", covariates = c("t2m", "blh"),
    split_method = "ts", train_fraction = 0.8,
    model_config = list(n_trials = 1, cv_folds = 2, nrounds = 10, early_stopping_rounds = 5),
    n_samples = 5, verbose = FALSE
  )
  default <- do.call(nm_do_all, c(list(df = df), common))
  explicit <- do.call(nm_do_all, c(list(df = df), common, list(log_transform = FALSE)))

  expect_equal(default$res, explicit$res)
  expect_equal(default$df_prep, explicit$df_prep)
})

test_that("nm_do_all: the log fit wins on logRMSE", {
  skip_if_not_installed("lightgbm")

  set.seed(7)
  n <- 720
  t <- seq_len(n) - 1
  df <- data.frame(
    date = seq(as.POSIXct("2024-01-01", tz = "UTC"), by = "hour", length.out = n),
    t2m = 10 + 8 * sin(2 * pi * t / (24 * 30)) + rnorm(n, 0, 1),
    blh = 800 + 400 * sin(2 * pi * t / 24) + rnorm(n, 0, 50)
  )
  df[["PM2.5"]] <- expm1(1.5 + 0.004 * (df$t2m - 10) + 0.0004 * (df$blh - 800) + rnorm(n, 0, 0.3)) *
    exp(rnorm(n, 0, 0.5))

  common <- list(
    target = "PM2.5", backend = "lightgbm", covariates = c("t2m", "blh"),
    split_method = "ts", train_fraction = 0.8,
    model_config = list(n_trials = 1, cv_folds = 2, nrounds = 10, early_stopping_rounds = 5),
    n_samples = 5, verbose = FALSE
  )
  lin <- do.call(nm_do_all, c(list(df = df), common))
  logr <- do.call(nm_do_all, c(list(df = df), common, list(log_transform = TRUE)))

  s_lin <- nm_Stats(lin$res, mod = "normalised", obs = "observed", statistic = "logRMSE")
  s_log <- nm_Stats(logr$res, mod = "normalised", obs = "observed", statistic = "logRMSE")
  expect_lt(s_log$logRMSE, s_lin$logRMSE)
})

test_that("nm_do_all_unc: log_transform keeps the ensemble in the original units", {
  skip_if_not_installed("lightgbm")

  set.seed(7)
  n <- 720
  t <- seq_len(n) - 1
  df <- data.frame(
    date = seq(as.POSIXct("2024-01-01", tz = "UTC"), by = "hour", length.out = n),
    t2m = 10 + 8 * sin(2 * pi * t / (24 * 30)) + rnorm(n, 0, 1),
    blh = 800 + 400 * sin(2 * pi * t / 24) + rnorm(n, 0, 50)
  )
  df[["PM2.5"]] <- expm1(1.5 + 0.004 * (df$t2m - 10) + 0.0004 * (df$blh - 800) + rnorm(n, 0, 0.3)) *
    exp(rnorm(n, 0, 0.5))

  out <- nm_do_all_unc(
    df = df, target = "PM2.5", backend = "lightgbm", covariates = c("t2m", "blh"),
    split_method = "ts", train_fraction = 0.8,
    model_config = list(n_trials = 1, cv_folds = 2, nrounds = 10, early_stopping_rounds = 5),
    n_samples = 5, n_models = 3, verbose = FALSE, log_transform = TRUE
  )

  expect_equal(out$res$observed, df[["PM2.5"]], tolerance = 1e-12)
  for (col in c("mean", "median", "lower_bound", "upper_bound", "weighted")) {
    expect_true(all(out$res[[col]] >= 0))
  }
  expect_gt(nrow(out$mod_stats), 0)
})
