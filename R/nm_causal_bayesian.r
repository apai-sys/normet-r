# Bayesian Synthetic Control Method
#
# Ported from Python normet causal/bayesian_scm.py
# Places a symmetric Dirichlet prior on donor simplex weights and fits
# with MCMC (Metropolis-within-Gibbs: the weights' log-ratios, then the noise SD,
# each with an adaptive step, started at the posterior mode).

NULL

#' Bayesian SCM with Simplex Weights
#'
#' Bayesian synthetic control with Dirichlet prior on donor weights and
#' Normal likelihood (normet-py's model, which PyMC samples with NUTS). Sampled
#' here by Metropolis-within-Gibbs: the weights by a random walk on their
#' log-ratios, then the noise SD on the log scale, each step adapted to its
#' acceptance rate during burn-in. The chain starts at the posterior mode (the
#' simplex least-squares weights, exactly the mode for \code{dirichlet_alpha = 1},
#' and their residual SD). On the bundled ULEZ design it gives what normet-py's
#' NUTS gives: the posterior mean fits MY1's pre-period with RMSE 21.7, not the
#' least-squares 13.2, as a flat prior on 53 donors puts its mass inside the simplex.
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

  # Metropolis-within-Gibbs with a Dirichlet prior on the simplex weights.
  # Weights: a Gaussian random walk on their log-ratios to the largest one
  # (w = softmax(z)), symmetric, so near the simplex's faces -- where a treated unit
  # outside its donors' range puts the posterior -- a step can leave and come back.
  # Sigma: a random walk on log(sigma). Likelihood: y ~ N(Xw, sigma).
  n_obs <- nrow(X_pre)

  log_prior <- function(w) {
    sum((dirichlet_alpha - 1) * log(w))
  }

  log_lik <- function(w, s) {
    mu <- X_pre %*% w
    -n_obs / 2 * log(s^2) - sum((y_pre - mu)^2) / (2 * s^2)
  }

  log_sigma_prior <- function(s) {
    if (s <= 0) return(-Inf)
    -s^2 / (2 * sigma_prior^2)
  }

  # The posterior in (z, log sigma): sum(log w) and log(sigma) are the Jacobians.
  log_target <- function(w, s) {
    if (any(w <= 0)) return(-Inf)
    lp <- log_prior(w) + log_lik(w, s) + log_sigma_prior(s) + sum(log(w)) + log(s)
    if (!is.finite(lp)) return(-Inf)
    lp
  }

  softmax <- function(z) {
    e <- exp(z - max(z))
    e / sum(e)
  }

  # Start at the posterior mode: the simplex least-squares weights (floored off the
  # simplex's faces) and their residual SD.
  w_cur <- .nm_simplex_weights(X_pre, y_pre) + 1e-6
  w_cur <- w_cur / sum(w_cur)
  ref <- which.max(w_cur)
  z_cur <- log(w_cur) - log(w_cur[ref])
  sigma_cur <- max(sqrt(mean((y_pre - X_pre %*% w_cur)^2)), 1e-6)
  lt_cur <- log_target(w_cur, sigma_cur)
  n_iter <- burnin + draws

  # Each proposal's step, adapted to its acceptance rate over the last 50 steps
  z_step <- 0.1
  sigma_step <- 0.1
  n_acc <- 0
  n_acc_sigma <- 0

  samples <- matrix(NA, nrow = draws, ncol = J)
  sigma_samples <- numeric(draws)

  pb <- NULL
  if (verbose && requireNamespace("progress", quietly = TRUE)) {
    pb <- progress::progress_bar$new(
      format = "  Bayesian SCM [:bar] :percent | ETA: :eta",
      total = n_iter, clear = FALSE, width = 60
    )
  }

  for (i in seq_len(n_iter)) {
    if (i %% 50 == 0 && i <= burnin) {
      if (n_acc / 50 < 0.15) z_step <- z_step * 0.8
      if (n_acc / 50 > 0.4) z_step <- z_step * 1.2
      if (n_acc_sigma / 50 < 0.15) sigma_step <- sigma_step * 0.8
      if (n_acc_sigma / 50 > 0.4) sigma_step <- sigma_step * 1.2
      n_acc <- 0
      n_acc_sigma <- 0
    }

    # Weights, sigma held
    z_prop <- z_cur
    z_prop[-ref] <- z_cur[-ref] + stats::rnorm(J - 1, 0, z_step)
    w_prop <- softmax(z_prop)
    lt_prop <- log_target(w_prop, sigma_cur)
    if (is.finite(lt_prop) && log(runif(1)) < lt_prop - lt_cur) {
      z_cur <- z_prop
      w_cur <- w_prop
      lt_cur <- lt_prop
      n_acc <- n_acc + 1
    }

    # Sigma, weights held
    sigma_prop <- sigma_cur * exp(stats::rnorm(1, 0, sigma_step))
    lt_prop <- log_target(w_cur, sigma_prop)
    if (is.finite(lt_prop) && log(runif(1)) < lt_prop - lt_cur) {
      sigma_cur <- sigma_prop
      lt_cur <- lt_prop
      n_acc_sigma <- n_acc_sigma + 1
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
