# Enhanced Model Evaluation Metrics
#
# Ported from Python normet utils/metrics.py enhancements.
# Extends nm_Stats and nm_modStats with:
# - by= grouping (season, month, hour, weekday, year, day_of_year)
# - custom predictor function

NULL

.TIME_GROUP_TOKENS <- c("season", "month", "hour", "weekday", "year", "day_of_year")

.season_from_month <- function(m) {
  if (m %in% c(12, 1, 2)) return("DJF")
  if (m %in% c(3, 4, 5)) return("MAM")
  if (m %in% c(6, 7, 8)) return("JJA")
  "SON"
}

.expand_time_token <- function(df, token) {
  if (!"date" %in% colnames(df)) stop("`by='", token, "' requires a 'date' column.")
  dt <- as.POSIXlt(df$date)
  switch(token,
    season = vapply(dt$mon + 1, .season_from_month, character(1)),
    month = dt$mon + 1,
    hour = dt$hour,
    weekday = (dt$wday + 6) %% 7,
    year = dt$year + 1900,
    day_of_year = dt$yday + 1,
    stop("Unknown time token '", token, "'.")
  )
}

#' Compute Statistics with Grouping
#'
#' Enhanced version of \code{nm_modStats} that supports grouping by
#' time-based tokens (season, month, hour, etc.) and custom predictor functions.
#'
#' @param df Data frame. Must contain target column \code{"value"}.
#' @param model Trained model object.
#' @param subset Character. Which split to evaluate (\code{"training"},
#'        \code{"testing"}, \code{"all"}). If NULL and "set" column exists,
#'        returns one row per split plus "all".
#' @param statistic Character vector. Metrics to compute.
#' @param predictor Function. Optional override for prediction.
#'        Signature: \code{function(model, df)} returning numeric vector.
#' @param by Character. Column name(s) or time token to group by.
#'        Special tokens: \code{"season"}, \code{"month"}, \code{"hour"},
#'        \code{"weekday"}, \code{"year"}, \code{"day_of_year"}.
#' @param include_all Logical. When \code{by} is given, also compute metrics
#'        across all rows (group label \code{"all"}).
#'
#' @return A data frame of metrics with a grouping column.
#' @export
nm_modStats_grouped <- function(df, model, subset = NULL, statistic = NULL,
                                predictor = NULL, by = NULL, include_all = TRUE) {
  if (is.null(predictor)) {
    predict_fn <- function(m, d) nm_predict(m, d, verbose = FALSE)
  } else {
    predict_fn <- predictor
  }

  compute_one <- function(df_in) {
    y_pred <- predict_fn(model, df_in)
    y_true <- df_in[["value"]]
    row <- .stats_from_arrays_internal(y_pred, y_true, statistic %||% .DEFAULT_STATS)
    row
  }

  # Legacy path: by set column
  if (is.null(by)) {
    return(nm_modStats(df, model, subset = subset, statistic = statistic))
  }

  # Grouped path
  keys <- if (length(by) > 1) as.list(by) else list(by)
  work <- as.data.frame(df)
  group_cols <- character(0)

  for (k in keys) {
    if (k %in% .TIME_GROUP_TOKENS) {
      work[[k]] <- .expand_time_token(work, k)
      group_cols <- c(group_cols, k)
    } else if (k %in% colnames(work)) {
      group_cols <- c(group_cols, k)
    } else {
      stop("`by` key '", k, "' is neither a column nor a known time token.")
    }
  }

  pieces <- list()
  if (length(group_cols) > 0) {
    groups <- interaction(work[, group_cols, drop = FALSE], drop = TRUE)
    for (g in levels(groups)) {
      idx <- which(groups == g)
      sub <- work[idx, , drop = FALSE]
      row <- compute_one(sub)
      vals <- strsplit(g, "\\.")[[1]]
      for (j in seq_along(group_cols)) {
        row[[group_cols[j]]] <- vals[j]
      }
      pieces[[length(pieces) + 1]] <- row
    }
  }

  if (include_all) {
    row_all <- compute_one(work)
    for (col_name in group_cols) {
      row_all[[col_name]] <- "all"
    }
    pieces[[length(pieces) + 1]] <- row_all
  }

  if (length(pieces) == 0) return(data.frame())
  out <- do.call(rbind, pieces)
  out[, c(group_cols, setdiff(colnames(out), group_cols)), drop = FALSE]
}

.stats_from_arrays_internal <- function(y_pred, y_true, statistic) {
  mask <- is.finite(y_pred) & is.finite(y_true)
  yhat <- as.numeric(y_pred)[mask]
  yobs <- as.numeric(y_true)[mask]
  n <- length(yhat)

  if (n == 0) {
    keys <- statistic
    if ("r" %in% statistic) keys <- unique(c(keys, "p_level"))
    out <- as.list(rep(NA_real_, length(keys)))
    names(out) <- keys
    if ("n" %in% statistic) out$n <- 0L
    if ("p_level" %in% names(out) && is.na(out$p_level)) out$p_level <- NA_character_
    return(as.data.frame(out))
  }

  diff <- yhat - yobs
  adiff <- abs(diff)
  res <- list()

  if ("n" %in% statistic) res$n <- as.integer(n)
  if ("FAC2" %in% statistic) res$FAC2 <- .fac2_int(yhat, yobs)
  if ("MB" %in% statistic) res$MB <- mean(diff)
  if ("MGE" %in% statistic) res$MGE <- mean(adiff)
  if ("RMSE" %in% statistic) res$RMSE <- sqrt(mean(diff^2))

  sum_obs <- sum(yobs)
  if ("NMB" %in% statistic) res$NMB <- if (sum_obs != 0) sum(diff) / sum_obs else NA_real_
  if ("NMGE" %in% statistic) res$NMGE <- if (sum_obs != 0) sum(adiff) / sum_obs else NA_real_

  denom_abs_obs <- sum(abs(yobs - mean(yobs)))
  if ("COE" %in% statistic) {
    res$COE <- if (denom_abs_obs != 0) 1.0 - (sum(adiff) / denom_abs_obs) else NA_real_
  }
  if ("IOA" %in% statistic) {
    lhs <- sum(adiff)
    rhs <- 2.0 * denom_abs_obs
    res$IOA <- if (rhs == 0 && lhs == 0) 1.0 else if (rhs == 0) NA_real_ else if (lhs <= rhs) 1.0 - lhs / rhs else rhs / lhs - 1.0
  }

  r_val <- NA_real_
  p_val <- NA_real_
  if ("r" %in% statistic || "R2" %in% statistic) {
    if (n > 1 && sd(yhat) > 0 && sd(yobs) > 0) {
      test <- tryCatch(stats::cor.test(yhat, yobs, method = "pearson"), error = function(e) NULL)
      if (!is.null(test)) {
        r_val <- test$estimate
        p_val <- test$p.value
      }
    }
  }

  if ("r" %in% statistic) {
    res$r <- r_val
    res$p_level <- if (!is.finite(p_val) || is.na(p_val)) "" else if (p_val >= 0.1) "" else if (p_val >= 0.05) "+" else if (p_val >= 0.01) "*" else if (p_val >= 0.001) "**" else "***"
  }
  if ("R2" %in% statistic) res$R2 <- if (is.finite(r_val)) r_val^2 else NA_real_

  keys_needed <- statistic
  if ("r" %in% statistic) keys_needed <- union(keys_needed, "p_level")
  for (k in keys_needed) {
    if (is.null(res[[k]])) res[[k]] <- NA_real_
  }
  if ("p_level" %in% names(res) && (is.na(res$p_level) || is.null(res$p_level))) res$p_level <- NA_character_

  as.data.frame(res)
}

.fac2_int <- function(y_pred, y_true) {
  epsilon <- 1e-9
  ratio <- y_pred / (y_true + epsilon)
  mask <- is.finite(ratio)
  if (!any(mask)) return(NA_real_)
  mean((ratio[mask] >= 0.5) & (ratio[mask] <= 2.0))
}
