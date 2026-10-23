# Mirrors normet-py's PR #63 additions to tests/test_metrics.py:
# logMAE / logRMSE, accuracy in log1p space -- the space a log-transformed
# fit optimises.

test_that("log metrics: a perfect fit is exactly zero", {
  y <- c(0.5, 2.0, 10.0, 100.0)
  out <- normet:::.stats_from_arrays(y, y, c("logMAE", "logRMSE"))
  expect_equal(out$logMAE, 0.0)
  expect_equal(out$logRMSE, 0.0)
})

test_that("log metrics: known values", {
  y_true <- c(1.0, 10.0, 100.0)
  y_pred <- c(1.5, 12.0, 90.0)
  ldiff <- log1p(y_pred) - log1p(y_true)
  out <- normet:::.stats_from_arrays(y_pred, y_true, c("logMAE", "logRMSE"))
  expect_equal(out$logMAE, mean(abs(ldiff)), tolerance = 1e-12)
  expect_equal(out$logRMSE, sqrt(mean(ldiff^2)), tolerance = 1e-12)
})

test_that("log metrics: bound proportional errors that MGE does not", {
  # A constant 10% overprediction: MGE grows with the level (1 -> 100), the
  # log1p error stays bounded near a tenth of a log unit -- why a log fit is
  # judged in log space. (log1p, not log: the weight of a relative miss
  # grows from ~half a relative unit at low levels toward the full unit.)
  y <- c(10.0, 100.0, 1000.0)
  yhat <- 1.1 * y
  mge <- abs(yhat - y)
  log_err <- abs(log1p(yhat) - log1p(y))
  expect_equal(mge[3] / mge[1], 100.0)
  expect_lt(max(log_err), 0.1)
  out <- normet:::.stats_from_arrays(yhat, y, c("MGE", "logMAE"))
  expect_equal(out$logMAE, mean(log_err), tolerance = 1e-12)
})

test_that("log metrics: out-of-domain pairs are dropped from the log metrics only", {
  # One pair below -1 (outside log1p's domain) is dropped from the log
  # metrics only; the linear statistics keep it.
  y_true <- c(1.0, -2.0)
  y_pred <- c(1.5, -1.5)
  out <- normet:::.stats_from_arrays(y_pred, y_true, c("logMAE", "logRMSE", "MGE", "n"))
  expect_equal(as.integer(out$n), 2L)
  expect_true(is.finite(out$MGE))
  expect_equal(out$logMAE, abs(log1p(1.5) - log1p(1.0)), tolerance = 1e-12)
  expect_equal(out$logRMSE, abs(log1p(1.5) - log1p(1.0)), tolerance = 1e-12)
})

test_that("log metrics: all out of domain are NA", {
  out <- normet:::.stats_from_arrays(c(-2.5, -3.5), c(-2.0, -3.0), c("logMAE", "logRMSE"))
  expect_true(is.na(out$logMAE))
  expect_true(is.na(out$logRMSE))
})

test_that("default stats do not include the log metrics", {
  y <- c(1.0, 2.0, 3.0)
  out <- nm_Stats(data.frame(value_predict = y, value = y),
    mod = "value_predict", obs = "value"
  )
  expect_false("logMAE" %in% colnames(out))
  expect_false("logRMSE" %in% colnames(out))
})
