# Diagnostic Summaries for Synthetic-Control Fits
#
# Ported from Python normet causal/diagnostics.py
# Provides:
#   nm_scm_diagnostics        - pre/post fit quality + weight concentration
#   nm_loo_weight_stability   - leave-one-donor-out weight sensitivity

NULL

#' SCM Diagnostics
#'
#' Summarise the quality of a synthetic-control fit: pre-period fit metrics,
#' post-period effect summary, donor weight concentration, the pre-period
#' parallel-trend check, and -- when the panel carries coordinates -- the
#' donor pool's spatial layout.
#'
#' @param scm_result List or data.frame. Output of \code{nm_scm},
#'        \code{nm_scm_abadie}, \code{nm_did_baseline}, or similar.
#'        Must contain a \code{synthetic} data.frame with columns
#'        \code{observed}, \code{synthetic}, \code{effect}, and optionally
#'        \code{weights}.
#' @param cutoff_date Character or Date. Treatment cutoff.
#' @param top_k Integer. How many top donors to report. Default 5.
#' @param panel Optional data.frame, the long-format donor panel. With
#'        \code{treated_unit}, and carrying \code{lat_col}/\code{lon_col}, a
#'        \code{spatial} section is appended: each donor's distance and
#'        compass sector from the treated unit, the pool's centroid offset,
#'        and its sector coverage -- a reading of where the counterfactual is
#'        borrowed from, which the weights alone do not say (see
#'        \code{\link{nm_donor_spatial_summary}}).
#' @param donors Optional character vector, the donor units to place. Defaults
#'        to the fit's weights' names; without weights and without this the
#'        section is skipped.
#' @param treated_unit Optional character, the treated unit the bearings are
#'        taken from; required for the \code{spatial} section.
#' @param unit_col,lat_col,lon_col Column names in \code{panel} for the unit
#'        id, latitude and longitude.
#' @param n_sectors Integer. Compass sectors the bearings are divided into
#'        (8 = N/NE/E/...). Default 8.
#'
#' @return A list with pre-period fit (\code{pre_n}, \code{pre_rmse},
#'         \code{pre_mae}, \code{pre_mape}, \code{pre_r2}), post-period
#'         effect (\code{post_n}, \code{att}, \code{att_cum},
#'         \code{post_rmse}), weight concentration (\code{hhi},
#'         \code{effective_n_donors}, \code{n_donors}, \code{top_donors},
#'         \code{top_donor_share}) and \code{pre_trend}, the
#'         \code{nm_pre_trend} result of \code{\link{nm_pre_trend_test}}:
#'         whether the pre-period was parallel. When the panel supports it, a
#'         \code{spatial} element too: a \code{donors} table plus
#'         \code{centroid_offset_km}, \code{centroid_bearing_deg},
#'         \code{sector_coverage}, \code{sector_fraction},
#'         \code{n_donors_placed}, \code{n_donors_missing}.
#' @export
nm_scm_diagnostics <- function(scm_result, cutoff_date, top_k = 5,
                               panel = NULL, donors = NULL, treated_unit = NULL,
                               unit_col = "unit", lat_col = "lat", lon_col = "lon",
                               n_sectors = 8L) {
  if (is.data.frame(scm_result)) {
    synth <- scm_result
    weights <- NULL
  } else if (is.list(scm_result) && "synthetic" %in% names(scm_result)) {
    synth <- scm_result[["synthetic"]]
    weights <- scm_result[["weights"]]
  } else {
    stop("`scm_result` must be a data.frame or a list with 'synthetic' key.")
  }
  if (!"effect" %in% colnames(synth)) {
    stop("'synthetic' must have 'effect' column.")
  }

  cutoff_ts <- as.Date(cutoff_date)
  pre <- synth[synth$date < cutoff_ts, , drop = FALSE]
  post <- synth[synth$date >= cutoff_ts, , drop = FALSE]

  pre_n <- nrow(pre)
  post_n <- nrow(post)

  # Pre-period fit
  pre_rmse <- NA_real_
  pre_mae <- NA_real_
  pre_mape <- NA_real_
  pre_r2 <- NA_real_
  if (pre_n > 0) {
    obs_p <- as.numeric(pre$observed)
    syn_p <- as.numeric(pre$synthetic)
    mask <- is.finite(obs_p) & is.finite(syn_p)
    obs_p <- obs_p[mask]
    syn_p <- syn_p[mask]
    if (length(obs_p) > 0) {
      err <- obs_p - syn_p
      pre_rmse <- sqrt(mean(err^2))
      pre_mae <- mean(abs(err))
      denom <- abs(obs_p)
      mape_vals <- ifelse(denom > 1e-12, abs(err) / denom, NA)
      pre_mape <- mean(mape_vals, na.rm = TRUE)
      ss_tot <- sum((obs_p - mean(obs_p))^2)
      ss_res <- sum(err^2)
      pre_r2 <- if (ss_tot > 0) 1 - ss_res / ss_tot else NA_real_
    }
  }

  # Post-period effect
  att <- NA_real_
  att_cum <- NA_real_
  post_rmse <- NA_real_
  if (post_n > 0) {
    eff_post <- as.numeric(post$effect)
    eff_post <- eff_post[is.finite(eff_post)]
    post_n <- length(eff_post)
    if (post_n > 0) {
      att <- mean(eff_post)
      att_cum <- sum(eff_post)
      post_rmse <- sqrt(mean(eff_post^2))
    }
  }

  # Weight concentration
  hhi <- NA_real_
  eff_n <- NA_real_
  top_donors <- numeric(0)
  top_share <- NA_real_
  n_donors <- 0
  if (!is.null(weights) && length(weights) > 0) {
    w <- as.numeric(weights)
    w[!is.finite(w)] <- 0
    s <- sum(w)
    if (abs(s) > 1e-12) w <- w / s
    hhi <- sum(w^2)
    eff_n <- if (hhi > 0) 1 / hhi else NA_real_
    n_donors <- length(w)
    ord <- order(abs(w), decreasing = TRUE)
    top_idx <- ord[seq_len(min(top_k, length(w)))]
    top_vals <- abs(w[top_idx])
    top_donors <- setNames(top_vals, names(weights)[top_idx])
    top_share <- sum(top_vals)
  }

  # Whether the pre-period was parallel, on the same window (normet-py #61).
  pre_trend <- nm_pre_trend_test(synth, cutoff_date)

  out <- list(
    pre_n = pre_n, pre_rmse = pre_rmse, pre_mae = pre_mae,
    pre_mape = pre_mape, pre_r2 = pre_r2,
    post_n = post_n, att = att, att_cum = att_cum, post_rmse = post_rmse,
    hhi = hhi, effective_n_donors = eff_n, n_donors = n_donors,
    top_donors = top_donors, top_donor_share = top_share,
    pre_trend = pre_trend
  )

  # Spatial section (normet-py #65): only when the panel carries the
  # coordinates it is about. Absent panel, absent columns, or an unnamed
  # treated unit, the summary is exactly what it was before -- the section
  # is a reading, not a requirement.
  if (is.data.frame(panel) && !is.null(treated_unit) &&
      lat_col %in% colnames(panel) && lon_col %in% colnames(panel)) {
    donor_names <- if (!is.null(donors)) donors else (names(weights) %||% character(0))
    if (length(donor_names) > 0) {
      table <- nm_donor_spatial_summary(
        panel, donor_names, treated_unit,
        unit_col = unit_col, lat_col = lat_col, lon_col = lon_col,
        n_sectors = n_sectors, weights = weights
      )
      s <- nm_spatial_summary(table, n_donors = length(donor_names), n_sectors = n_sectors)
      out$spatial <- c(list(donors = table), s)
    }
  }
  out
}

#' Leave-One-Donor-Out Weight Stability
#'
#' Refits SCM with each donor held out in turn, reporting the drift of
#' remaining weights from the full-pool baseline.
#'
#' @inheritParams nm_scm
#' @param ... Additional arguments passed to \code{nm_scm}.
#'
#' @return A data.frame with columns \code{dropped_donor},
#'         \code{mean_abs_drift}, \code{max_abs_drift}, \code{effect_shift}.
#' @export
nm_loo_weight_stability <- function(df, date_col = "date", unit_col = "code",
                                    outcome_col = "poll", treated_unit = NULL,
                                    cutoff_date = NULL, donors = NULL, ...) {
  base <- nm_scm(df = df, date_col = date_col, unit_col = unit_col,
    outcome_col = outcome_col, treated_unit = treated_unit,
    cutoff_date = cutoff_date, donors = donors, ...)
  w_base <- base$weights
  cutoff_ts <- as.Date(cutoff_date)
  att_base <- mean(base$synthetic$effect[base$synthetic$date >= cutoff_ts], na.rm = TRUE)

  rows <- list()
  for (d in donors) {
    sub_donors <- setdiff(donors, d)
    if (length(sub_donors) < 2) next
    tryCatch(
      {
        r <- nm_scm(df = df, date_col = date_col, unit_col = unit_col,
          outcome_col = outcome_col, treated_unit = treated_unit,
          cutoff_date = cutoff_date, donors = sub_donors, ...)
        w_sub <- r$weights[sub_donors]
        drift <- abs(w_sub - w_base[sub_donors])
        att <- mean(r$synthetic$effect[r$synthetic$date >= cutoff_ts], na.rm = TRUE)
        rows[[length(rows) + 1]] <- data.frame(
          dropped_donor = d,
          mean_abs_drift = mean(drift, na.rm = TRUE),
          max_abs_drift = max(drift, na.rm = TRUE),
          effect_shift = att - att_base
        )
      },
      error = function(e) NULL)
  }
  if (length(rows) == 0) return(data.frame())
  do.call(rbind, rows)
}
