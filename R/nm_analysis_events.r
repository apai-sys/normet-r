# Event and Anomaly Detection for Environmental Time Series
#
# Ported from Python normet analysis/events.py
# Provides three complementary anomaly detection methods:
# - "iqr": robust univariate threshold (median +/- k * IQR)
# - "isolation": IsolationForest on lagged features (requires solitude package)
# - "stl_residual": STL decomposition then IQR on residuals

NULL

#' Compute Anomaly Scores for a Time Series
#'
#' Compute per-timestamp anomaly scores using one of three methods.
#'
#' @param series Numeric vector or data frame with a \code{value} column.
#' @param value_col Character. Column name if \code{series} is a data frame.
#' @param method Character. One of \code{"iqr"}, \code{"isolation"}, or
#'        \code{"stl_residual"}.
#' @param stl_period Integer. Period for STL decomposition (e.g., 24 for hourly
#'        data with diurnal cycle). Only used when \code{method = "stl_residual"}.
#'        If NULL, defaults to 24.
#' @param seed Integer. Random seed for reproducible methods (currently used by
#'        \code{method = "isolation"}). Default \code{7654321}.
#'
#' @return A numeric vector of anomaly scores (same length as input).
#' @export
nm_anomaly_scores <- function(series, value_col = NULL, method = "iqr", stl_period = NULL, seed = 7654321) {
  if (is.data.frame(series)) {
    if (is.null(value_col) || !value_col %in% colnames(series)) {
      stop("`value_col` is required and must exist in the data frame.")
    }
    s <- as.numeric(series[[value_col]])
  } else {
    s <- as.numeric(series)
  }

  method <- match.arg(method, c("iqr", "isolation", "stl_residual"))

  if (method == "iqr") {
    med <- median(s, na.rm = TRUE)
    qs <- quantile(s, c(0.25, 0.75), na.rm = TRUE)
    iqr <- qs[2] - qs[1]
    if (is.na(iqr) || iqr <= 0) return(rep(0, length(s)))
    return(abs(s - med) / iqr)
  }

  if (method == "isolation") {
    if (!requireNamespace("solitude", quietly = TRUE)) {
      stop("Package 'solitude' is required for isolation method. Install with: install.packages('solitude')")
    }
    feats <- data.frame(x = s)
    for (lag in c(1, 2, 3, 6, 12)) {
      feats[[paste0("lag_", lag)]] <- c(rep(NA, lag), s[seq_len(length(s) - lag)])
    }
    for (j in seq_len(ncol(feats))) {
      feats[[j]] <- zoo::na.locf(feats[[j]], na.rm = FALSE)
      feats[[j]] <- zoo::na.locf(feats[[j]], fromLast = TRUE, na.rm = FALSE)
      feats[is.na(feats[[j]]), j] <- 0
    }
    iso <- solitude::isolationForest$new(seed = as.integer(seed))
    iso$fit(feats)
    scores <- iso$predict(feats)
    # Center on the standard isolation-forest cutoff (anomaly_score ~ 0.5 is
    # "normal"; > 0.5 is anomalous), so `nm_detect_events`'s threshold = 0
    # for this method flags points above that cutoff (larger = more anomalous).
    return(scores$anomaly_score - 0.5)
  }

  if (method == "stl_residual") {
    if (!requireNamespace("stats", quietly = TRUE)) stop("stats package required.")
    if (!requireNamespace("forecast", quietly = TRUE)) {
      stop("Package 'forecast' is required for STL method. Install with: install.packages('forecast')")
    }
    if (is.null(stl_period)) stl_period <- 24
    ts_obj <- stats::ts(s, frequency = stl_period)
    stl_fit <- tryCatch(
      stats::stl(ts_obj, s.window = "periodic", robust = TRUE),
      error = function(e) forecast::mstl(ts_obj)
    )
    resid <- as.numeric(stl_fit$time.series[, "remainder"])
    resid <- resid[is.finite(resid)]
    med <- median(resid, na.rm = TRUE)
    qs <- quantile(resid, c(0.25, 0.75), na.rm = TRUE)
    iqr <- max(qs[2] - qs[1], 1e-12)
    scores <- abs(resid - med) / iqr
    # Pad back to original length
    full_scores <- rep(NA, length(s))
    finite_idx <- which(is.finite(s))
    full_scores[finite_idx[seq_along(resid)]] <- scores
    full_scores
  }
}

#' Detect Consecutive Anomalous Intervals
#'
#' Identify consecutive time intervals where anomaly scores exceed a threshold.
#'
#' @param series Numeric vector or data frame. If a vector with
#'        \code{names()} that parse as dates (e.g. \code{as.character(Date)},
#'        as produced when subsetting a panel matrix column), or a data frame
#'        with a \code{date} column / date-like row names, \code{start}/\code{end}
#'        in the result will be \code{Date} values; otherwise they will be
#'        1-based integer positions.
#' @param value_col Character. Column name if \code{series} is a data frame.
#' @param method Character. Anomaly detection method.
#' @param k Numeric. IQR multiplier threshold (default 3.0). For isolation
#'        method, the threshold is always 0.
#' @param min_length Integer. Minimum number of consecutive flagged timestamps
#'        for an event. Default 1.
#' @param stl_period Integer. Period for STL decomposition.
#' @param seed Integer. Random seed forwarded to \code{\link{nm_anomaly_scores}}.
#'
#' @return A data frame with columns: \code{start}, \code{end}, \code{n},
#'         \code{max_score}, \code{mean_score}, sorted by \code{max_score}
#'         descending. \code{start}/\code{end} are \code{Date} values when
#'         date information can be recovered from \code{series} (see above),
#'         otherwise 1-based integer positions.
#' @export
nm_detect_events <- function(series, value_col = NULL, method = "iqr",
                             k = 3.0, min_length = 1, stl_period = NULL,
                             seed = 7654321) {
  scores <- nm_anomaly_scores(series, value_col = value_col, method = method,
    stl_period = stl_period, seed = seed)
  threshold <- if (method == "isolation") 0 else k
  mask <- scores > threshold & is.finite(scores)

  # Recover Date-like start/end values when possible, falling back to
  # 1-based integer positions (mirrors Python's DatetimeIndex-based output).
  timestamps <- NULL
  if (is.data.frame(series)) {
    if ("date" %in% colnames(series)) {
      timestamps <- series[["date"]]
      if (is.character(timestamps)) {
        conv <- try(as.Date(timestamps), silent = TRUE)
        if (inherits(conv, "Date")) timestamps <- conv
      }
    } else if (inherits(try(as.Date(rownames(series)), silent = TRUE), "Date")) {
      timestamps <- as.Date(rownames(series))
    }
  } else if (!is.null(names(series)) &&
             inherits(try(as.Date(names(series)), silent = TRUE), "Date")) {
    timestamps <- as.Date(names(series))
  }
  if (is.null(timestamps)) timestamps <- seq_along(scores)

  if (!any(mask)) {
    return(data.frame(start = timestamps[0], end = timestamps[0], n = integer(0),
      max_score = numeric(0), mean_score = numeric(0)))
  }

  # Find runs of TRUE
  rle_mask <- rle(mask)
  end_idx <- cumsum(rle_mask$lengths)
  start_idx <- c(1, end_idx[-length(end_idx)] + 1)

  rows <- list()
  for (i in which(rle_mask$values)) {
    n_pts <- rle_mask$lengths[i]
    if (n_pts < min_length) next
    seg_scores <- scores[start_idx[i]:end_idx[i]]
    rows[[length(rows) + 1]] <- data.frame(
      start = timestamps[start_idx[i]],
      end = timestamps[end_idx[i]],
      n = n_pts,
      max_score = max(seg_scores, na.rm = TRUE),
      mean_score = mean(seg_scores, na.rm = TRUE)
    )
  }
  if (length(rows) == 0) {
    return(data.frame(start = timestamps[0], end = timestamps[0], n = integer(0),
      max_score = numeric(0), mean_score = numeric(0)))
  }
  out <- do.call(rbind, rows)
  out[order(out$max_score, decreasing = TRUE), , drop = FALSE]
}

#' Event-Based Placebo Detection
#'
#' Automatically detect candidate cutoff dates from anomaly events.
#' Used internally by Bayesian SCM for automatic cutoff detection.
#'
#' @param series Numeric vector. If named (e.g. with \code{as.character(Date)}
#'        names, as produced when subsetting a panel matrix column), the
#'        names are used to recover \code{start} as a \code{Date} value;
#'        otherwise an integer position is returned.
#' @param method Character. Anomaly method (\code{"iqr"}).
#' @param k Numeric. IQR threshold.
#' @param seed Integer. Random seed forwarded to \code{\link{nm_detect_events}}.
#'
#' @return A Date (or POSIXct) value of the earliest detected event start if
#'         \code{series} carries date-like names, otherwise an integer
#'         position; or \code{NULL} if no event is detected.
#' @keywords internal
nm_detect_cutoff <- function(series, method = "iqr", k = 3.0, seed = 7654321) {
  events <- nm_detect_events(series, method = method, k = k, seed = seed)
  if (nrow(events) == 0) return(NULL)
  events$start[1]
}
