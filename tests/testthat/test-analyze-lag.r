# Tests for nm_analyze_lag (ACF / PACF + pre-whitened CCF).

make_driver_response <- function(n = 2000, true_lag = 6, seed = 0) {
  set.seed(seed)
  t <- seq_len(n)
  season <- sin(2 * pi * t / 24)

  driver <- numeric(n)
  for (i in 2:n) driver[i] <- 0.6 * driver[i - 1] + rnorm(1)
  driver <- driver + 2 * season

  resp <- rep(NA_real_, n)
  resp[(true_lag + 1):n] <- 0.8 * driver[seq_len(n - true_lag)] +
    1.5 * season[(true_lag + 1):n]
  resp <- resp + rnorm(n, 0, 0.3)

  data.frame(
    date = seq(as.POSIXct("2020-01-01", tz = "UTC"), by = "hour", length.out = n),
    ws = driver,
    pm25 = resp
  )
}

test_that("ACF/PACF only when no driver", {
  df <- make_driver_response()
  res <- nm_analyze_lag(df, target = "pm25", max_lag = 24)

  expect_s3_class(res, "nm_lag_diagnostics")
  expect_null(res$driver)
  expect_null(res$ccf)
  # ACF at lag 0 is exactly 1.
  expect_equal(res$acf$value[res$acf$lag == 0], 1)
  # A strongly autocorrelated series flags at least one AR lag.
  expect_true(length(res$target_ar_lags) > 0)
})

test_that("pre-whitened CCF recovers the injected lag", {
  true_lag <- 6
  df <- make_driver_response(true_lag = true_lag)
  res <- nm_analyze_lag(df, target = "pm25", driver = "ws", max_lag = 24, prewhiten = TRUE)

  expect_true(res$prewhitened)
  expect_false(is.null(res$ccf))
  expect_equal(res$peak_lag, true_lag)
  expect_true(true_lag %in% res$driver_lags)
})

test_that("CCF peak is on the positive (driver-leads) side", {
  df <- make_driver_response(true_lag = 4)
  res <- nm_analyze_lag(df, target = "pm25", driver = "ws", max_lag = 24, prewhiten = TRUE)
  expect_true(!is.na(res$peak_lag) && res$peak_lag > 0)
})

test_that("significance band shrinks with n", {
  small <- nm_analyze_lag(make_driver_response(n = 300), "pm25", "ws", max_lag = 12)
  large <- nm_analyze_lag(make_driver_response(n = 3000), "pm25", "ws", max_lag = 12)
  expect_lt(large$band, small$band)
})

test_that("print reports target and driver", {
  df <- make_driver_response()
  res <- nm_analyze_lag(df, target = "pm25", driver = "ws", max_lag = 12)
  out <- paste(utils::capture.output(print(res)), collapse = " ")
  expect_match(out, "pm25")
  expect_match(out, "ws")
})

test_that("bad max_lag raises", {
  df <- make_driver_response(n = 100)
  expect_error(nm_analyze_lag(df, target = "pm25", max_lag = 0))
})
