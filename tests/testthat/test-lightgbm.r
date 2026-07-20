test_that("nm_train_lgb trains a model and predictions work", {
  skip_if_not_installed("lightgbm")

  set.seed(42)
  n <- 100
  df <- data.frame(
    date = seq(as.POSIXct("2020-01-01", tz = "UTC"), by = "day", length.out = n),
    value = 10 + 2 * sin(2 * pi * 1:n / 30) + rnorm(n, 0, 0.5),
    x1 = rnorm(n, 5, 1),
    x2 = rnorm(n, 20, 3)
  )
  df <- nm_process_date(df, verbose = FALSE)
  df <- normet:::nm_add_date_variables(data.table::as.data.table(df))
  data.table::setDF(df)

  model <- nm_train_lgb(
    df = df,
    target = "value",
    covariates = c("x1", "x2"),
    model_config = list(n_trials = 5, cv_folds = 2),
    seed = 42,
    verbose = FALSE
  )

  expect_true(inherits(model, "lgb.Booster"))
  expect_equal(attr(model, "backend"), "lightgbm")

  feat <- nm_extract_features(model)
  expect_equal(feat, c("x1", "x2"))

  preds <- nm_predict(model, df, verbose = FALSE)
  expect_length(preds, n)
  expect_true(is.numeric(preds))
})

test_that("nm_train_lgb handles factor predictors (weekday) without degenerating", {
  skip_if_not_installed("lightgbm")

  set.seed(42)
  n <- 200
  df <- data.frame(
    date = seq(as.POSIXct("2020-01-01", tz = "UTC"), by = "day", length.out = n),
    value = 10 + 2 * sin(2 * pi * 1:n / 30) + rnorm(n, 0, 0.5),
    x1 = rnorm(n, 5, 1),
    x2 = rnorm(n, 20, 3)
  )
  df <- nm_process_date(df, verbose = FALSE)
  df <- normet:::nm_add_date_variables(data.table::as.data.table(df))
  data.table::setDF(df)

  predictors <- c("x1", "x2", "weekday")

  model <- nm_train_lgb(
    df = df,
    target = "value",
    covariates = predictors,
    model_config = list(n_trials = 2, cv_folds = 2, num_leaves_min = 5, num_leaves_max = 15),
    seed = 42,
    verbose = FALSE
  )

  expect_equal(attr(model, "factor_levels")$weekday, levels(df$weekday))

  preds <- nm_predict(model, df, verbose = FALSE)
  expect_length(preds, n)
  expect_true(is.numeric(preds))
  expect_true(length(unique(preds)) > 1)
})

test_that("nm_normalise works with lightgbm model", {
  skip_if_not_installed("lightgbm")

  set.seed(42)
  n <- 50
  df <- data.frame(
    date = seq(as.POSIXct("2020-01-01", tz = "UTC"), by = "day", length.out = n),
    value = 10 + 2 * sin(2 * pi * 1:n / 30) + rnorm(n, 0, 0.5),
    temp = 15 + 5 * sin(2 * pi * 1:n / 30) + rnorm(n, 0, 1),
    ws = 3 + 2 * sin(2 * pi * 1:n / 30) + rnorm(n, 0, 0.5)
  )

  result <- nm_build_model(
    df, target = "value",
    covariates = c("temp", "ws"),
    model_config = list(n_trials = 5, cv_folds = 2),
    seed = 42, verbose = FALSE
  )

  class_before <- class(result$df_prep)

  norm <- nm_normalise(
    df = result$df_prep,
    model = result$model,
    resample_vars = c("temp", "ws"),
    n_samples = 20, aggregate = TRUE,
    verbose = FALSE
  )

  expect_s3_class(norm, "data.frame")
  expect_true(all(c("date", "observed", "normalised") %in% names(norm)))
  expect_true(all(is.finite(norm$normalised)))

  # nm_normalise must not mutate the caller's df_prep in place (e.g. via
  # data.table::setDT(), which would silently turn it into a data.table).
  expect_equal(class(result$df_prep), class_before)

  # And df_prep must remain usable by other functions afterwards.
  pdp <- nm_pdp(result$df_prep, result$model, var_list = c("temp"), verbose = FALSE)
  expect_s3_class(pdp, "data.frame")
})

test_that("nm_pdp works with lightgbm model", {
  skip_if_not_installed("lightgbm")

  set.seed(42)
  n <- 100
  df <- data.frame(
    date = seq(as.POSIXct("2020-01-01", tz = "UTC"), by = "day", length.out = n),
    value = 10 + 2 * sin(2 * pi * 1:n / 30) + rnorm(n, 0, 0.5),
    temp = 15 + 5 * sin(2 * pi * 1:n / 30) + rnorm(n, 0, 1),
    ws = 3 + 2 * sin(2 * pi * 1:n / 30) + rnorm(n, 0, 0.5)
  )

  result <- nm_build_model(
    df, target = "value",
    covariates = c("temp", "ws"),
    model_config = list(n_trials = 5, cv_folds = 2),
    seed = 42, verbose = FALSE
  )

  pdp <- nm_pdp(
    df, result$model, var_list = c("temp"),
    training_only = FALSE, verbose = FALSE
  )

  expect_s3_class(pdp, "data.frame")
  expect_true(all(c("variable", "value", "pdp_mean") %in% names(pdp)))
  expect_true("temp" %in% pdp$variable)
})

test_that("nm_run_scm works with mlscm backend using lightgbm", {
  skip_if_not_installed("lightgbm")

  set.seed(42)
  dates <- seq(as.Date("2020-01-01"), as.Date("2020-01-30"), by = "day")
  units <- c("Treated", "C1", "C2", "C3")
  grid <- expand.grid(date = dates, code = units, stringsAsFactors = FALSE)

  grid$outcome <- 0
  grid$outcome[grid$code == "C1"] <- 10 + sin(1:30)
  grid$outcome[grid$code == "C2"] <- 8 + cos(1:30)
  grid$outcome[grid$code == "C3"] <- 12 + stats::rnorm(30, 0, 0.5)
  grid$outcome[grid$code == "Treated"] <-
    0.6 * grid$outcome[grid$code == "C1"] +
    0.4 * grid$outcome[grid$code == "C2"] +
    stats::rnorm(30, sd = 0.1)

  res <- nm_run_scm(
    df = grid,
    date_col = "date",
    outcome_col = "outcome",
    unit_col = "code",
    treated_unit = "Treated",
    donors = c("C1", "C2", "C3"),
    cutoff_date = "2020-01-20",
    scm_backend = "mlscm",
    model_config = list(n_trials = 3, cv_folds = 2),
    verbose = FALSE
  )

  expect_true(is.data.frame(res))
  expect_true(all(c("date", "observed", "synthetic", "effect") %in% names(res)))
  expect_true(all(is.finite(res$synthetic)))
})

test_that("nm_extract_features detects lightgbm model", {
  skip_if_not_installed("lightgbm")

  set.seed(42)
  n <- 50
  df <- data.frame(
    date = seq(as.POSIXct("2020-01-01", tz = "UTC"), by = "day", length.out = n),
    value = rnorm(n, 10, 1),
    a = rnorm(n), b = rnorm(n), c = rnorm(n)
  )

  result <- nm_build_model(
    df, target = "value",
    covariates = c("a", "b", "c"),
    model_config = list(n_trials = 3, cv_folds = 2),
    seed = 42, verbose = FALSE
  )

  feat <- nm_extract_features(result$model)
  expect_equal(sort(feat), sort(c("a", "b", "c")))
})
