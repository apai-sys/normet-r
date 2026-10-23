# Pre-Trend Diagnostics for Synthetic Control Fits
#
# Ported from Python normet causal/prediagnostics.py
# Provides:
#   nm_pre_trend_test - whether the pre-period was parallel (OLS slope + RMSPE drift)

NULL

# A number in the verdict's format: `digits` significant digits, "nan" and
# "inf" where R would print NA and Inf (the verdict strings mirror normet-py's).
.nm_pt_g <- function(x, digits) {
  if (length(x) != 1L || is.na(x)) return("nan")
  s <- sprintf(paste0("%.", digits, "g"), x)
  if (is.infinite(x)) s <- tolower(s)
  s
}

# An all-NaN result with the `insufficient` verdict, for a pre-period too
# short to support a slope test.
.nm_pre_trend_insufficient <- function(n, min_periods) {
  structure(list(
    slope = NA_real_,
    p_slope = NA_real_,
    rmpe_drift = NA_real_,
    n_periods = as.integer(n),
    verdict = sprintf(
      "insufficient: %d pre-period point%s, %d are needed for a trend test",
      as.integer(n), if (n != 1) "s" else "", as.integer(min_periods)
    )
  ), class = "nm_pre_trend")
}

# RMSPE of the final third of e divided by that of the first two thirds.
.nm_pt_drift <- function(e) {
  n <- length(e)
  third <- n %/% 3
  if (third < 1L) return(NA_real_)
  early <- sqrt(mean(e[seq_len(n - third)]^2))
  late <- sqrt(mean(e[(n - third + 1):n]^2))
  if (early <= 0) return(if (late > 0) Inf else NA_real_)
  late / early
}

#' Pre-Trend Test for a Synthetic-Control Fit
#'
#' The first question a reviewer asks of an SCM is whether the pre-period was
#' parallel: the identification argument rests on the synthetic unit tracking
#' the treated unit *before* the intervention, so a pre-period residual that
#' drifts away from zero is a parallel-trends violation wearing a good
#' pre-RMSE costume. `nm_scm_diagnostics()` reports how close the fit is on
#' average in the pre-period, but not whether the fit is *getting* closer or
#' further as the intervention approaches, which is what a violation about to
#' happen looks like.
#'
#' This test answers it with two complementary numbers on the pre-period
#' residuals `e_t = observed_t - synthetic_t`: the OLS slope of `e_t` against
#' the period index with its classical two-sided t-test, and `rmpe_drift`, the
#' RMSPE of the final third of the pre-period divided by that of the first two
#' thirds (the raw-residual quantity Abadie's post/pre RMSPE ratio is built
#' from). One means a stable fit; above one the residuals grow toward the
#' cutoff. The two catch different failure modes: a slow linear drift has a
#' significant slope but a mild drift ratio (the fit absorbs much of a
#' monotone ramp's level), while a late breakdown has a drift ratio that says
#' so while the slope stays quiet.
#'
#' The t-test is the classical OLS one (it assumes the residuals are
#' independent); pre-period SCM residuals at daily-or-slower frequency are
#' usually close enough to that, and a violation that is *systematic* - which
#' is what the test hunts for - shows up in the drift ratio as well, which
#' makes no independence assumption at all.
#'
#' @param scm_result List or data.frame. Output of \code{nm_scm} or any other
#'        fit in \code{\link{nm_scm_diagnostics}}'s family - anything with a
#'        \code{synthetic} data.frame carrying \code{observed} and
#'        \code{synthetic} columns (or that data.frame directly).
#' @param cutoff_date Character or Date. Treatment cutoff; periods at or
#'        after it are excluded.
#' @param alpha Numeric. Significance level for the slope test in the
#'        verdict. Default 0.05.
#' @param min_periods Integer. Fewer finite pre-period points than this
#'        cannot support the test; the result is then all-missing with an
#'        \code{insufficient} verdict rather than a p-value computed from two
#'        degrees of freedom. Default 5.
#'
#' @return A list of class \code{nm_pre_trend} with \code{slope} (the OLS
#'         slope of the pre-period residuals, in outcome units per period),
#'         \code{p_slope} (its two-sided t-test p-value), \code{rmpe_drift},
#'         \code{n_periods} and \code{verdict}, a traffic light with its
#'         numbers: \code{fail} when the slope is significant at the 1\%
#'         level - a pre-period that is trending is not parallel, whatever
#'         the drift ratio says; \code{caution} when the slope is significant
#'         at \code{alpha} but not at 1\%, or when the drift ratio exceeds
#'         1.25 (the fit deteriorates toward the cutoff without a resolvable
#'         trend); \code{ok} otherwise. A pre-period too short for the test
#'         gives \code{insufficient}.
#' @seealso \code{\link{nm_scm_diagnostics}}, which carries this result under
#'          \code{pre_trend}.
#' @examples
#' set.seed(1)
#' dates <- seq(as.Date("2023-01-01"), by = "day", length.out = 60)
#' syn <- data.frame(
#'   date = dates,
#'   observed = sin(seq_len(60) / 7) + rnorm(60, sd = 0.05),
#'   synthetic = sin(seq_len(60) / 7)
#' )
#' nm_pre_trend_test(syn, "2023-03-01")
#' @export
nm_pre_trend_test <- function(scm_result, cutoff_date, alpha = 0.05, min_periods = 5L) {
  if (is.data.frame(scm_result)) {
    synth <- scm_result
  } else if (is.list(scm_result) && "synthetic" %in% names(scm_result)) {
    synth <- scm_result[["synthetic"]]
  } else {
    stop("`scm_result` must be a data.frame or a list with a 'synthetic' key.", call. = FALSE)
  }
  if (!is.data.frame(synth)) {
    stop("The 'synthetic' entry must be a data.frame.", call. = FALSE)
  }
  for (col in c("observed", "synthetic")) {
    if (!col %in% colnames(synth)) {
      stop(sprintf("Column '%s' missing from the synthetic-control result.", col), call. = FALSE)
    }
  }
  if (!"date" %in% colnames(synth)) {
    stop("Column 'date' missing from the synthetic-control result.", call. = FALSE)
  }

  cutoff_ts <- as.Date(cutoff_date)
  pre <- synth[synth$date < cutoff_ts, , drop = FALSE]
  if (nrow(pre) == 0L) return(.nm_pre_trend_insufficient(0, min_periods))

  obs <- suppressWarnings(as.numeric(pre$observed))
  syn <- suppressWarnings(as.numeric(pre$synthetic))
  keep <- is.finite(obs) & is.finite(syn)
  e <- obs[keep] - syn[keep]
  n <- length(e)
  if (n < max(min_periods, 3L)) return(.nm_pre_trend_insufficient(n, min_periods))

  # OLS of e on the period index; the classical two-sided t-test, which is
  # what lm()'s summary reports (normet-py computes it with scipy).
  t_idx <- seq_len(n) - 1
  x <- cbind(1, t_idx)
  xtx_inv <- solve(crossprod(x))
  beta <- as.vector(xtx_inv %*% crossprod(x, e))
  resid <- e - as.vector(x %*% beta)
  dof <- n - 2L
  s2 <- sum(resid^2) / dof
  se_slope <- sqrt(max(s2, 0) * xtx_inv[2, 2])
  if (se_slope > 0 && is.finite(se_slope)) {
    p <- 2 * stats::pt(abs(beta[2] / se_slope), df = dof, lower.tail = FALSE)
  } else {
    p <- NA_real_
  }
  drift <- .nm_pt_drift(e)
  slope <- beta[2]

  if (!is.finite(p) || !is.finite(drift)) {
    verdict <- sprintf("indeterminate: the test could not be computed (p=%s, drift=%s)",
                       .nm_pt_g(p, 3), .nm_pt_g(drift, 3))
  } else if (p < 0.01) {
    verdict <- sprintf("fail: significant pre-trend (p=%s, drift=%s) -- the pre-period was not parallel",
                       .nm_pt_g(p, 3), .nm_pt_g(drift, 2))
  } else if (p < alpha) {
    verdict <- sprintf("caution: borderline pre-trend (p=%s, drift=%s)",
                       .nm_pt_g(p, 3), .nm_pt_g(drift, 2))
  } else if (drift > 1.25) {
    verdict <- sprintf("caution: the pre-period fit deteriorates toward the cutoff (p=%s, drift=%s)",
                       .nm_pt_g(p, 3), .nm_pt_g(drift, 2))
  } else {
    verdict <- sprintf("ok: no significant pre-trend (p=%s, drift=%s)",
                       .nm_pt_g(p, 3), .nm_pt_g(drift, 2))
  }

  structure(list(
    slope = slope,
    p_slope = p,
    rmpe_drift = drift,
    n_periods = as.integer(n),
    verdict = verdict
  ), class = "nm_pre_trend")
}

#' A one-line reading of the pre-trend test.
#' @export
print.nm_pre_trend <- function(x, ...) {
  cat(sprintf(
    "pre-trend on %d pre-period points: slope %s, p %s, drift %s | %s\n",
    x$n_periods, .nm_pt_g(x$slope, 3), .nm_pt_g(x$p_slope, 3),
    .nm_pt_g(x$rmpe_drift, 2), x$verdict
  ))
  invisible(x)
}
