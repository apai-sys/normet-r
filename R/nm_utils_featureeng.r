# Feature Engineering Utilities
#
# Ported from Python normet utils/featureeng.py
# Provides cyclical encoding, wind-to-uv decomposition,
# lag features, and rolling-window statistics.

NULL

#' Cyclically Encode a Periodic Variable
#'
#' Replace a periodic feature (e.g., hour of day, day of year, wind direction)
#' with its sine/cosine encoding to preserve circular continuity.
#'
#' @param df A data frame.
#' @param col Character. Column name to encode. Must be numeric in \eqn{[0, period)}.
#' @param period Numeric. Cycle length (e.g., 24 for hour, 365.25 for day of year).
#' @param drop Logical. If TRUE, drop the original column.
#' @param prefix Character. Optional prefix for new columns (defaults to \code{col}).
#'        New columns are named \code{{prefix}_sin} and \code{{prefix}_cos}.
#'
#' @return A data frame with sine/cosine columns appended.
#' @export
nm_cyclical_encode <- function(df, col, period, drop = FALSE, prefix = NULL) {
  if (!col %in% colnames(df)) stop("Column '", col, "' not found in df.")
  if (period <= 0) stop("`period` must be positive.")

  out <- as.data.frame(df)
  base <- prefix %||% col
  theta <- 2 * pi * as.numeric(out[[col]]) / period
  out[[paste0(base, "_sin")]] <- sin(theta)
  out[[paste0(base, "_cos")]] <- cos(theta)
  if (drop) out[[col]] <- NULL
  out
}

#' Decompose Wind Speed and Direction into u/v Components
#'
#' Convert wind speed and meteorological wind direction into
#' zonal (u, east-west) and meridional (v, north-south) components.
#'
#' @param speed Numeric vector. Wind speed (any unit).
#' @param direction_deg Numeric vector. Wind direction in degrees.
#' @param convention Character. \code{"meteorological"} (direction wind is *from*,
#'        clockwise from North) or \code{"oceanographic"} (direction wind is *toward*).
#'
#' @return A data frame with columns \code{u} (zonal) and \code{v} (meridional).
#' @export
nm_wind_to_uv <- function(speed, direction_deg, convention = "meteorological") {
  s <- as.numeric(speed)
  d <- as.numeric(direction_deg)
  if (length(s) != length(d)) stop("`speed` and `direction_deg` must have the same length.")

  rad <- d * pi / 180
  if (convention == "meteorological") {
    u <- -s * sin(rad)
    v <- -s * cos(rad)
  } else if (convention == "oceanographic") {
    u <- s * sin(rad)
    v <- s * cos(rad)
  } else {
    stop("`convention` must be 'meteorological' or 'oceanographic'.")
  }
  data.frame(u = u, v = v)
}

#' Add Lag Features
#'
#' Create lagged copies of specified columns.
#'
#' @param df A data frame with a datetime \code{date} column.
#' @param cols Character vector. Column names to lag.
#' @param lags Integer vector. Positive lag values (e.g., 1, 2, 3).
#' @param group_col Character. Optional column name for within-group lags.
#' @param date_col Character. Date column name. Default \code{"date"}.
#' @param suffix Character. Suffix for new column names. Default \code{"_lag"}.
#'
#' @return A data frame with lag columns appended.
#' @export
nm_add_lag_features <- function(df, cols, lags, group_col = NULL,
                                date_col = "date", suffix = "_lag") {
  if (length(cols) == 0 || length(lags) == 0) return(as.data.frame(df))
  if (any(lags <= 0)) stop("`lags` must contain positive integers.")

  out <- df[order(df[[date_col]]), , drop = FALSE]
  for (c in cols) {
    for (k in lags) {
      name <- paste0(c, suffix, k)
      if (!is.null(group_col)) {
        out[[name]] <- unlist(stats::ave(seq_len(nrow(out)), out[[group_col]],
          FUN = function(idx) {
            x <- out[[c]][idx]
            c(rep(NA, k), x[seq_len(length(x) - k)])
          }))
      } else {
        out[[name]] <- c(rep(NA, k), out[[c]][seq_len(nrow(out) - k)])
      }
    }
  }
  out
}

#' Add Rolling Window Statistics
#'
#' Compute rolling window statistics (mean, sd, min, max, median, sum) for
#' specified columns.
#'
#' @param df A data frame with a datetime \code{date} column.
#' @param cols Character vector. Columns to compute rolling stats for.
#' @param windows Integer vector. Window sizes in rows.
#' @param aggs Character vector. Aggregation functions.
#'        One or more of \code{"mean"}, \code{"sd"}, \code{"min"}, \code{"max"},
#'        \code{"median"}, \code{"sum"}.
#' @param min_periods Integer. Minimum periods for rolling window (defaults to window size).
#' @param group_col Character. Optional column name for within-group rolling stats.
#' @param date_col Character. Date column name.
#' @param suffix Character. Suffix for new columns. Default \code{"_roll"}.
#' @param causal Logical. If TRUE (default), use trailing windows (no look-ahead).
#'        If FALSE, use centered windows.
#'
#' @return A data frame with rolling statistic columns appended.
#' @export
nm_add_rolling_features <- function(df, cols, windows, aggs = "mean",
                                    min_periods = NULL, group_col = NULL,
                                    date_col = "date", suffix = "_roll",
                                    causal = TRUE) {
  allowed <- c("mean", "sd", "min", "max", "median", "sum")
  bad_aggs <- setdiff(aggs, allowed)
  if (length(bad_aggs) > 0) stop("Unsupported aggs: ", paste(bad_aggs, collapse = ", "))
  if (any(windows <= 0)) stop("`windows` must contain positive integers.")

  out <- df[order(df[[date_col]]), , drop = FALSE]

  for (c in cols) {
    for (w in windows) {
      mp <- if (is.null(min_periods)) w else min_periods
      for (agg in aggs) {
        name <- paste0(c, suffix, w, "_", agg)
        vals <- rep(NA_real_, nrow(out))

        if (!is.null(group_col)) {
          for (grp in unique(out[[group_col]])) {
            idx <- which(out[[group_col]] == grp)
            if (length(idx) == 0) next
            x <- out[[c]][idx]
            rolled <- .roll_apply(x, w, mp, agg, causal)
            vals[idx] <- rolled
          }
        } else {
          vals <- .roll_apply(out[[c]], w, mp, agg, causal)
        }
        out[[name]] <- vals
      }
    }
  }
  out
}

.roll_apply <- function(x, window, min_periods, agg, causal) {
  n <- length(x)
  out <- rep(NA_real_, n)
  for (i in seq_len(n)) {
    if (causal) {
      idx_start <- max(1, i - window + 1)
      idx_end <- i
    } else {
      half <- floor(window / 2)
      idx_start <- max(1, i - half)
      idx_end <- min(n, i + (window - half - 1))
    }
    if ((idx_end - idx_start + 1) < min_periods) next
    chunk <- x[idx_start:idx_end]
    chunk <- chunk[is.finite(chunk)]
    if (length(chunk) < min_periods) next
    out[i] <- switch(agg,
      mean = mean(chunk),
      sd = sd(chunk),
      min = min(chunk),
      max = max(chunk),
      median = median(chunk),
      sum = sum(chunk),
      NA_real_
    )
  }
  out
}


# ---------------------------------------------------------------------------
# Lag-structure diagnostics (ACF / PACF / pre-whitened CCF)
# ---------------------------------------------------------------------------

# Shift a vector by `k` rows. Positive k looks back (k=1 -> previous row),
# matching nm_add_lag_features; negative k looks ahead. Out-of-range -> all NA.
.nm_lag_shift <- function(x, k) {
  n <- length(x)
  if (k == 0) return(x)
  if (abs(k) >= n) return(rep(NA_real_, n))
  if (k > 0) return(c(rep(NA_real_, k), x[seq_len(n - k)]))
  k <- -k
  c(x[(k + 1):n], rep(NA_real_, k))
}

# Pearson cross-correlation at each lag; lag k>0 => cor(shift(driver, k),
# target), i.e. the driver leads the target by k rows.
.nm_ccf_at_lags <- function(driver, target, lags) {
  vapply(lags, function(k) {
    d <- .nm_lag_shift(driver, k)
    ok <- is.finite(d) & is.finite(target)
    if (sum(ok) < 3L) NA_real_ else stats::cor(d[ok], target[ok])
  }, numeric(1))
}

# Box-Jenkins pre-whitening: fit an AR(p) to the driver (AIC up to max_ar), take
# its innovations as the white driver, and filter the centred target with the
# same AR polynomial. Returns aligned, full-length vectors plus the order p.
.nm_prewhiten <- function(driver, target, max_ar) {
  fit <- stats::ar(
    stats::na.omit(driver),
    order.max = max(1L, as.integer(max_ar)), aic = TRUE
  )
  phi <- as.numeric(fit$ar)
  dc <- driver - mean(driver, na.rm = TRUE)
  yc <- target - mean(target, na.rm = TRUE)
  if (fit$order < 1L || length(phi) == 0L) {
    return(list(driver = dc, target = yc, p = 0L))
  }
  filt <- c(1, -phi)
  dw <- stats::filter(dc, filt, method = "convolution", sides = 1)
  yf <- stats::filter(yc, filt, method = "convolution", sides = 1)
  list(
    driver = as.numeric(dw), target = as.numeric(yf),
    p = as.integer(fit$order)
  )
}

#' Diagnose Lag Structure (ACF / PACF / Pre-whitened CCF)
#'
#' Compute a target's autocorrelation (ACF) and partial autocorrelation (PACF)
#' to suggest autoregressive lags, and -- when a \code{driver} is given -- the
#' cross-correlation (CCF) between driver and target to suggest predictive
#' driver lags. By default the CCF uses \emph{pre-whitened} series so that
#' shared seasonality / autocorrelation does not produce spurious peaks
#' (Box-Jenkins pre-whitening).
#'
#' The series is sorted by \code{date_col} and assumed to be regularly spaced;
#' non-finite values are dropped pairwise. For multi-site panels, call this once
#' per site (pass a single-site slice).
#'
#' @param df A data frame with a datetime column.
#' @param target Character. Response column (e.g. the pollutant).
#' @param driver Character. Optional driver column (e.g. a meteorological
#'        variable). If \code{NULL}, only ACF/PACF of the target are returned.
#' @param max_lag Integer. Maximum lag (rows) for ACF/PACF and the CCF range.
#'        Default 48.
#' @param date_col Character. Datetime column to sort by. Default \code{"date"}.
#' @param prewhiten Logical. Pre-whiten before the CCF (recommended for
#'        autocorrelated, seasonal series). Ignored when \code{driver} is
#'        \code{NULL}. Default \code{TRUE}.
#' @param max_ar Integer. Maximum AR order for the pre-whitening filter
#'        (AIC-selected). Default 24.
#' @param alpha Numeric. Two-sided significance level for the white-noise bands.
#'        Default 0.05.
#'
#' @return An object of class \code{"nm_lag_diagnostics"}: a list with
#'   \code{acf}/\code{pacf} (and \code{ccf} when a driver is given) data frames
#'   of \code{lag}/\code{value}, the suggested \code{target_ar_lags} and
#'   \code{driver_lags}, the \code{peak_lag}, the significance \code{band}, and
#'   bookkeeping fields. A \code{ccf} lag \code{k > 0} means the driver leads
#'   the target by \code{k} rows, matching \code{nm_add_lag_features(lags = k)}.
#' @export
nm_analyze_lag <- function(df, target, driver = NULL, max_lag = 48L,
                           date_col = "date", prewhiten = TRUE,
                           max_ar = 24L, alpha = 0.05) {
  if (max_lag < 1L) stop("`max_lag` must be >= 1.")
  if (!target %in% colnames(df)) stop("Column '", target, "' not found in df.")

  out <- df[order(df[[date_col]]), , drop = FALSE]
  y <- as.numeric(out[[target]])
  z <- stats::qnorm(1 - alpha / 2)

  n_target <- sum(is.finite(y))
  nlags <- min(as.integer(max_lag), max(1L, n_target - 2L))

  na_pass <- stats::na.pass
  a <- stats::acf(y, lag.max = nlags, plot = FALSE, na.action = na_pass)
  pa <- stats::pacf(y, lag.max = nlags, plot = FALSE, na.action = na_pass)
  acf_df <- data.frame(
    lag = as.integer(a$lag[, , 1]), value = as.numeric(a$acf[, , 1])
  )
  pacf_df <- data.frame(
    lag = as.integer(pa$lag[, , 1]), value = as.numeric(pa$acf[, , 1])
  )

  band <- z / sqrt(max(n_target, 1L))
  ar_sig <- pacf_df$lag >= 1L & is.finite(pacf_df$value) &
    abs(pacf_df$value) > band
  target_ar_lags <- pacf_df$lag[ar_sig]

  result <- list(
    target = target, driver = NULL, n = n_target, alpha = alpha, band = band,
    acf = acf_df, pacf = pacf_df, ccf = NULL,
    target_ar_lags = as.integer(target_ar_lags),
    driver_lags = integer(0), peak_lag = NA_integer_, prewhitened = FALSE
  )

  if (is.null(driver)) {
    return(structure(result, class = "nm_lag_diagnostics"))
  }
  if (!driver %in% colnames(df)) stop("Column '", driver, "' not found in df.")

  x <- as.numeric(out[[driver]])
  prewhitened <- isTRUE(prewhiten)
  if (prewhitened) {
    pw <- tryCatch(.nm_prewhiten(x, y, max_ar), error = function(e) NULL)
    if (is.null(pw)) {
      warning("Pre-whitening failed; falling back to raw CCF.")
      prewhitened <- FALSE
      x_use <- x
      y_use <- y
    } else {
      x_use <- pw$driver
      y_use <- pw$target
    }
  } else {
    x_use <- x
    y_use <- y
  }

  lags <- seq.int(-as.integer(max_lag), as.integer(max_lag))
  ccf_vals <- .nm_ccf_at_lags(x_use, y_use, lags)
  ccf_df <- data.frame(lag = lags, value = ccf_vals)

  n_ccf <- sum(is.finite(x_use) & is.finite(y_use))
  band_ccf <- z / sqrt(max(n_ccf, 1L))

  lead <- ccf_df[ccf_df$lag >= 0L & is.finite(ccf_df$value), , drop = FALSE]
  driver_lags <- lead$lag[abs(lead$value) > band_ccf]
  peak_lag <- if (nrow(lead) > 0L) {
    lead$lag[which.max(abs(lead$value))]
  } else {
    NA_integer_
  }

  result$driver <- driver
  result$n <- n_ccf
  result$band <- band_ccf
  result$ccf <- ccf_df
  result$driver_lags <- as.integer(driver_lags)
  result$peak_lag <- as.integer(peak_lag)
  result$prewhitened <- prewhitened
  structure(result, class = "nm_lag_diagnostics")
}

#' @export
print.nm_lag_diagnostics <- function(x, ...) {
  hdr <- sprintf("<nm_lag_diagnostics> target='%s'", x$target)
  if (!is.null(x$driver)) {
    hdr <- paste0(hdr, sprintf(", driver='%s'", x$driver))
  }
  cat(hdr, "\n", sep = "")
  info <- sprintf("  n=%d | band=+/-%.3f (alpha=%s)", x$n, x$band, x$alpha)
  cat(info, "\n", sep = "")
  ar_str <- if (length(x$target_ar_lags)) {
    paste(x$target_ar_lags, collapse = ", ")
  } else {
    "-"
  }
  cat(sprintf("  target AR lags (PACF): %s\n", ar_str))
  if (!is.null(x$driver)) {
    tag <- if (isTRUE(x$prewhitened)) "pre-whitened" else "raw"
    dl_str <- if (length(x$driver_lags)) {
      paste(x$driver_lags, collapse = ", ")
    } else {
      "-"
    }
    cat(sprintf("  driver lags (CCF, %s): %s\n", tag, dl_str))
    cat(sprintf("  peak driver-leading lag: %s\n", x$peak_lag))
  }
  invisible(x)
}

#' @export
plot.nm_lag_diagnostics <- function(x, ...) {
  npanels <- if (!is.null(x$ccf)) 3L else 2L
  op <- graphics::par(mfrow = c(npanels, 1), mar = c(4, 4, 2, 1))
  on.exit(graphics::par(op), add = TRUE)

  stem <- function(frame, title, xlab) {
    plot(frame$lag, frame$value,
      type = "h", main = title, xlab = xlab, ylab = "corr"
    )
    graphics::abline(h = 0, col = "grey50")
    graphics::abline(h = c(-x$band, x$band), col = "red", lty = 2)
  }
  stem(x$acf, paste0("ACF - ", x$target), "lag")
  stem(x$pacf, paste0("PACF - ", x$target), "lag")
  if (!is.null(x$ccf)) {
    tag <- if (isTRUE(x$prewhitened)) "pre-whitened" else "raw"
    stem(
      x$ccf,
      paste0("CCF (", tag, ") - ", x$driver, " -> ", x$target),
      "lag (driver leads target ->)"
    )
  }
  invisible(x)
}
