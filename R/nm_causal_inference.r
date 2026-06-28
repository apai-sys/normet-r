# Inference for Synthetic-Control Estimates
#
# Ported from Python normet causal/inference.py
# Provides:
#   nm_conformal_effect_interval - conformal prediction interval for ATT
#   nm_rmspe_ratio_test          - Abadie's RMSPE-ratio placebo test

NULL

.coerce_effect <- function(scm_result) {
  if (is.data.frame(scm_result)) {
    synth <- scm_result
  } else if (is.list(scm_result) && "synthetic" %in% names(scm_result)) {
    synth <- scm_result[["synthetic"]]
  } else {
    stop("Expected a data.frame or list with 'synthetic' key.")
  }
  if (!"effect" %in% colnames(synth)) stop("Effect column missing.")
  synth[, c("date", "effect")]
}

#' Conformal Effect Interval
#'
#' Finite-sample conformal prediction interval for the average post-period
#' treatment effect. Uses sub-sampling to build a null distribution.
#'
#' @param scm_result Data.frame or list. SCM output with an \code{effect}
#'        column in \code{synthetic}.
#' @param cutoff_date Character or Date. Treatment cutoff.
#' @param n_perm Integer. Number of permutations. Default 1000.
#' @param ci_level Numeric. Confidence level. Default 0.95.
#' @param random_state Integer. Random seed. Default 7654321.
#'
#' @return A list with \code{att}, \code{low}, \code{high}, \code{p_value},
#'         \code{n_post}, \code{n_perm}.
#' @export
nm_conformal_effect_interval <- function(scm_result, cutoff_date,
                                         n_perm = 1000, ci_level = 0.95,
                                         random_state = 7654321) {
  eff_df <- .coerce_effect(scm_result)
  eff <- eff_df$effect
  names(eff) <- as.character(eff_df$date)
  cutoff_ts <- as.Date(cutoff_date)

  post_mask <- as.Date(names(eff)) >= cutoff_ts
  post <- eff[post_mask & is.finite(eff)]
  n_post <- length(post)
  if (n_post == 0) stop("No post-period observations.")

  att <- mean(post)
  all_vals <- eff[is.finite(eff)]
  n_total <- length(all_vals)
  if (n_total <= n_post) stop("Need pre-period to build null distribution.")

  set.seed(random_state)
  starts <- sample.int(n_total - n_post + 1, size = n_perm, replace = TRUE)
  idx_mat <- outer(starts, seq_len(n_post) - 1L, `+`)
  means <- rowMeans(matrix(all_vals[idx_mat], nrow = n_perm, ncol = n_post))

  p_two_sided <- (sum(abs(means) >= abs(att)) + 1) / (length(means) + 1)
  alpha <- 1 - ci_level
  q <- quantile(abs(means), 1 - alpha, na.rm = TRUE)

  list(att = att, low = att - q, high = att + q,
    p_value = p_two_sided, n_post = n_post, n_perm = length(means))
}

#' RMSPE Ratio Test
#'
#' Abadie's classical placebo significance heuristic: compare the treated
#' unit's post/pre RMSPE ratio against the placebo distribution from
#' \code{placebo_in_space}.
#'
#' @param placebo_space_out List. Output of \code{nm_placebo_in_space}.
#'        Must contain \code{treated} (data.frame with \code{effect}) and
#'        \code{placebos} (list of data.frames).
#' @param cutoff_date Character or Date. Treatment cutoff.
#'
#' @return A list with \code{treated_ratio}, \code{placebo_ratios}
#'         (named numeric), \code{p_value}, \code{rank}. \code{rank} is
#'         1-indexed from largest to smallest, with ties broken in favour
#'         of the treated unit (i.e. \code{rank = 1 + count of ratios
#'         strictly greater than treated_ratio}).
#' @export
nm_rmspe_ratio_test <- function(placebo_space_out, cutoff_date) {
  if (!"treated" %in% names(placebo_space_out)) {
    stop("`placebo_space_out` must contain 'treated'.")
  }
  cutoff_ts <- as.Date(cutoff_date)

  rmspe_ratio <- function(eff) {
    eff <- eff[is.finite(eff)]
    pre <- eff[as.Date(names(eff)) < cutoff_ts]
    post <- eff[as.Date(names(eff)) >= cutoff_ts]
    if (length(pre) == 0 || length(post) == 0) return(NA_real_)
    pre_rmspe <- sqrt(mean(pre^2))
    post_rmspe <- sqrt(mean(post^2))
    if (pre_rmspe > 0) post_rmspe / pre_rmspe else NA_real_
  }

  treated_df <- placebo_space_out[["treated"]]
  treated_eff <- setNames(treated_df$effect, as.character(treated_df$date))
  treated_ratio <- rmspe_ratio(treated_eff)

  placebo_ratios <- c()
  for (nm in names(placebo_space_out[["placebos"]])) {
    p <- placebo_space_out[["placebos"]][[nm]]
    if ("effect" %in% colnames(p)) s <- p$effect
    else if (nm %in% colnames(p)) s <- p[[nm]]
    else s <- p[[1]]
    if (length(s) > 0) {
      s_named <- setNames(as.numeric(s), as.character(p$date))
      r <- rmspe_ratio(s_named)
      if (is.finite(r)) placebo_ratios[nm] <- r
    }
  }

  all_ratios <- c(placebo_ratios, treated = treated_ratio)
  if (length(placebo_ratios) == 0 || all(!is.finite(placebo_ratios))) {
    return(list(treated_ratio = treated_ratio, placebo_ratios = placebo_ratios,
      p_value = NA_real_, rank = 1))
  }
  p_value <- (sum(placebo_ratios >= treated_ratio, na.rm = TRUE) + 1) /
    (sum(is.finite(placebo_ratios)) + 1)
  # Best rank among ties (matches Python's np.searchsorted-based formula):
  # rank = 1 + count of ratios strictly greater than treated_ratio.
  rank <- sum(all_ratios > treated_ratio, na.rm = TRUE) + 1

  list(treated_ratio = treated_ratio, placebo_ratios = placebo_ratios,
    p_value = p_value, rank = rank)
}
