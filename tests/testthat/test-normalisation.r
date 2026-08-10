test_that("nm_normalise cache key ignores resample_vars order", {
  # Regression guard, mirrors normet-py's
  # test_normalise_cache_key_ignores_resample_order. The key used to carry the
  # order of `resample_vars` in two places at once -- the argument list itself
  # and the column order handed to nm_dataframe_hash() -- so callers reaching
  # the same set by different routes (nm_decom_met's shrinking sublist of a
  # feature-importance order) recomputed every single time.
  #
  # Mocking nm_predict_lgb() below is not enough to run without the backend:
  # nm_normalise_lgb() calls nm_require("lightgbm") before it ever predicts.
  skip_if_not_installed("lightgbm")

  dates <- seq(as.POSIXct("2026-05-19 00:00:00", tz = "UTC"), by = "hour", length.out = 48)
  set.seed(1)
  df <- data.frame(
    date = dates, value = rnorm(48),
    ws = rnorm(48), temp = rnorm(48), blh = rnorm(48)
  )

  model <- list()
  attr(model, "backend") <- "lightgbm"
  attr(model, "feature_names") <- c("ws", "temp", "blh")   # nm_norm_normalise.r:527

  # Counter lives outside the model: anything stored on the model itself would
  # change nm_model_hash() between calls and defeat the cache, making the
  # assertions below pass for the wrong reason.
  calls <- new.env(parent = emptyenv())
  calls$n <- 0L
  mock_pred <- function(model, newdata, verbose = FALSE, ...) {
    calls$n <- calls$n + 1L
    rep(0, nrow(newdata))
  }
  orig_pred <- get("nm_predict_lgb", envir = asNamespace("normet"))
  assignInNamespace("nm_predict_lgb", mock_pred, ns = "normet")
  on.exit(assignInNamespace("nm_predict_lgb", orig_pred, ns = "normet"), add = TRUE)

  cache_dir <- file.path(tempdir(), paste0("nmcache_", as.integer(runif(1, 1, 1e8))))
  dir.create(cache_dir, showWarnings = FALSE, recursive = TRUE)
  on.exit(unlink(cache_dir, recursive = TRUE), add = TRUE)

  # nm_normalise_lgb() takes no `covariates` -- the R API reads the feature list
  # off the model -- so the key's variable-order sensitivity rides entirely on
  # `resample_vars` here.
  base_args <- list(
    df = df, model = model, cache_dir = cache_dir, verbose = FALSE,
    n_samples = 2, seed = 1
  )

  do.call(nm_normalise, c(base_args, list(resample_vars = c("ws", "temp", "blh"))))
  first <- calls$n
  expect_gt(first, 0)

  # Same set, different order -> must be served from cache.
  do.call(nm_normalise, c(base_args, list(resample_vars = c("blh", "ws", "temp"))))
  expect_equal(calls$n, first)

  # A genuinely different set must still miss, otherwise the assertion above
  # would also hold if the set dropped out of the key entirely.
  do.call(nm_normalise, c(base_args, list(resample_vars = c("ws", "temp"))))
  expect_gt(calls$n, first)
})


test_that("nm_normalise_auto correctly converges under mocked prediction backend", {
  # 1. Setup mock dataset
  dates <- seq(as.POSIXct("2026-05-19 00:00:00", tz = "UTC"),
    as.POSIXct("2026-05-19 23:00:00", tz = "UTC"),
    by = "hour")
  df <- data.frame(
    date = dates,
    value = seq_along(dates) * 0.5
  )

  # 2. Setup S3 mock model
  mock_model <- list()
  attr(mock_model, "backend") <- "mock_backend"

  # 3. Create mock normalise function
  mock_normalise <- function(df, model, resample_vars = NULL, resample_df = NULL,
                             n_samples = 100, aggregate = TRUE, verbose = FALSE, ...) {
    # Returns exactly observed value + a static shift, ensuring absolute stability from batch 2
    data.frame(
      date = df$date,
      observed = df$value,
      normalised = df$value + 1.23
    )
  }

  # 4. Mock the namespace binding for nm_normalise
  orig_normalise <- normet::nm_normalise
  assignInNamespace("nm_normalise", mock_normalise, ns = "normet")
  on.exit(assignInNamespace("nm_normalise", orig_normalise, ns = "normet"))

  # 5. Run auto normalisation
  res <- nm_normalise_auto(
    df = df,
    model = mock_model,
    convergence_tol = "0.5%",
    stability_streak = 3,
    batch_size = 100,
    max_samples = 1000,
    verbose = FALSE
  )

  # Check that convergence was reached
  expect_true(is.list(res))
  expect_true(all(c("best_n", "res") %in% names(res)))

  # With stability_streak = 3, it should stop at exactly 400 samples (batch 1: no check, batch 2: streak 1, batch 3: streak 2, batch 4: streak 3 -> stop)
  expect_equal(res$best_n, 400)

  # Verify correct output format and values
  expect_s3_class(res$res, "data.frame")
  expect_false(data.table::is.data.table(res$res)) # Ensure it's a standard data.frame via setDF
  expect_equal(res$res$normalised, df$value + 1.23)
})
