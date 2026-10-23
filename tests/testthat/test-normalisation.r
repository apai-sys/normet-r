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

# ---------------------------------------------------------------------------
# log_transform: df and model on the log1p scale, result back in original
# units. Mirrors normet-py's PR #63 additions to test_normalise_pools.py
# (the flaml stand-in model becomes the package's own mock-model pattern).
# ---------------------------------------------------------------------------

.log_frame <- function() {
  # (original-unit frame, its log1p-space twin): the log-space frame is what
  # nm_do_all(log_transform = TRUE) hands to nm_normalise.
  n <- 20
  df_orig <- data.frame(
    date = seq(as.POSIXct("2024-01-01", tz = "UTC"), by = "hour", length.out = n),
    value = 1.0 + (0:(n - 1)) / 10.0,  # 1.0 .. 2.9 in original units
    w = rep(c(0.0, 1.0, 2.0), length.out = n),
    stringsAsFactors = FALSE
  )
  df_log <- df_orig
  df_log$value <- log1p(df_orig$value)
  list(orig = df_orig, log = df_log)
}

.log_model <- function() {
  # Small log-scale predictions (0.5 .. 0.9), so expm1 stays in a sane range.
  model <- list()
  attr(model, "backend") <- "lightgbm"
  attr(model, "feature_names") <- "w"
  model
}

.log_predict_mock <- function() {
  mock_pred <- function(model, newdata, verbose = FALSE, ...) {
    0.5 + 0.2 * as.numeric(newdata[["w"]])
  }
  orig_pred <- get("nm_predict_lgb", envir = asNamespace("normet"))
  assignInNamespace("nm_predict_lgb", mock_pred, ns = "normet")
  function() assignInNamespace("nm_predict_lgb", orig_pred, ns = "normet")
}

test_that("nm_normalise: log_transform inverts the point estimate and the quantiles", {
  # The log path = the linear path run on the same log-space frame, with
  # every column inverted: observed, normalised and the quantiles.
  skip_if_not_installed("lightgbm")
  frames <- .log_frame()
  restore <- .log_predict_mock()
  on.exit(restore(), add = TRUE)

  common <- list(model = .log_model(), n_samples = 12, seed = 3, n_cores = 1,
    verbose = FALSE, return_quantiles = c(0.1, 0.5, 0.9)
  )
  lin <- do.call(nm_normalise, c(list(df = frames$log), common))
  logr <- do.call(nm_normalise, c(list(df = frames$log), common, list(log_transform = TRUE)))

  expect_equal(expm1(lin$normalised), logr$normalised, tolerance = 1e-12)
  for (q in c("q100", "q500", "q900")) {
    expect_equal(expm1(lin[[q]]), logr[[q]], tolerance = 1e-12)
  }
  # observed comes back in the original units the user gave
  expect_equal(logr$observed, frames$orig$value, tolerance = 1e-12)
  expect_true(all(logr$normalised >= 0))
})

test_that("nm_normalise: the default log_transform is bit identical to the legacy call", {
  skip_if_not_installed("lightgbm")
  frames <- .log_frame()
  restore <- .log_predict_mock()
  on.exit(restore(), add = TRUE)

  plain <- nm_normalise(
    df = frames$log, model = .log_model(),
    n_samples = 12, seed = 3, n_cores = 1, verbose = FALSE
  )
  explicit <- nm_normalise(
    df = frames$log, model = .log_model(),
    n_samples = 12, seed = 3, n_cores = 1, verbose = FALSE, log_transform = FALSE
  )
  expect_identical(plain, explicit)
})

test_that("nm_normalise: log_transform inverts the aggregate=FALSE wide table", {
  skip_if_not_installed("lightgbm")
  frames <- .log_frame()
  restore <- .log_predict_mock()
  on.exit(restore(), add = TRUE)

  common <- list(model = .log_model(), n_samples = 12, seed = 3, n_cores = 1,
    verbose = FALSE, aggregate = FALSE
  )
  lin <- do.call(nm_normalise, c(list(df = frames$log), common))
  logr <- do.call(nm_normalise, c(list(df = frames$log), common, list(log_transform = TRUE)))

  seed_cols <- setdiff(colnames(lin), c("date", "observed"))
  expect_setequal(seed_cols, setdiff(colnames(logr), c("date", "observed")))
  for (c in seed_cols) {
    expect_equal(expm1(lin[[c]]), logr[[c]], tolerance = 1e-12)
  }
})
