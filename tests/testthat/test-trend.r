# Trend and segmented trend (nm_trend, nm_trend_breaks, nm_mann_kendall,
# nm_theil_sen). The deterministic statistics are pinned to the reference values
# computed by normet-py on the same fixture files (R and py agree to the last
# digit there); the block-bootstrap figures are checked by their properties,
# because R's global stream draws different replicates than numpy's (same math,
# different draws).

.nm_trend_df <- function(file) {
  df <- read.csv(test_path(file))
  df$date <- as.POSIXct(df$date, tz = "UTC")
  df
}

test_that("the mann-kendall test matches the reference (classical and seasonal)", {
  df <- .nm_trend_df("nm_trend_demo.csv")
  t <- nm_mann_kendall(df, value_col = "demo")
  expect_equal(t$S, 43054)
  expect_equal(t$var_S, 1.393041666666667e+07, tolerance = 1e-12)
  expect_equal(t$z, 1.153510005303948e+01, tolerance = 1e-12)
  expect_equal(t$p, 0)
  expect_equal(t$n, 500)
  expect_false(t$seasonal)

  # The seasonal (Sen 1968) variant on 480 hourly rows, period 24: the S is the
  # sum of the within-slot S, the variance the sum of the 24 slots' variances.
  df2 <- .nm_trend_df("nm_trend_demo2.csv")
  t2 <- nm_mann_kendall(df2, value_col = "d2", seasonal_period = 24)
  expect_equal(t2$S, -256)
  expect_equal(t2$var_S, 22800, tolerance = 1e-12)
  expect_equal(t2$z, -1.688778755257931, tolerance = 1e-12)
  expect_equal(t2$p, 9.126183657556930e-02, tolerance = 1e-12)
  expect_true(t2$seasonal)
  expect_equal(t2$n_periods, 24L)

  # A partial period is refused rather than tested on uneven groups.
  expect_error(nm_mann_kendall(rbind(df2, df2[1, ]), value_col = "d2", seasonal_period = 24),
               "whole number of periods")
})

test_that("nm_trend matches the reference on a clean hourly record", {
  res <- nm_trend(.nm_trend_df("nm_trend_demo.csv"), value_col = "demo", name = "demo")
  expect_equal(res$test$S, 43054)
  expect_equal(res$test$p, 0)
  # Theil-Sen slope with the Sen (1968) interval: order statistics of the sorted
  # pair-wise slopes, not a 1.96 * IQR shortcut.
  expect_equal(res$slope$slope, 4.834710420195992e-02, tolerance = 1e-12)
  expect_equal(res$slope$ci_low, 4.091180403806791e-02, tolerance = 1e-12)
  expect_equal(res$slope$ci_high, 5.592670233868577e-02, tolerance = 1e-12)
  # Per-year figures: the day slope times 365.25.
  expect_equal(res$slope$slope_per_year, 1.765877980976586e+01, tolerance = 1e-12)
  expect_equal(res$slope$ci_low_per_year, 1.494303642490430e+01, tolerance = 1e-12)
  expect_equal(res$slope$ci_high_per_year, 2.042722802920498e+01, tolerance = 1e-12)
  expect_equal(res$slope$time_unit, "day")
  expect_equal(res$n, 500)
  expect_equal(res$n_dropped, 0)
  # The residuals carry no AR(1) signal: the Theil-Sen interval stands as-is and
  # no bootstrap ran.
  expect_equal(res$ar1_acf, -2.155305119820414e-02, tolerance = 1e-12)
  expect_equal(res$ar1_p, 6.298479474425585e-01, tolerance = 1e-12)
  expect_false(res$ar_autocorrelated)
  expect_null(res$boot_slope_se)
  expect_true(grepl("increasing", format(res), fixed = TRUE))
})

test_that("nm_trend drops missing values and counts them", {
  df <- .nm_trend_df("nm_trend_demo.csv")
  drop <- c(7L, 100L, 300L, 499L)
  df$demo[drop] <- NA
  res <- nm_trend(df, value_col = "demo", name = "demo")
  expect_equal(res$n, 496)
  expect_equal(res$n_dropped, 4)
  # Dropping the values is the same as removing the rows: the statistic of the
  # remaining 496 values is the same either way.
  res2 <- nm_trend(df[-drop, ], value_col = "demo", name = "demo")
  expect_equal(res$test$S, res2$test$S)
  expect_equal(res$test$z, res2$test$z)
  expect_equal(res$slope$slope, res2$slope$slope)
})

test_that("a record too short is refused", {
  expect_error(nm_trend(1:10, name = "short"), "at least 15 observed values")
})

test_that("a positional vector is tested on the 0..n-1 grid, per step", {
  df <- .nm_trend_df("nm_trend_demo.csv")
  res <- nm_trend(df$demo, name = "positional")
  expect_equal(res$slope$time_unit, "step")
  # The same values, but the axis is in hours, not days: the step slope is the
  # day slope divided by 24, and per-day / per-year figures are not available.
  expect_equal(res$slope$slope, 4.834710420195992e-02 / 24, tolerance = 1e-12)
  expect_null(res$slope$slope_per_year)
})

test_that("an autocorrelated record takes the block-bootstrap path", {
  res <- nm_trend(.nm_trend_df("nm_trend_ar1.csv"), value_col = "ar1", name = "ar1",
                  n_bootstrap = 100)
  # The deterministic parts.
  expect_equal(res$test$S, 210518)
  expect_equal(res$slope$slope, 2.508661955666117e-02, tolerance = 1e-12)
  expect_equal(res$ar1_acf, 7.195775615955065e-01, tolerance = 1e-12)
  expect_true(res$ar_autocorrelated)
  # The week-long block: one calendar week, CPython's exact floor-division of the
  # 7-day quotient (169 for hourly, not the 168 a naive ceiling would give).
  expect_equal(res$block_length, 169L)
  # The bootstrap figures differ from py's draws, but not from the math: the SE is
  # finite, the interval brackets the slope, and a slope this large is significant
  # under either p.
  expect_true(is.finite(res$boot_slope_se) && res$boot_slope_se > 0)
  expect_true(res$boot_ci_low < res$slope$slope && res$slope$slope < res$boot_ci_high)
  expect_true(res$p_wald_boot > 0 && res$p_wald_boot < 0.05)
  # The classical MK p is anti-conservative here: the reading says so.
  expect_match(.nm_trend_reading(res, name = "ar1"), "bootstrap CI", fixed = TRUE)
})

test_that("the segmented test finds the two regimes and pins the deterministic part", {
  brk <- nm_trend_breaks(.nm_trend_df("nm_trend_breaks_demo.csv"), value_col = "v",
                         name = "two-regime", n_bootstrap = 100)
  expect_equal(brk$n_segments, 2L)
  expect_equal(brk$n, 480)
  expect_equal(brk$n_dropped, 0)
  expect_equal(brk$time_unit, "day")
  # Where it breaks: the regime change at 2024-01-09 00:00.
  expect_equal(brk$best_break, as.POSIXct("2024-01-09 00:00:00", tz = "UTC"))
  expect_equal(brk$best_split_pct, 7.937714048475485e+01, tolerance = 1e-6)
  expect_equal(brk$starts, as.POSIXct(c("2024-01-01 00:00:00", "2024-01-09 00:00:00"), tz = "UTC"))
  expect_equal(brk$ends, as.POSIXct(c("2024-01-08 23:00:00", "2024-01-20 23:00:00"), tz = "UTC"))
  # The fit the grid found. The SSE-derived quantities carry a tolerance of
  # 1e-6 rather than the 1e-12 the median-based ones below keep: SSE is a sum
  # over 480 residuals, and Windows accumulates it ~7e-8 (relative) differently
  # from mac/linux (MSVC's pairwise summation), so a tighter pin is red CI on
  # Windows without catching any regression -- a real change moves these by
  # orders of magnitude more. The median-based slopes below are exact on every
  # platform, so they keep the tight pin.
  expect_equal(brk$sse_single, 5.484440048993731, tolerance = 1e-6)
  expect_equal(brk$sse_segmented, 1.131048366501820, tolerance = 1e-6)
  expect_equal(brk$improvement_pct, 7.937714048475483e+01, tolerance = 1e-6)
  expect_equal(brk$bic_single, -2.127976771167126e+03, tolerance = 1e-6)
  expect_equal(brk$bic_segmented, -2.867265032166779e+03, tolerance = 1e-6)
  # The two segments, each with its own Theil-Sen slope and Sen interval.
  expect_equal(brk$segments[[1]]$n, 192L)
  expect_equal(brk$segments[[1]]$slope, 4.944000246864251e-02, tolerance = 1e-12)
  expect_equal(brk$segments[[1]]$ci_low, 4.672922278036513e-02, tolerance = 1e-12)
  expect_equal(brk$segments[[1]]$ci_high, 5.230180973179964e-02, tolerance = 1e-12)
  expect_equal(brk$segments[[2]]$n, 288L)
  expect_equal(brk$segments[[2]]$slope, -1.998919069805219e-02, tolerance = 1e-12)
  expect_equal(brk$segments[[2]]$ci_low, -2.166801123973501e-02, tolerance = 1e-12)
  expect_equal(brk$segments[[2]]$ci_high, -1.827602029072725e-02, tolerance = 1e-12)
  # The block is capped at a third of the record so a resample still holds a cut.
  expect_equal(brk$block_length, 160L)
  # The p is a property of R's draws, not py's: significant at 5 % on a break this
  # large, with a p in (0, 0.05].
  expect_true(brk$p_value > 0 && brk$p_value <= 0.05)
  expect_true(brk$significant)
  expect_equal(brk$alpha, 0.05)
  expect_match(format(brk), "2 segments", fixed = TRUE)
  expect_match(.nm_trend_breaks_reading(brk, name = "two-regime"), "break(s) at", fixed = TRUE)
})

test_that("flat noise stays one regime and says where the search wanted to cut", {
  set.seed(3)
  y <- rnorm(400, 0, 1)
  df <- data.frame(date = as.POSIXct("2024-01-01", tz = "UTC") + (0:399) * 3600, v = y)
  brk <- nm_trend_breaks(df, value_col = "v", name = "flat", n_bootstrap = 100)
  expect_equal(brk$n_segments, 1L)
  expect_false(brk$significant)
  expect_equal(length(brk$segments), 1L)
  expect_equal(brk$starts, as.POSIXct("2024-01-01 00:00:00", tz = "UTC"))
  expect_equal(brk$ends, as.POSIXct("2024-01-17 15:00:00", tz = "UTC"))
  expect_true(!is.null(brk$best_break))  # the candidate is recorded even when refused
  expect_match(paste(brk$notes, collapse = " "), "one regime", fixed = TRUE)
})

test_that("the segmented test's guards", {
  df <- .nm_trend_df("nm_trend_breaks_demo.csv")
  # min_segment leaves no room for two segments.
  expect_error(nm_trend_breaks(df, value_col = "v", min_segment = 300),
               "no room for two segments")
  # max_segments below 2 is a misuse.
  expect_error(nm_trend_breaks(df, value_col = "v", max_segments = 1), "max_segments")
})

test_that("the long-term component is read natively from the decomposition's columns", {
  df <- .nm_trend_df("nm_trend_breaks_demo.csv")
  df$date_unix <- as.numeric(df$date) - as.numeric(as.POSIXct("2024-01-01", tz = "UTC"))
  df$emi_base <- df$v - df$date_unix * 0.05  # some smooth long-term drift
  df$emi_base[1] <- df$emi_base[1] + 1e-9    # keep it off exact degeneracy
  brk <- nm_trend_breaks(df, value_col = "long-term", name = "lt")
  expect_equal(brk$name, "lt")
  expect_true(brk$n_segments >= 1L)
  # And a table without the decomposition's columns refuses the alias.
  expect_error(nm_trend_breaks(.nm_trend_df("nm_trend_breaks_demo.csv"), value_col = "long-term"),
               "no 'date_unix' column")
})
