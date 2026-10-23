# Mirrors normet-py's tests/test_prediagnostics.py (PR #61).
#
# The panel fixture is the clean case: the treated unit equals 0.5*D1 + 0.5*D2
# plus tiny noise before the cutoff, so the pre-period is parallel and the
# test must stay quiet. Drift is then injected into the treated unit's
# pre-period and the test must catch it.

CUTOFF <- "2023-05-01"
DONORS <- paste0("D", 1:6)

# Toy panel: one treated unit + 6 donors, 200 days from 2023-01-01. Treated
# equals 0.5*D1 + 0.5*D2 in the pre-period (plus tiny noise), then gets a
# shock of +10 after the cutoff. Each donor carries a distinct sinusoid, so
# the 0.5/0.5 weight identity is recoverable. normet-py's scm_panel fixture.
.pt_panel <- function(seed = 1L, ramp = 0, late_noise = 0) {
  set.seed(seed)
  n <- 200L
  dates <- seq(as.Date("2023-01-01"), by = "day", length.out = n)
  t <- seq_len(n) - 1
  periods <- c(30, 17, 45, 11, 60, 23)
  donors <- lapply(1:6, function(j) 5 + (j - 1) + 3 * sin(2 * pi * t / periods[j] + (j - 1)))
  treated <- 0.5 * donors[[1]] + 0.5 * donors[[2]] + stats::rnorm(n, sd = 0.05)
  treated <- treated + ifelse(dates >= as.Date(CUTOFF), 10, 0)
  if (ramp > 0) {
    # A linear pre-period ramp on the treated unit: zero at the first day,
    # `ramp` the day before the cutoff; the donors carry no trend, so the
    # synthetic control cannot reproduce it.
    n_pre <- sum(dates < as.Date(CUTOFF))
    treated <- treated + ifelse(dates < as.Date(CUTOFF), ramp * t / max(n_pre - 1, 1), 0)
  }
  if (late_noise > 0) {
    # Noise that doubles in the final third of the pre-period: no trend, but
    # the fit stops tracking near the cutoff.
    pre_max <- max(dates[dates < as.Date(CUTOFF)])
    late <- dates > (pre_max - 40) & dates < as.Date(CUTOFF)
    treated <- treated + ifelse(late, stats::rnorm(n, sd = late_noise), 0)
  }
  values <- c(list(treated), donors)
  codes <- c("T", DONORS)
  do.call(rbind, lapply(seq_along(codes), function(i) data.frame(
    date = dates, code = codes[i], value = values[[i]], stringsAsFactors = FALSE
  )))
}

.pt_fit <- function(panel) {
  nm_scm(
    df = panel, date_col = "date", unit_col = "code", outcome_col = "value",
    treated_unit = "T", cutoff_date = CUTOFF, donors = DONORS,
    allow_negative_weights = FALSE, verbose = FALSE
  )
}

test_that("nm_pre_trend_test is quiet on a parallel pre-period", {
  out <- .pt_fit(.pt_panel())
  pt <- nm_pre_trend_test(out, CUTOFF)

  expect_s3_class(pt, "nm_pre_trend")
  expect_equal(pt$n_periods, 120L)
  expect_true(startsWith(pt$verdict, "ok"))
  expect_gte(pt$p_slope, 0.05)
  expect_gte(pt$rmpe_drift, 0.7)
  expect_lte(pt$rmpe_drift, 1.3)
  expect_match(capture.output(print(pt)), "pre-trend on 120 pre-period points")
})

test_that("nm_pre_trend_test catches an injected drift", {
  # A slow linear ramp: the slope is decisive even though the drift ratio
  # stays mild (the fit absorbs much of a monotone ramp's level).
  out <- .pt_fit(.pt_panel(ramp = 2))
  pt <- nm_pre_trend_test(out, CUTOFF)

  expect_true(startsWith(pt$verdict, "fail"))
  expect_lt(pt$p_slope, 0.01)
  expect_gt(pt$rmpe_drift, 1)
  expect_gt(pt$slope, 0)
})

test_that("nm_pre_trend_test flags a late fit breakdown without a trend", {
  out <- .pt_fit(.pt_panel(seed = 7L, late_noise = 1.25))
  pt <- nm_pre_trend_test(out, CUTOFF)

  expect_true(startsWith(pt$verdict, "caution"))
  expect_match(pt$verdict, "deteriorates")
  expect_gte(pt$p_slope, 0.01)
  expect_gt(pt$rmpe_drift, 1.25)
})

test_that("nm_pre_trend_test reads a bare data.frame and a list the same", {
  out <- .pt_fit(.pt_panel())
  pt_df <- nm_pre_trend_test(out$synthetic, CUTOFF)
  pt_list <- nm_pre_trend_test(out, CUTOFF)

  expect_equal(pt_df$p_slope, pt_list$p_slope)
  expect_equal(pt_df$verdict, pt_list$verdict)
})

test_that("nm_pre_trend_test is insufficient on a short pre-period", {
  # Four pre-period points: the counterfactual machinery still runs, but the
  # trend test refuses a p-value from two degrees of freedom.
  out <- .pt_fit(.pt_panel())
  syn <- out$synthetic
  pre <- syn[syn$date < as.Date(CUTOFF), , drop = FALSE]
  pt <- nm_pre_trend_test(pre[(nrow(pre) - 3):nrow(pre), , drop = FALSE], CUTOFF)

  expect_equal(pt$n_periods, 4L)
  expect_true(startsWith(pt$verdict, "insufficient"))
  expect_true(is.na(pt$slope))
  expect_true(is.na(pt$p_slope))
  expect_true(is.na(pt$rmpe_drift))
})

test_that("nm_pre_trend_test rejects a frame without the columns", {
  expect_error(nm_pre_trend_test(data.frame(a = c(1, 2)), CUTOFF), "observed")
  expect_error(nm_pre_trend_test(list(effect = c(1)), CUTOFF), "'synthetic' key")
})

test_that("nm_scm_diagnostics carries the pre-trend", {
  out <- .pt_fit(.pt_panel())
  diag <- nm_scm_diagnostics(out, CUTOFF)
  pt <- nm_pre_trend_test(out, CUTOFF)

  expected_old <- c("pre_n", "pre_rmse", "pre_mae", "pre_mape", "pre_r2",
                    "post_n", "att", "att_cum", "post_rmse", "hhi",
                    "effective_n_donors", "top_donors", "top_donor_share", "n_donors")
  expect_true(all(expected_old %in% names(diag)))
  expect_setequal(names(diag$pre_trend), c("slope", "p_slope", "rmpe_drift", "n_periods", "verdict"))
  expect_equal(diag$pre_trend$p_slope, pt$p_slope)
  expect_equal(diag$pre_trend$slope, pt$slope)
  expect_equal(diag$pre_trend$verdict, pt$verdict)
})

test_that("nm_run_scm result feeds the test", {
  res <- nm_run_scm(
    df = .pt_panel(), date_col = "date", unit_col = "code", outcome_col = "value",
    treated_unit = "T", cutoff_date = CUTOFF, donors = DONORS, verbose = FALSE
  )
  pt <- nm_pre_trend_test(res, CUTOFF)

  expect_equal(pt$n_periods, 120L)
  expect_true(startsWith(pt$verdict, "ok"))
})
