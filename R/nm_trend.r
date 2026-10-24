# Trend analysis for environmental time-series
#
# Ported from Python normet analysis/trend.py. The deliverable of de-weathering is an
# emission-driven series, and the question every such analysis must answer next is: is
# that series trending, how fast, and can we say so honestly? Hourly air-quality records
# are strongly autocorrelated (diurnal and weekly structure carried through the model),
# and a plain Mann-Kendall test on such a series treats its 8760 hourly values as 8760
# independent draws -- inflating the significance of every trend it finds. This module
# ships the test with the corrections the data demand:
#
# - nm_mann_kendall  : S statistic with tie correction (Hirsch et al. 1982), including
#                      the seasonal variant of Sen (1968) for records that carry a
#                      repeating calendar structure.
# - nm_theil_sen     : robust median pair-wise slope with the analytic Sen (1968) 95 %
#                      confidence interval, in units of *per day* when the input is a
#                      datetime series, so hourly, daily and monthly records compare.
# - nm_trend         : the entry point. Runs both, diagnoses serial correlation of the
#                      trend residuals, and -- when it finds a problem -- replaces the
#                      slope's error estimate with a moving-block bootstrap (block
#                      length long enough to keep the calendar structure together) and a
#                      Wald p-value computed from that bootstrap standard error.
# - nm_trend_breaks  : piecewise (segmented) trend, for records whose level or slope
#                      changes part-way through -- a policy year, a lockdown. Splits the
#                      record into up to max_segments linear segments, each reported with
#                      its own Theil-Sen slope and Sen interval; a split is accepted only
#                      when it beats the BIC penalty *and* the best possible split on
#                      moved-block resamples (the search multiplicity corrected), so a
#                      record with no change is reported as one regime, not as a break
#                      the grid happened to find.
#
# Nothing here resamples the *weather*; this is statistics on the series the user has
# already normalised.

# ---------------------------------------------------------------------------
# Input handling
# ---------------------------------------------------------------------------

#' Reduce a table to the trend's (value, time) pairs.
#'
#' `series` is a data frame or data.table with a `date` column and the values in
#' `value_col`, or a plain numeric vector (a positional record, tested on the
#' 0..n-1 grid and its slopes per *step* -- the record is not assumed hourly).
#' `value_col` may name "long-term", the separated long-term component of an emission
#' decomposition (`date_unix + emi_base`). Missing values are kept, to be dropped and
#' counted by the caller.
#'
#' @return A list: `y` the float values, `dates` POSIXct where the record carries
#'   calendar time, `positional` whether it does not, `name` the series' name.
#' @noRd
.nm_trend_input <- function(series, value_col = NULL, name = NULL) {
  positional <- FALSE
  if (is.data.frame(series) || data.table::is.data.table(series)) {
    if (is.null(value_col)) {
      stop("value_col is required when passing a data frame.", call. = FALSE)
    }
    if (identical(value_col, "long-term")) {
      for (col in c("date_unix", "emi_base")) {
        if (!col %in% names(series)) {
          stop(sprintf(
            "the table has no '%s' column: 'long-term' is the emission decomposition's separated long-term component.",
            col
          ), call. = FALSE)
        }
      }
      y <- as.numeric(series[["date_unix"]] + series[["emi_base"]])
    } else {
      if (!value_col %in% names(series)) {
        stop(sprintf("Column '%s' not in the table.", value_col), call. = FALSE)
      }
      y <- as.numeric(series[[value_col]])
    }
    if (!"date" %in% names(series)) {
      stop(
        "the table has no 'date' column: a positional series is passed as a numeric vector.",
        call. = FALSE
      )
    }
    dates <- .nm_trend_dates(series[["date"]])
    if (is.null(dates)) positional <- TRUE
  } else {
    y <- as.numeric(series)
    dates <- NULL
    positional <- TRUE
  }
  list(
    y = y,
    dates = dates,
    positional = positional,
    name = name %||% value_col %||% "series"
  )
}

#' A column's times as POSIXct, or NULL where it holds no calendar time.
#' @noRd
.nm_trend_dates <- function(d) {
  if (inherits(d, "POSIXct")) return(d)
  if (inherits(d, "Date")) return(as.POSIXct(d, tz = "UTC"))
  if (is.numeric(d) && all(d[!is.na(d)] >= 0) && any(d[!is.na(d)] > 1e12)) {
    return(as.POSIXct(d, origin = "1970-01-01", tz = "UTC"))
  }
  NULL
}

#' The time grid of the finite values, in days (datetime records) or original step
#' positions (positional records, gaps preserved: a missing row is a hole in the grid,
#' not a renumbering of what survives).
#' @noRd
.nm_trend_time_grid <- function(y, dates, positional) {
  finite <- is.finite(y)
  if (!positional && !is.null(dates)) {
    return(as.numeric(dates[finite]) / 86400)
  }
  which(finite) - 1L  # the 0-based positions, as normet-py's positional grid
}

#' The median spacing of a datetime series in days, or NULL where it cannot be said.
#' @noRd
.nm_trend_median_days <- function(y, dates, positional) {
  if (positional || is.null(dates) || length(y) < 2) return(NULL)
  finite <- is.finite(y)
  t <- as.numeric(dates[finite])
  if (length(t) < 2) return(NULL)
  deltas <- diff(sort(t))
  deltas <- deltas[deltas > 0]
  if (!length(deltas)) return(NULL)
  med <- median(deltas) / 86400
  if (is.finite(med) && med > 0) med else NULL
}

#' A break point, spoken the way a report would: date to the minute, or step.
#' @noRd
.nm_fmt_index <- function(value) {
  if (inherits(value, "POSIXct")) format(value, "%Y-%m-%d %H:%M") else as.character(value)
}

# ---------------------------------------------------------------------------
# Mann-Kendall
# ---------------------------------------------------------------------------

#' S = sum over i<j of sign(y_j - y_i) within one group.
#'
#' Row by row: 3.8 billion pairs (a 10-year hourly record in one group) take tens of
#' seconds; O(n) in memory. For such records prefer the seasonal form, whose groups
#' stay smaller.
#' @noRd
.nm_mk_s_statistic <- function(group) {
  n <- length(group)
  if (n < 2) return(0)
  total <- 0
  for (i in seq_len(n - 1)) {
    total <- total + sum(sign(group[(i + 1):n] - group[i]))
  }
  total
}

#' Sum over tied value-groups of t(t-1)(2t+5).
#' @noRd
.nm_mk_tie_correction <- function(values) {
  counts <- as.numeric(table(values))
  t <- counts[counts > 1]
  if (!length(t)) return(0)
  sum(t * (t - 1) * (2 * t + 5))
}

#' The direction a Mann-Kendall test says: increasing or decreasing at the 5 % level,
#' else none.
#' @noRd
.nm_trend_direction <- function(test) {
  if (test$p < 0.05 && test$S > 0) "increasing"
  else if (test$p < 0.05 && test$S < 0) "decreasing"
  else "none"
}

#' Mann-Kendall trend test
#'
#' The Mann-Kendall test on one series: the S statistic with the tie correction of
#' Hirsch et al. (1982), its variance, the continuity-corrected z and the two-sided
#' p. Missing values are dropped and counted in `n`. With `seasonal_period` the
#' seasonal (Sen 1968) variant: the S statistic is the sum of the classical S computed
#' within each calendar slot (for a 24-hour period, slot m is every value recorded at
#' hour m, ordered by day). The record must hold a whole number of full periods after
#' dropping missing values; anything else errors rather than testing uneven groups,
#' which is where the variance formula silently breaks.
#'
#' @param series A data frame with a `date` column and a value column, or a numeric
#'   vector (positional).
#' @param value_col The value column where `series` is a data frame.
#' @param seasonal_period The repeating calendar period in steps of the record
#'   (24 hourly, 7 daily, 12 monthly), or NULL for the classical test.
#' @return An object of class `nm_trend_test`: `S`, `var_S`, `z`, `p`, `n`, `seasonal`
#'   and `n_periods` (the calendar groups, when seasonal).
#' @export
nm_mann_kendall <- function(series, value_col = NULL, seasonal_period = NULL) {
  tin <- .nm_trend_input(series, value_col)
  y <- tin$y
  x <- y[is.finite(y)]
  if (length(x) < 8) {
    stop(sprintf(
      "nm_mann_kendall needs at least 8 observed values, got %d (the test's normal approximation is the wrong tool before that).",
      length(x)
    ), call. = FALSE)
  }
  n_periods_out <- NULL
  if (!is.null(seasonal_period)) {
    period <- as.integer(seasonal_period)
    if (period < 2) stop(sprintf("seasonal_period must be >= 2, got %d.", period), call. = FALSE)
    n_periods <- length(x) %/% period
    remainder <- length(x) %% period
    if (remainder != 0) {
      stop(sprintf(
        "a seasonal test with period %d needs a whole number of periods, but the record holds %d values (%d full periods + %d). Drop the trailing partial period or leave seasonal_period NULL.",
        period, length(x), n_periods, remainder
      ), call. = FALSE)
    }
    g <- period
    # Sen (1968): slot m is every m-th value from the start -- grouping consecutive
    # periods instead would measure the cycle's own rise-then-fall shape, not the
    # between-year trend, and come out systematically signed for any cyclic signal.
    slots <- seq_along(x) - 1L
    S <- 0
    tie_sum <- 0
    for (m in seq_len(g)) {
      grp <- x[slots %% g == (m - 1L)]
      S <- S + .nm_mk_s_statistic(grp)
      tie_sum <- tie_sum + .nm_mk_tie_correction(grp)
    }
    m_size <- length(x) %/% g
    # Per-slot classical variance, summed across the slots: Var(S) of one group of
    # size m is m(m-1)(2m+5)/18 (Hirsch et al. 1982); the slots are disjoint, so
    # their variances add.
    var_S <- g * (m_size * (m_size - 1) * (2 * m_size + 5)) / 18 - tie_sum / 18
    n_periods_out <- g
  } else {
    S <- .nm_mk_s_statistic(x)
    # Standard MK variance with tie correction (Hirsch et al. 1982):
    # Var(S) = [n(n-1)(2n+5) - sum_t t(t-1)(2t+5)] / 18.
    var_S <- (length(x) * (length(x) - 1) * (2 * length(x) + 5) -
      .nm_mk_tie_correction(x)) / 18
  }

  if (var_S <= 0) {
    # Every value identical: S is 0 and its variance is 0 by the same formula.
    # Report no trend rather than dividing by zero.
    return(.nm_trend_test(0, 0, 0, 1, length(x), FALSE, n_periods_out))
  }
  z <- if (S > 0) (S - 1) / sqrt(var_S) else if (S < 0) (S + 1) / sqrt(var_S) else 0
  p <- 2 * (1 - stats::pnorm(abs(z)))
  .nm_trend_test(S, var_S, z, p, length(x), !is.null(seasonal_period), n_periods_out)
}

#' @noRd
.nm_trend_test <- function(S, var_S, z, p, n, seasonal = FALSE, n_periods = NULL) {
  structure(
    list(
      S = S, var_S = as.numeric(var_S), z = as.numeric(z), p = as.numeric(p),
      n = as.integer(n), seasonal = seasonal, n_periods = n_periods
    ),
    class = "nm_trend_test"
  )
}

# ---------------------------------------------------------------------------
# Theil-Sen
# ---------------------------------------------------------------------------

#' A Fenwick tree over positions 1..n: the rank counts the counting quantile keeps.
#' @noRd
.nm_fenwick <- function(n) {
  bit <- integer(n + 1L)
  list(
    add = function(i, delta = 1L) {
      while (i <= n) {
        bit[i] <- bit[i] + delta
        i <- i + (i & -i)
      }
      invisible(NULL)
    },
    query = function(i) {
      s <- 0L
      while (i > 0) {
        s <- s + bit[i]
        i <- i - (i & -i)
      }
      s
    }
  )
}

#' The k-th smallest of all pair-wise slopes of (x, y) (k from 1), without forming
#' them.
#'
#' For a threshold v the slope of the pair (i, j), i < j, is at most v when
#' y_j - v x_j <= y_i - v x_i, so the k-th order statistic of the slopes is the
#' smallest v with at least k pairs at or below it, found by a bisection against that
#' count (each count runs in O(n log n) over the sorted transformed values). The
#' bisection's limit is the step function's jump -- one of the pair-wise slopes
#' themselves.
#' @noRd
.nm_pairwise_order_stat <- function(x, y, k) {
  n <- length(y)
  gap <- min(diff(x))
  bound <- 2 * max(abs(y)) / gap
  count_le <- function(v) {
    w <- y - v * x
    ord <- order(w, method = "radix")
    rank <- integer(n)
    rank[ord] <- seq_len(n)
    bit <- .nm_fenwick(n)
    total <- 0L
    for (i in n:1) {
      total <- total + bit$query(rank[i])  # the later positions at rank <= rank[i]
      bit$add(rank[i])
    }
    total
  }
  lo <- -bound
  hi <- bound
  repeat {
    if (hi - lo <= 4 * .Machine$double.eps * max(1, abs(lo), abs(hi))) break
    mid <- (lo + hi) / 2
    if (count_le(mid) >= k) hi <- mid else lo <- mid
  }
  (lo + hi) / 2
}

#' The linearly interpolated (numpy type 7) median of all pair-wise slopes, without
#' forming them: a convex combination of two adjacent order statistics.
#' @noRd
.nm_pairwise_median <- function(x, y) {
  n <- length(y)
  m_pairs <- n * (n - 1) / 2
  h <- 0.5 * (m_pairs - 1)  # 0-based rank, numpy's linear interpolation
  j <- floor(h)
  g <- h - j
  if (g < 1e-12) {
    return(.nm_pairwise_order_stat(x, y, j + 1L))
  }
  (1 - g) * .nm_pairwise_order_stat(x, y, j + 1L) + g * .nm_pairwise_order_stat(x, y, j + 2L)
}

#' The Theil-Sen slope of (x, y), with the Sen (1968) 95 % interval.
#'
#' As scipy.stats.theilslopes: the slope is the median pair-wise slope, and the
#' interval's endpoints are two order statistics of the pair-wise slopes, the indices
#' from equation (2.6) of Sen (1968) -- the variance of S with the tie corrections of
#' the repeated x and y values, and the 95 % normal deviate. All pair-wise slopes are
#' computed where the record is small enough to hold them (at most 5 x 10^7 pairs);
#' above that, the three needed order statistics are selected directly by counting
#' (see .nm_pairwise_order_stat).
#' @noRd
.nm_theil_sen_fit <- function(x, y) {
  n <- length(y)
  nt <- n * (n - 1) / 2  # N in Sen (1968): the number of pair-wise slopes
  # Equation 2.6 in Sen (1968), as scipy writes it: the S variance with the tie
  # corrections of the repeated values (a single value's group contributes 0).
  xreps <- as.numeric(table(x))
  yreps <- as.numeric(table(y))
  sigsq <- (n * (n - 1) * (2 * n + 5) -
    sum(xreps * (xreps - 1) * (2 * xreps + 5)) -
    sum(yreps * (yreps - 1) * (2 * yreps + 5))) / 18
  sigma <- sqrt(pmax(0, sigsq))
  z <- qnorm(0.025)  # the 95 % normal deviate, negative as in scipy
  ru0 <- min(round((nt - z * sigma) / 2), nt - 1)  # 0-based index of the upper end
  rl0 <- max(round((nt + z * sigma) / 2) - 1, 0)  # 0-based index of the lower end
  if (nt <= 5e7) {
    slopes <- .nm_pairwise_slopes(x, y)
    medslope <- as.numeric(stats::quantile(slopes, probs = 0.5, type = 7))
    ord <- order(slopes, method = "radix")
    low <- slopes[ord[rl0 + 1L]]
    high <- slopes[ord[ru0 + 1L]]
    rm(slopes, ord)
  } else {
    medslope <- .nm_pairwise_median(x, y)
    low <- .nm_pairwise_order_stat(x, y, rl0 + 1L)
    high <- .nm_pairwise_order_stat(x, y, ru0 + 1L)
  }
  list(slope = medslope, ci_low = low, ci_high = high)
}

#' Every pair-wise slope of (x, y): x strictly increasing, both finite.
#' @noRd
.nm_pairwise_slopes <- function(x, y) {
  n <- length(y)
  m_pairs <- n * (n - 1) / 2
  out <- numeric(m_pairs)
  pos <- 1L
  for (i in seq_len(n - 1)) {
    take <- (y[(i + 1):n] - y[i]) / (x[(i + 1):n] - x[i])
    out[pos:(pos + length(take) - 1L)] <- take
    pos <- pos + length(take)
  }
  out
}

#' Theil-Sen slope of a series against time
#'
#' The robust median pair-wise slope (as scipy.stats.theilslopes), with the analytic
#' Sen (1968) 95 % interval on the slope. The slope is per *day* where the record
#' carries calendar time -- so hourly, daily and monthly records compare -- and per
#' *step* for a positional one; `slope_per_year` is the day slope times 365.25, given
#' only where a per-year conversion is meaningful.
#'
#' @param series A data frame with a `date` column and a value column, or a numeric
#'   vector (positional).
#' @param value_col The value column where `series` is a data frame.
#' @return An object of class `nm_trend_slope`: `slope`, `ci_low`, `ci_high`, `n`,
#'   `time_unit` ("day" or "step") and, where temporal, the per-year figures.
#' @export
nm_theil_sen <- function(series, value_col = NULL) {
  tin <- .nm_trend_input(series, value_col)
  y <- tin$y
  x <- y[is.finite(y)]
  if (length(x) < 4) {
    stop(sprintf("nm_theil_sen needs at least 4 observed values, got %d.", length(x)),
      call. = FALSE
    )
  }
  xtime <- .nm_trend_time_grid(y, tin$dates, tin$positional)
  fit <- .nm_theil_sen_fit(xtime, x)
  time_unit <- if (tin$positional) "step" else "day"
  out <- list(
    slope = fit$slope, ci_low = fit$ci_low, ci_high = fit$ci_high,
    n = length(x), time_unit = time_unit,
    slope_per_year = NULL, ci_low_per_year = NULL, ci_high_per_year = NULL
  )
  if (!is.null(.nm_trend_median_days(y, tin$dates, tin$positional))) {
    days <- 365.25
    out$slope_per_year <- out$slope * days
    out$ci_low_per_year <- out$ci_low * days
    out$ci_high_per_year <- out$ci_high * days
  }
  structure(out, class = "nm_trend_slope")
}

# ---------------------------------------------------------------------------
# Serial-correlation diagnostic + block bootstrap
# ---------------------------------------------------------------------------

#' ACF(1) of the OLS trend residuals and a large-sample p-value.
#'
#' acf1 = sum(r_t r_{t-1}) / sum(r_t^2) is the sample autocorrelation; p =
#' 2(1-Phi(|acf1| sqrt(n))), the sample ACF(1) being approximately N(0, 1/n) under a
#' no-autocorrelation null.
#' @noRd
.nm_ar1_residuals_acf <- function(y, x) {
  n <- length(y)
  if (n < 8) return(c(NA_real_, NA_real_))
  fit <- stats::lm(y ~ x)
  resid <- stats::residuals(fit)
  denom <- sum(resid^2)
  if (denom <= 0) return(c(0, 1))
  acf1 <- sum(resid[2:n] * resid[1:(n - 1)]) / denom
  z <- acf1 * sqrt(n)
  c(acf1, 2 * (1 - stats::pnorm(abs(z))))
}

#' Moving-block length: the longer of 3 n^(1/3) and one calendar week (sub-daily
#' records only), capped at n/3.
#' @noRd
.nm_default_block_length <- function(n, med_days = NULL) {
  length_ <- max(3L, as.integer(round(3 * n^(1 / 3))))
  if (!is.null(med_days) && med_days > 0 && med_days < 1) {
    # One calendar week, ceiled the way Python's -(-7 // med_days) ceils it:
    # CPython's float floor division is exact about the true quotient, so for
    # hourly points (med_days the double just under 1/24) a week is 169, not 168.
    length_ <- max(length_, .nm_week_ceil(med_days))
  }
  if (n >= 9) min(length_, n %/% 3) else 3L
}

#' The smallest integer k with k * md >= 7 in the exact real sense -- the value
#' CPython's -(-7 // md) gives, its float floor division using the true quotient
#' rather than the rounded one (Objects/floatobject.c).
#'
#' The IEEE quotient is within one of the answer, so the candidates around it are
#' tested by exact integer-times-double products: md is Dekker-split into a 27-bit
#' head and a 26-bit tail, each product exact for k below 2^26, and the sum is
#' compared with 7 by a TwoSum so the low bits decide the boundary.
#' @noRd
.nm_week_ceil <- function(md) {
  c1 <- 134217729  # 2^27 + 1, the Dekker splitting constant
  t <- c1 * md
  hi <- t - (t - md)
  lo <- md - hi
  ge7 <- function(k) {
    a <- k * hi  # exact: k below 2^26, hi 27 bits
    b <- k * lo  # exact: lo 26 bits
    s <- a + b
    bv <- s - a
    e <- (a - (s - bv)) + (b - bv)  # TwoSum: s + e is the exact product
    # Compare without the last addition, which would round s + e back onto 7:
    # s + e >= 7 holds iff s > 7, or s == 7 with e >= 0 (e < 0 is the case
    # 168 * the-double-just-under-1/24, a week of hourly points).
    s > 7 || (s == 7 && e >= 0)
  }
  k <- as.integer(floor(7 / md))
  if (k < 1L) k <- 1L
  while (k > 1L && ge7(k - 1L)) k <- k - 1L
  while (!ge7(k)) k <- k + 1L
  k
}

#' Ordinary-least-squares slope for one bootstrap replicate (O(n)).
#' @noRd
.nm_ols_slope <- function(x, y) {
  sx <- sum(x)
  sy <- sum(y)
  sxy <- sum(x * y)
  sxx <- sum(x * x)
  denom <- length(x) * sxx - sx * sx
  if (denom == 0) return(NA_real_)
  (length(x) * sxy - sx * sy) / denom
}

#' Seed the global RNG for a bootstrap run (the package's convention).
#' @noRd
.nm_rng <- function(seed) {
  set.seed(seed)
  invisible(TRUE)
}

#' Moving-block bootstrap of the OLS trend slope.
#'
#' Blocks of `block_length` contiguous points are drawn with replacement until n points
#' are assembled; the last block is truncated. Each replicate uses the OLS slope (the
#' block sampling is what fixes the autocorrelation, not the per-replicate estimator).
#' @noRd
.nm_block_bootstrap_slopes <- function(x, y, block_length, n_bootstrap, seed) {
  n <- length(x)
  .nm_rng(seed)
  n_starts <- n - block_length + 1L
  full <- n %/% block_length
  remain <- n - full * block_length
  slopes <- numeric(n_bootstrap)
  for (b in seq_len(n_bootstrap)) {
    if (full > 0) {
      starts <- sample.int(n_starts, size = full, replace = TRUE) - 1L
      idx <- unlist(lapply(starts, function(s) s:(s + block_length - 1L)))
    } else {
      idx <- integer(0)
    }
    if (remain > 0 && n_starts > 0) {
      s0 <- sample.int(n_starts, 1L) - 1L
      idx <- c(idx, s0:(s0 + remain - 1L))
    }
    slopes[b] <- .nm_ols_slope(x[idx + 1L], y[idx + 1L])
  }
  slopes
}

# ---------------------------------------------------------------------------
# Piecewise (segmented) trend breaks
# ---------------------------------------------------------------------------

#' Cumulative sums of the five quantities an OLS fit on any sub-range needs: each
#' array is padded with a leading zero, so the OLS residual sum of squares of any
#' segment is O(1) from centered moments.
#' @noRd
.nm_prefix_sums <- function(x, y) {
  zero <- 0
  list(
    c(zero, cumsum(x)), c(zero, cumsum(y)),
    c(zero, cumsum(x * x)), c(zero, cumsum(y * y)), c(zero, cumsum(x * y))
  )
}

#' OLS residual sum of squares of the points (i, j] (1-based), from prefix sums.
#' @noRd
.nm_segment_sse <- function(pre, i, j) {
  m <- j - i
  if (m < 2) return(NA_real_)
  sx <- pre[[1]][j] - pre[[1]][i]
  sy <- pre[[2]][j] - pre[[2]][i]
  sxx <- pre[[3]][j] - pre[[3]][i]
  syy <- pre[[4]][j] - pre[[4]][i]
  sxy <- pre[[5]][j] - pre[[5]][i]
  sxx_c <- sxx - sx * sx / m
  if (sxx_c <= 1e-12) {
    # x (nearly) constant: only a mean is identifiable; the squared deviation of y
    # from its own mean is the attainable fit.
    return(max(0, syy - sy * sy / m))
  }
  syy_c <- syy - sy * sy / m
  sxy_c <- sxy - sx * sy / m
  max(0, syy_c - sxy_c * sxy_c / sxx_c)
}

#' BIC of a piecewise-linear fit: three parameters per segment (slope, intercept,
#' noise variance). -Inf for a perfect fit keeps the comparisons total: two perfect
#' fits tie, so an exact linear record stops at one segment.
#' @noRd
.nm_bic <- function(sse, n, n_segments) {
  if (sse <= 0) return(-Inf)
  n * log(sse / n) + 3 * n_segments * log(n)
}

#' Two-segment OLS SSE, for every candidate split at once: for each candidate c, the
#' SSE of (i, c] plus the SSE of [c, j).
#' @noRd
.nm_segment_sse_range <- function(pre, i, j, c) {
  # left pieces (i, c] + right pieces [c, j), both at once:
  sse_left <- function() {
    m <- c - i
    sx <- pre[[1]][c] - pre[[1]][i]
    sy <- pre[[2]][c] - pre[[2]][i]
    sxx <- pre[[3]][c] - pre[[3]][i]
    syy <- pre[[4]][c] - pre[[4]][i]
    sxy <- pre[[5]][c] - pre[[5]][i]
    sxx_c <- sxx - sx * sx / m
    syy_c <- syy - sy * sy / m
    sxy_c <- sxy - sx * sy / m
    pmax(0, syy_c - sxy_c * sxy_c / sxx_c)
  }
  sse_right <- function() {
    m <- j - c
    sx <- pre[[1]][j] - pre[[1]][c]
    sy <- pre[[2]][j] - pre[[2]][c]
    sxx <- pre[[3]][j] - pre[[3]][c]
    syy <- pre[[4]][j] - pre[[4]][c]
    sxy <- pre[[5]][j] - pre[[5]][c]
    sxx_c <- sxx - sx * sx / m
    syy_c <- syy - sy * sy / m
    sxy_c <- sxy - sx * sy / m
    pmax(0, syy_c - sxy_c * sxy_c / sxx_c)
  }
  sse_left() + sse_right()
}

#' Best single split of segment (i, j] by SSE reduction: (best_c, sse_before,
#' sse_after), best_c NULL where the segment is too short to split.
#' @noRd
.nm_scan_split <- function(pre, i, j, min_segment) {
  now <- .nm_segment_sse(pre, i, j)
  lo <- i + min_segment
  hi <- j - min_segment
  if (hi < lo) return(list(best_c = NULL, now = now, after = Inf))
  c <- lo:hi
  after <- .nm_segment_sse_range(pre, i, j, c)
  k <- which.min(after)
  list(best_c = as.integer(c[k]), now = now, after = as.numeric(after[k]))
}

#' Greedy forward segmentation: repeatedly split the worst segment, accepting a split
#' only when BIC says the extra parameters earn their keep.
#' @noRd
.nm_greedy_segments <- function(x, y, max_segments, min_segment) {
  n <- length(x)
  pre <- .nm_prefix_sums(x, y)
  total <- .nm_segment_sse(pre, 1L, n + 1L)
  segs <- list(c(1L, n + 1L))
  first_candidate <- NULL
  k <- 1L
  while (k < max_segments) {
    best_gain <- NULL
    best_cut <- NULL
    bic_now <- .nm_bic(total, n, k)
    for (ij in segs) {
      i <- ij[1]
      j <- ij[2]
      sc <- .nm_scan_split(pre, i, j, min_segment)
      if (is.null(sc$best_c)) next
      if (k == 1L && i == 1L) {
        # Positive pct = the split's SSE reduction, recorded even when the BIC gate
        # below rejects the split.
        first_candidate <- list(
          c = sc$best_c,
          pct = if (sc$now > 0) 100 * (sc$now - sc$after) / sc$now else 0
        )
      }
      gain <- sc$now - sc$after
      if (gain <= 0 || .nm_bic(total - gain, n, k + 1) >= bic_now) next
      if (is.null(best_gain) || gain > best_gain) {
        best_gain <- gain
        best_cut <- c(i, j, sc$best_c)
      }
    }
    if (is.null(best_cut) || is.null(best_gain)) break
    i <- best_cut[1]
    j <- best_cut[2]
    c <- best_cut[3]
    keep <- vapply(segs, function(sg) !identical(unname(sg[1:2]), c(i, j)), TRUE)
    segs <- c(segs[keep], list(c(i, c), c(c, j)))
    total <- total - best_gain
    k <- k + 1L
  }
  segs <- segs[order(vapply(segs, function(sg) sg[1], numeric(1)))]
  list(segments = segs, sse = total, n_segments = k, first_candidate = first_candidate)
}

#' Indices (1-based) of one moved-block resample of n points: full blocks, truncated
#' tail -- the same scheme as .nm_block_bootstrap_slopes.
#' @noRd
.nm_block_indices <- function(n, block_length) {
  n_starts <- n - block_length + 1L
  full <- n %/% block_length
  remain <- n - full * block_length
  idx <- if (full > 0) {
    starts <- sample.int(n_starts, size = full, replace = TRUE) - 1L
    unlist(lapply(starts, function(s) s:(s + block_length - 1L)))
  } else {
    integer(0)
  }
  if (remain > 0 && n_starts > 0) {
    s0 <- sample.int(n_starts, 1L) - 1L
    idx <- c(idx, s0:(s0 + remain - 1L))
  }
  idx + 1L
}

#' Block-bootstrap p-value for the best-split improvement.
#'
#' Each replicate re-runs the entire greedy search on a moved-block resample of the
#' (time, value) pairs and records how much pure-noise searching improved over that
#' replicate's single-segment fit; comparing the observed improvement against that null
#' distribution corrects for having looked at n-1 possible positions (and for the
#' autocorrelation, which the block sampling preserves).
#' @noRd
.nm_break_search_p <- function(x, y, max_segments, min_segment, improvement_obs,
                               block_length, n_bootstrap, seed) {
  n <- length(x)
  .nm_rng(seed)
  ge <- 0L
  for (b in seq_len(n_bootstrap)) {
    idx <- .nm_block_indices(n, block_length)
    xb <- x[idx]
    yb <- y[idx]
    pre <- .nm_prefix_sums(xb, yb)
    sse_single_rep <- .nm_segment_sse(pre, 1L, n + 1L)
    greedy <- .nm_greedy_segments(xb, yb, max_segments, min_segment)
    if (sse_single_rep - greedy$sse >= improvement_obs - 1e-9) ge <- ge + 1L
  }
  (1 + ge) / (1 + n_bootstrap)
}

#' Theil-Sen slope of one segment [i, j) (1-based) straight off the time grid.
#'
#' The fit goes on the time coordinates themselves, not on a re-sliced original series:
#' slicing a positional record would renumber its index (or leave the hole the trend
#' documents) and a datetime slice would re-run the whole input handling for no reason.
#' @noRd
.nm_segment_theil_sen <- function(xtime, y, i, j, positional) {
  fit <- .nm_theil_sen_fit(xtime[i:(j - 1L)], y[i:(j - 1L)])
  out <- list(
    slope = fit$slope, ci_low = fit$ci_low, ci_high = fit$ci_high,
    n = j - i, time_unit = if (positional) "step" else "day",
    slope_per_year = NULL, ci_low_per_year = NULL, ci_high_per_year = NULL
  )
  if (!positional) {
    out$slope_per_year <- out$slope * 365.25
    out$ci_low_per_year <- out$ci_low * 365.25
    out$ci_high_per_year <- out$ci_high * 365.25
  }
  structure(out, class = "nm_trend_slope")
}

#' Detect trend breaks: the segmented fit of a series
#'
#' Splits the record into at most `max_segments` linear segments, each reported with
#' its own Theil-Sen slope and Sen (1968) interval. The split comes from a full grid
#' search (the two-segment SSE of every candidate position is O(1) from prefix sums)
#' and is accepted only under a two-part gate: per round, the split must improve the
#' BIC over the current fit; and the SSE improvement of the final fit over the
#' single-segment fit must beat the same search re-run on moved-block resamples -- the
#' multiple-testing-corrected, autocorrelation-aware p is the one to quote. A record
#' that fails a gate is reported as one regime, with the best candidate cut and its
#' p kept so a report can say what was looked at.
#'
#' @param series A data frame with a `date` column and a value column, or a numeric
#'   vector (positional).
#' @param value_col The value column where `series` is a data frame. "long-term" is the
#'   emission decomposition's separated long-term component (date_unix + emi_base).
#' @param name A label for the one-line report; defaults to the column's.
#' @param max_segments Upper bound on segments (one split with the default).
#' @param min_segment Minimum points per segment; defaults to the longer of 28 and 5 %
#'   of the record.
#' @param alpha The threshold the bootstrap p-value must fall below for a break to be
#'   reported.
#' @param block_length Bootstrap block length in points; defaults to the same
#'   heuristic as \code{\link{nm_trend}}.
#' @param n_bootstrap Replicates of the search under the block-bootstrapped null.
#' @param seed The RNG seed; the result is reproducible.
#' @return An object of class `nm_trend_breaks`, with `summary()` (one row per segment)
#'   and a one-line `format()`.
#' @export
nm_trend_breaks <- function(series, value_col = NULL, name = NULL, max_segments = 2,
                            min_segment = NULL, alpha = 0.05, block_length = NULL,
                            n_bootstrap = 500, seed = 7654321) {
  tin <- .nm_trend_input(series, value_col)
  y <- tin$y
  finite <- is.finite(y)
  x <- y[finite]
  n <- length(x)
  n_dropped <- length(y) - n
  if (n < 40) {
    stop(sprintf(
      "nm_trend_breaks needs at least 40 observed values, got %d -- a split test on fewer is a statement about the noise, not the record.",
      n
    ), call. = FALSE)
  }
  max_segments <- as.integer(max_segments)
  if (max_segments < 2) stop(sprintf("max_segments must be at least 2, got %d.", max_segments),
    call. = FALSE
  )
  if (!(alpha > 0 && alpha < 1)) stop(sprintf("alpha must lie in (0, 1), got %s.", alpha),
    call. = FALSE
  )
  n_bootstrap <- as.integer(n_bootstrap)
  if (n_bootstrap < 50) {
    stop(sprintf(
      "n_bootstrap must be at least 50 (the p-value's resolution is 1/%d), got %d.",
      n_bootstrap, n_bootstrap
    ), call. = FALSE)
  }

  min_seg <- if (is.null(min_segment)) max(28L, as.integer(n %/% 20)) else as.integer(min_segment)
  if (min_seg < 2) stop(sprintf("min_segment must be at least 2, got %d.", min_seg),
    call. = FALSE
  )
  if (2 * min_seg > n) {
    stop(sprintf(
      "min_segment=%d leaves no room for two segments (%d > %d observed values); pass a smaller min_segment.",
      min_seg, 2 * min_seg, n
    ), call. = FALSE)
  }

  xtime <- .nm_trend_time_grid(y, tin$dates, tin$positional)
  dates <- if (is.null(tin$dates)) NULL else tin$dates[finite]
  time_unit <- if (tin$positional) "step" else "day"

  pre <- .nm_prefix_sums(xtime, x)
  sse_single <- .nm_segment_sse(pre, 1L, n + 1L)
  greedy <- .nm_greedy_segments(xtime, x, max_segments, min_seg)
  k <- greedy$n_segments
  sse_final <- greedy$sse
  bic_single <- .nm_bic(sse_single, n, 1)
  bic_final <- .nm_bic(sse_final, n, k)
  # The first round's best candidate is the reportable break: it exists whether or not
  # the BIC gate accepted it, so a record reported as one regime still says where the
  # search wanted to cut.
  best_break <- if (is.null(greedy$first_candidate)) NULL else
    if (is.null(dates)) as.numeric(greedy$first_candidate$c) else dates[greedy$first_candidate$c]
  best_split_pct <- if (is.null(greedy$first_candidate)) 0 else as.numeric(greedy$first_candidate$pct)

  result <- structure(
    list(
      name = name %||% tin$name, n = n, n_dropped = n_dropped, time_unit = time_unit,
      starts = NULL, ends = NULL, segments = list(), n_segments = 1L,
      best_break = best_break, best_split_pct = best_split_pct,
      sse_single = sse_single, sse_segmented = sse_final,
      improvement_pct = if (sse_single > 0) 100 * (1 - sse_final / sse_single) else 0,
      bic_single = bic_single, bic_segmented = bic_final,
      p_value = NULL, significant = FALSE, alpha = as.numeric(alpha),
      max_segments = max_segments, min_segment = min_seg,
      block_length = NULL, n_bootstrap = NULL, notes = character()
    ),
    class = "nm_trend_breaks"
  )

  whole <- function() {
    list(
      starts = if (is.null(dates)) 1L else dates[1],
      ends = if (is.null(dates)) n else dates[n],
      segments = list(nm_theil_sen(series, value_col))
    )
  }

  if (k == 1L) {
    result$notes <- c(
      result$notes,
      paste0(
        "No split passed the BIC gate; the record is one regime. The search's best ",
        "candidate cut is recorded (best_break=", .nm_fmt_index(best_break),
        ", best_split_pct=", sprintf("%.1f", best_split_pct), ")."
      )
    )
    w <- whole()
    result$segments <- w$segments
    result$starts <- w$starts
    result$ends <- w$ends
    return(result)
  }

  bl <- if (!is.null(block_length)) as.integer(block_length) else
    .nm_default_block_length(n, med_days = .nm_trend_median_days(y, tin$dates, tin$positional))
  bl <- max(1L, min(bl, n %/% 3))
  improvement_obs <- sse_single - sse_final
  p <- .nm_break_search_p(xtime, x, max_segments, min_seg, improvement_obs,
                          bl, n_bootstrap, seed)
  result$block_length <- bl
  result$n_bootstrap <- n_bootstrap
  result$p_value <- as.numeric(p)
  result$significant <- p < alpha

  if (!result$significant) {
    # The grid found a split and BIC liked it, but the search under the null found
    # splits just as good: report one regime and say why.
    result$notes <- c(
      result$notes,
      sprintf(
        paste0(
          "Best split at %s cuts the SSE by %.1f%%, but the same search on %d ",
          "block-bootstrapped resamples reaches an improvement at least that large ",
          "with p=%.3g >= alpha=%s: one regime reported, no break claimed."
        ),
        .nm_fmt_index(best_break), result$improvement_pct, n_bootstrap, p, alpha
      )
    )
    w <- whole()
    result$segments <- w$segments
    result$starts <- w$starts
    result$ends <- w$ends
    return(result)
  }

  segs <- greedy$segments
  result$n_segments <- k
  result$starts <- if (is.null(dates)) {
    vapply(segs, function(sg) as.numeric(sg[1]), numeric(1))
  } else {
    do.call(c, lapply(segs, function(sg) dates[sg[1]]))
  }
  result$ends <- if (is.null(dates)) {
    vapply(segs, function(sg) as.numeric(sg[2] - 1L), numeric(1))
  } else {
    do.call(c, lapply(segs, function(sg) dates[sg[2] - 1L]))
  }
  # Theil-Sen per segment, fit on the time grid directly so a positional record with
  # holes is neither renumbered nor misread, and the Sen interval / per-year units
  # follow the whole-record code path.
  result$segments <- lapply(segs, function(sg)
    .nm_segment_theil_sen(xtime, x, sg[1], sg[2], tin$positional))
  nbreaks <- k - 1L
  result$notes <- c(
    result$notes,
    sprintf(
      paste0(
        "%d break%s accepted: each passed the BIC gate and the block-bootstrap gate ",
        "(p=%.3g < alpha=%s, %d resamples, block length %d). Segment slopes are ",
        "Theil-Sen per segment; compare adjacent segments against their Sen ",
        "intervals rather than re-testing the split."
      ),
      nbreaks, if (nbreaks == 1L) "" else "s", p, alpha, n_bootstrap, bl
    )
  )
  result
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

#' Trend test, robust slope and honest error bars for one series
#'
#' Runs \code{\link{nm_mann_kendall}} and \code{\link{nm_theil_sen}}, then asks
#' whether the residuals of a linear fit are autocorrelated. If they are (which hourly
#' normalised almost always is), the Theil-Sen interval -- which assumes independent
#' sampling -- is supplemented with a moving-block bootstrap standard error, bootstrap
#' interval and a Wald p-value from that bootstrap SE. The Mann-Kendall p-value is
#' always the classical one: there is no equally standard autocorrelated variant, so
#' the result carries an explicit note rather than pretending it was corrected.
#'
#' A known asymmetry, documented rather than hidden: the bootstrap SE is estimated from
#' OLS replicate slopes (fast, O(n) per replicate), while the point estimate and the
#' classical interval are Theil-Sen. On a record riddled with extreme spikes the OLS
#' variance -- not the robust variance -- is what the bootstrap measures, so read
#' `p_wald_boot` as the corrected significance of the *OLS* trend.
#'
#' @param series A data frame with a `date` column and a value column, or a numeric
#'   vector (positional).
#' @param value_col The value column where `series` is a data frame. "long-term" is the
#'   emission decomposition's separated long-term component (date_unix + emi_base).
#' @param name A label for the one-line report; defaults to the column's.
#' @param seasonal_period Forwarded to \code{\link{nm_mann_kendall}} (Sen 1968).
#' @param test_alpha The threshold at which the AR(1) diagnostic triggers the bootstrap.
#' @param block_length Bootstrap block length in points. Defaults to the longer of the
#'   Politis-Romano 3 n^(1/3) heuristic and one calendar week for sub-daily records.
#' @param n_bootstrap Bootstrap replicates.
#' @param seed The RNG seed; the bootstrap output is reproducible.
#' @return An object of class `nm_trend_result`, with `summary()` (a two-column
#'   metric/value table) and a one-line `format()`.
#' @export
nm_trend <- function(series, value_col = NULL, name = NULL, seasonal_period = NULL,
                     test_alpha = 0.05, block_length = NULL, n_bootstrap = 1000,
                     seed = 7654321) {
  tin <- .nm_trend_input(series, value_col)
  y <- tin$y
  finite <- is.finite(y)
  x <- y[finite]
  n_dropped <- length(y) - length(x)
  if (length(x) < 15) {
    stop(sprintf(
      "nm_trend() needs at least 15 observed values, got %d -- a trend test on fewer is a statement about the noise, not the trend.",
      length(x)
    ), call. = FALSE)
  }

  # The original series goes to both sub-tests (each re-runs the input handling); the
  # finite values' time grid and values go to the diagnostic and the bootstrap.
  test <- nm_mann_kendall(series, value_col, seasonal_period = seasonal_period)
  slope <- nm_theil_sen(series, value_col)
  xtime <- .nm_trend_time_grid(y, tin$dates, tin$positional)
  acf <- .nm_ar1_residuals_acf(x, xtime)
  autocorrelated <- is.finite(acf[2]) && acf[2] < test_alpha

  result <- structure(
    list(
      name = name %||% tin$name, n = length(x), n_dropped = n_dropped,
      test = test, slope = slope,
      ar1_acf = acf[1], ar1_p = acf[2], ar_autocorrelated = autocorrelated,
      boot_slope_se = NULL, boot_ci_low = NULL, boot_ci_high = NULL,
      p_wald_boot = NULL, block_length = NULL, n_bootstrap = NULL,
      notes = character()
    ),
    class = "nm_trend_result"
  )
  if (!autocorrelated) {
    result$notes <- c(
      result$notes,
      "AR(1) residual autocorrelation not significant; the Theil-Sen interval is used as-is."
    )
    return(result)
  }

  bl <- if (!is.null(block_length)) as.integer(block_length) else
    .nm_default_block_length(length(x),
      med_days = .nm_trend_median_days(y, tin$dates, tin$positional)
    )
  bl <- max(1L, min(bl, length(x) %/% 3))
  boots <- .nm_block_bootstrap_slopes(xtime, x, bl, as.integer(n_bootstrap), seed)
  finite_b <- is.finite(boots)
  if (sum(finite_b) < 10) {
    result$notes <- c(
      result$notes,
      sprintf(
        "only %d of %d bootstrap replicates were finite; no bootstrap interval reported.",
        sum(finite_b), n_bootstrap
      )
    )
    return(result)
  }

  b <- boots[finite_b]
  se <- stats::sd(b)
  q <- as.numeric(stats::quantile(b, probs = c(0.025, 0.975), type = 7))
  result$block_length <- bl
  result$n_bootstrap <- sum(finite_b)
  if (se > 0) {
    result$boot_slope_se <- se
    result$boot_ci_low <- q[1]
    result$boot_ci_high <- q[2]
    z_wald <- slope$slope / se
    result$p_wald_boot <- 2 * (1 - stats::pnorm(abs(z_wald)))
  }
  result$notes <- c(
    result$notes,
    sprintf(
      paste0(
        "AR(1) residual autocorrelation %.2f (p=%.2g) < %s: block bootstrap (length %d, ",
        "%d replicates) used for the slope interval. The Mann-Kendall p-value above is ",
        "the classical one and is anti-conservative under this autocorrelation; read ",
        "the bootstrap p_wald as the corrected test."
      ),
      result$ar1_acf, result$ar1_p, test_alpha, bl, sum(finite_b)
    )
  )
  result
}

# ---------------------------------------------------------------------------
# Summaries and one-line reports
# ---------------------------------------------------------------------------

#' @export
summary.nm_trend_result <- function(object, ...) {
  rows <- list(
    list("n", as.character(object$n)),
    list("n_missing_dropped", as.character(object$n_dropped)),
    list("MK_S", as.character(object$test$S)),
    list("MK_z", format(round(object$test$z, 3), trim = TRUE)),
    list("MK_p_two_sided", format(round(object$test$p, 5), trim = TRUE)),
    list("direction", .nm_trend_direction(object$test)),
    list(
      if (object$slope$time_unit == "day") "slope_per_day" else "slope_per_step",
      as.character(object$slope$slope)
    ),
    list(
      "slope_95ci",
      sprintf(
        "[%.4g, %.4g]%s",
        object$slope$ci_low, object$slope$ci_high,
        if (object$slope$time_unit == "day") " /day" else " /step"
      )
    ),
    list("ar1_residual_acf", format(round(object$ar1_acf, 3), trim = TRUE)),
    list("ar1_p", format(round(object$ar1_p, 5), trim = TRUE))
  )
  if (object$ar_autocorrelated) {
    rows <- c(rows, list(
      list("bootstrap_SE",
           if (is.null(object$boot_slope_se)) "NA" else format(round(object$boot_slope_se, 4), trim = TRUE)),
      list(
        "bootstrap_95ci",
        if (is.null(object$boot_ci_low)) "NA" else
          sprintf("[%.4g, %.4g]", object$boot_ci_low, object$boot_ci_high)
      ),
      list(
        "p_wald_block_bootstrap",
        if (is.null(object$p_wald_boot)) "NA" else format(round(object$p_wald_boot, 5), trim = TRUE)
      ),
      list("block_length", as.character(object$block_length)),
      list("n_bootstrap", as.character(object$n_bootstrap))
    ))
  }
  data.frame(metric = vapply(rows, `[[`, character(1), 1),
             value = vapply(rows, `[[`, character(1), 2),
             stringsAsFactors = FALSE)
}

#' @export
format.nm_trend_result <- function(x, ...) {
  s <- x$slope
  unit <- if (s$time_unit == "day") "u/m3/day" else "u/step"
  line <- paste0(
    x$name, ": n=", x$n,
    if (x$n_dropped) sprintf(" (dropped %d missing)", x$n_dropped) else "",
    sprintf(" | MK p=%.3g (%s)", x$test$p, .nm_trend_direction(x$test)),
    sprintf(" | slope %.4g %s", s$slope, unit),
    sprintf(" | 95%% CI [%.4g, %.4g]", s$ci_low, s$ci_high)
  )
  if (x$ar_autocorrelated) {
    if (!is.null(x$boot_slope_se) && !is.null(x$p_wald_boot)) {
      line <- paste0(
        line,
        sprintf(
          " | AR(1) acf=%.2f -> block bootstrap: SE=%.4g, p=%.3g",
          x$ar1_acf, x$boot_slope_se, x$p_wald_boot
        )
      )
    } else {
      line <- paste0(
        line,
        sprintf(" | AR(1) acf=%.2f -> block bootstrap unavailable (see notes)", x$ar1_acf)
      )
    }
  }
  line
}

#' @export
summary.nm_trend_breaks <- function(object, ...) {
  per_year <- object$time_unit == "day"
  df <- data.frame(
    start = vapply(object$starts, .nm_fmt_index, character(1)),
    end = vapply(object$ends, .nm_fmt_index, character(1)),
    n = vapply(object$segments, function(s) as.character(s$n), character(1)),
    slope = vapply(object$segments, function(s) as.character(s$slope), character(1)),
    ci_low = vapply(object$segments, function(s) as.character(s$ci_low), character(1)),
    ci_high = vapply(object$segments, function(s) as.character(s$ci_high), character(1)),
    stringsAsFactors = FALSE
  )
  if (per_year) {
    df$slope_per_year <- vapply(object$segments, function(s) as.character(s$slope_per_year), character(1))
    df$ci_low_per_year <- vapply(object$segments, function(s) as.character(s$ci_low_per_year), character(1))
    df$ci_high_per_year <- vapply(object$segments, function(s) as.character(s$ci_high_per_year), character(1))
  }
  df
}

#' @export
format.nm_trend_breaks <- function(x, ...) {
  unit <- if (x$time_unit == "day") "u/m3/day" else "u/step"
  line <- paste0(x$name, ": n=", x$n)
  if (x$n_dropped) line <- paste0(line, sprintf(" (dropped %d missing)", x$n_dropped))
  if (x$n_segments > 1) {
    line <- paste0(
      line,
      sprintf(" | %d segments | break at %s", x$n_segments, .nm_fmt_index(x$best_break)),
      sprintf(" | SSE -%.1f%%", x$improvement_pct)
    )
    for (i in seq_along(x$segments)) {
      line <- paste0(line, sprintf(" | seg%d slope %.3g %s", i, x$segments[[i]]$slope, unit))
    }
    line <- paste0(line, sprintf(" | p=%.3g", x$p_value))
    if (!x$significant) line <- paste0(line, " (no break; single regime reported)")
  } else {
    seg <- x$segments[[1]]
    line <- paste0(
      line,
      sprintf(" | 1 segment | slope %.3g %s", seg$slope, unit),
      sprintf(" | 95%% CI [%.3g, %.3g]", seg$ci_low, seg$ci_high)
    )
    if (!is.null(x$best_break)) {
      ptxt <- if (is.null(x$p_value)) "" else sprintf(", p=%.3g", x$p_value)
      line <- paste0(
        line,
        sprintf(
          " | best cut at %s (SSE %.1f%% lower%s) -- not reported as a break",
          .nm_fmt_index(x$best_break), x$best_split_pct, ptxt
        )
      )
    }
  }
  line
}

#' @export
print.nm_trend_result <- function(x, ...) {
  cat(format(x), "\n")
  if (length(x$notes)) cat(paste0("  - ", x$notes, collapse = "\n  - "), "\n")
  invisible(x)
}

#' @export
print.nm_trend_breaks <- function(x, ...) {
  cat(format(x), "\n")
  if (length(x$notes)) cat(paste0("  - ", x$notes, collapse = "\n  - "), "\n")
  invisible(x)
}
