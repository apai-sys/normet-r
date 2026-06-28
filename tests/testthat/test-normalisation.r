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
