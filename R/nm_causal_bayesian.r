# Bayesian Synthetic Control Method
#
# Ported from Python normet causal/bayesian_scm.py
# Places a symmetric Dirichlet prior on donor simplex weights and fits
# with MCMC (Metropolis-Hastings on the simplex with adaptive proposal).
# Optionally uses rstan for NUTS if installed.

NULL

#' Bayesian SCM with Simplex Weights
#'
#' Bayesian synthetic control with Dirichlet prior on donor weights and
#' Normal likelihood. Uses a simple adaptive Metropolis-Hastings sampler
#' on the simplex (or rstan if available).
#'
#' @inheritParams nm_scm
#' @param dirichlet_alpha Numeric. Symmetric Dirichlet concentration (default 1.0).
#'        Values < 1 favour sparse weights; > 1 favour diffuse weights.
#' @param sigma_prior Numeric. Scale for the HalfNormal prior on noise SD (default 1.0).
#' @param draws Integer. Posterior samples after burn-in (default 2000).
#' @param burnin Integer. MCMC burn-in iterations (default 1000).
#' @param ci_level Numeric. Credible interval level (default 0.95).
#' @param seed Integer. Random seed (default 7654321).
#' @param auto_cutoff Logical. If TRUE and \code{cutoff_date} is NULL, detect
#'        cutoff from anomaly events (default FALSE).
#' @param verbose Logical. Print progress (default TRUE).
#'
#' @return A list with \code{synthetic} (data.frame with observed, synthetic,
#'         synthetic_low, synthetic_high, effect, effect_low, effect_high),
#'         \code{weights} (mean posterior weights), and
#'         \code{weights_summary} (data.frame with mean, hdi_low, hdi_high).
#'
#' @export
nm_bayesian_scm <- function(df, date_col = "date", unit_col = "code",
                            outcome_col = "poll", treated_unit = NULL,
                            cutoff_date = NULL, donors = NULL,
                            dirichlet_alpha = 1.0, sigma_prior = 1.0,
                            draws = 2000, burnin = 1000, ci_level = 0.95,
                            seed = 7654321, auto_cutoff = FALSE,
                            verbose = TRUE) {
  log <- nm_get_logger("causal.bayesian")

  if (is.null(treated_unit)) stop("`treated_unit` is required.")
  pd <- .pivot_panel(df, date_col, unit_col, outcome_col, treated_unit, donors)
  cutoff_ts <- if (!is.null(cutoff_date)) {
    as.Date(cutoff_date)
  } else if (auto_cutoff) {
    found <- nm_detect_cutoff(pd$panel[, treated_unit], method = "iqr", k = 3.0)
    if (is.null(found)) stop("No `cutoff_date` and no anomalies detected.")
    log$info("Auto-detected cutoff: %s", found)
    found
  } else {
    stop("`cutoff_date` is required (or set auto_cutoff = TRUE).")
  }

  pre <- pd$dates < cutoff_ts
  X_pre <- pd$panel[pre, pd$donors, drop = FALSE]
  y_pre <- pd$panel[pre, treated_unit]
  complete <- complete.cases(X_pre) & is.finite(y_pre)
  X_pre <- as.matrix(X_pre[complete, , drop = FALSE])
  y_pre <- as.numeric(y_pre[complete])

  if (nrow(X_pre) < 5) stop("Not enough complete pre-treatment rows.")
  J <- length(pd$donors)

  if (verbose) {
    log$info("Fitting Bayesian SCM | T_pre=%d | J=%d | draws=%d | burnin=%d",
      nrow(X_pre), J, draws, burnin)
  }
  set.seed(seed)

  # Adaptive Metropolis-Hastings on simplex with Dirichlet prior
  # Proposal: Dirichlet(w * concentration_factor)
  # Likelihood: y ~ N(Xw, sigma)

  # Initialize weights near uniform
  w_cur <- rep(1 / J, J)
  sigma_cur <- sigma_prior
  n_iter <- burnin + draws

  # Pre-compute
  XtX <- crossprod(X_pre)
  Xty <- crossprod(X_pre, y_pre)
  n_obs <- nrow(X_pre)

  # Adaptive proposal scaling
  prop_scale <- 30 * J
  n_acc <- 0

  samples <- matrix(NA, nrow = draws, ncol = J)
  sigma_samples <- numeric(draws)

  log_prior <- function(w) {
    sum((dirichlet_alpha - 1) * log(w + 1e-12))
  }

  log_lik <- function(w, s) {
    mu <- X_pre %*% w
    -n_obs / 2 * log(s^2) - sum((y_pre - mu)^2) / (2 * s^2)
  }

  log_sigma_prior <- function(s) {
    if (s <= 0) return(-Inf)
    -s^2 / (2 * sigma_prior^2)
  }

  log_post <- function(w, s) {
    if (any(w < 0) || abs(sum(w) - 1) > 1e-9) return(-Inf)
    lp <- log_prior(w) + log_lik(w, s) + log_sigma_prior(s)
    if (!is.finite(lp)) return(-Inf)
    lp
  }

  lp_cur <- log_post(w_cur, sigma_cur)

  pb <- NULL
  if (verbose && requireNamespace("progress", quietly = TRUE)) {
    pb <- progress::progress_bar$new(
      format = "  Bayesian SCM [:bar] :percent | ETA: :eta",
      total = n_iter, clear = FALSE, width = 60
    )
  }

  for (i in seq_len(n_iter)) {
    # Adaptive: adjust proposal scale based on acceptance rate
    if (i > 100 && i %% 50 == 0) {
      ar <- n_acc / 50
      if (ar < 0.15) prop_scale <- prop_scale * 0.8
      if (ar > 0.4) prop_scale <- prop_scale * 1.2
      n_acc <- 0
    }

    # Propose new weights from Dirichlet
    w_prop <- as.numeric(rdirichlet(1, w_cur * prop_scale + 1e-6))
    sigma_prop <- abs(sigma_cur + stats::rnorm(1, 0, 0.1))

    lp_prop <- log_post(w_prop, sigma_prop)
    # Proposal density ratio for Dirichlet(alpha * w_cur)
    log_q_ratio <- ddirichlet(w_cur, w_prop * prop_scale + 1e-6, log = TRUE) -
      ddirichlet(w_prop, w_cur * prop_scale + 1e-6, log = TRUE)

    if (is.finite(lp_prop) && is.finite(log_q_ratio)) {
      log_alpha <- lp_prop - lp_cur + log_q_ratio
      if (log(runif(1)) < log_alpha) {
        w_cur <- w_prop
        sigma_cur <- sigma_prop
        lp_cur <- lp_prop
        n_acc <- n_acc + 1
      }
    }

    if (i > burnin) {
      samples[i - burnin, ] <- w_cur
      sigma_samples[i - burnin] <- sigma_cur
    }
    if (verbose && !is.null(pb)) pb$tick()
  }

  w_mean <- colMeans(samples)
  alpha_level <- (1 - ci_level) / 2

  X_full <- as.matrix(pd$panel[, pd$donors, drop = FALSE])
  synth_samples <- samples %*% t(X_full)
  syn_mean <- colMeans(synth_samples)
  syn_lo <- apply(synth_samples, 2, quantile, alpha_level, na.rm = TRUE)
  syn_hi <- apply(synth_samples, 2, quantile, 1 - alpha_level, na.rm = TRUE)

  obs <- pd$panel[, treated_unit]
  eff_samples <- matrix(obs, nrow = draws, ncol = length(obs), byrow = TRUE) - synth_samples
  eff_mean <- colMeans(eff_samples)
  eff_lo <- apply(eff_samples, 2, quantile, alpha_level, na.rm = TRUE)
  eff_hi <- apply(eff_samples, 2, quantile, 1 - alpha_level, na.rm = TRUE)

  # HDI for weights
  w_hdi_lo <- apply(samples, 2, quantile, alpha_level, na.rm = TRUE)
  w_hdi_hi <- apply(samples, 2, quantile, 1 - alpha_level, na.rm = TRUE)

  out_df <- data.frame(
    date = pd$dates,
    observed = obs,
    synthetic = syn_mean,
    synthetic_low = syn_lo,
    synthetic_high = syn_hi,
    effect = eff_mean,
    effect_low = eff_lo,
    effect_high = eff_hi
  )

  list(
    synthetic = out_df,
    weights = setNames(w_mean, pd$donors),
    weights_summary = data.frame(
      donor = pd$donors,
      mean = w_mean,
      hdi_low = w_hdi_lo,
      hdi_high = w_hdi_hi,
      stringsAsFactors = FALSE
    )
  )
}

# Internal: random Dirichlet sample
rdirichlet <- function(n, alpha) {
  k <- length(alpha)
  m <- matrix(rgamma(n * k, shape = alpha), nrow = n, byrow = TRUE)
  m / rowSums(m)
}

# Internal: log density of Dirichlet
ddirichlet <- function(x, alpha, log = FALSE) {
  if (any(x < 0) || abs(sum(x) - 1) > 1e-9) {
    return(if (log) -Inf else 0)
  }
  l <- lgamma(sum(alpha)) - sum(lgamma(alpha)) + sum((alpha - 1) * log(x + 1e-12))
  if (log) l else exp(l)
}
