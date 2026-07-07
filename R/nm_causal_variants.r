# Alternative Synthetic-Control Estimators
#
# Ported from Python normet causal/variants.py
# Provides:
#   nm_scm_abadie  - classic Abadie/Diamond/Hainmueller SCM (simplex weights)
#   nm_did_baseline - difference-in-differences with donor-pool control
#   nm_scm_mcnnm   - Matrix Completion with Nuclear-Norm Minimisation
#   nm_scm_robust  - Robust SCM (HSVT de-noising; Amjad, Shah & Shen 2018)

NULL

.pivot_panel <- function(df, date_col, unit_col, outcome_col, treated_unit, donors) {
  dates <- sort(unique(df[[date_col]]))
  units <- sort(unique(df[[unit_col]]))
  mat <- matrix(NA, nrow = length(dates), ncol = length(units))
  rownames(mat) <- as.character(dates)
  colnames(mat) <- units
  r_idx <- match(df[[date_col]], dates)
  c_idx <- match(df[[unit_col]], units)
  mat[cbind(r_idx, c_idx)] <- df[[outcome_col]]

  if (!treated_unit %in% units) stop("Treated unit not found.")
  if (is.null(donors)) {
    donors <- setdiff(units, treated_unit)
  } else {
    donors <- intersect(donors, setdiff(units, treated_unit))
  }
  if (length(donors) == 0) stop("No valid donors.")
  list(panel = mat, donors = donors, dates = dates)
}

#' Classic Abadie SCM
#'
#' Classic Abadie/Diamond/Hainmueller SCM with simplex (sum-to-one,
#' non-negative) donor weights. Solves the constrained quadratic program.
#'
#' @inheritParams nm_scm
#' @param allow_negative_weights Logical. If TRUE, weights may be negative.
#'        Default FALSE.
#'
#' @return A list with \code{synthetic} (data.frame with \code{date},
#'         \code{observed}, \code{synthetic}, \code{effect}) and
#'         \code{weights} (named numeric vector).
#' @export
nm_scm_abadie <- function(df, date_col = "date", unit_col = "code",
                          outcome_col = "poll", treated_unit = NULL,
                          cutoff_date = NULL, donors = NULL,
                          allow_negative_weights = FALSE) {
  if (is.null(treated_unit) || is.null(cutoff_date)) {
    stop("`treated_unit` and `cutoff_date` are required.")
  }
  pd <- .pivot_panel(df, date_col, unit_col, outcome_col, treated_unit, donors)
  cutoff_ts <- as.Date(cutoff_date)
  pre_mask <- pd$dates < cutoff_ts
  if (sum(pre_mask) < 2) stop("Not enough pre-treatment rows.")

  X_pre <- pd$panel[pre_mask, pd$donors, drop = FALSE]
  y_pre <- pd$panel[pre_mask, treated_unit]
  complete <- complete.cases(X_pre) & is.finite(y_pre)
  X_pre <- X_pre[complete, , drop = FALSE]
  y_pre <- y_pre[complete]
  if (nrow(X_pre) < 2) stop("Not enough complete pre-treatment rows.")

  J <- length(pd$donors)
  Xm <- as.matrix(X_pre)
  ym <- as.numeric(y_pre)

  obj <- function(w) sum((ym - Xm %*% w)^2)
  gr <- function(w) 2 * t(Xm) %*% (Xm %*% w - ym)

  Aeq <- matrix(1, nrow = 1, ncol = J)
  beq <- 1
  if (allow_negative_weights) {
    lo <- rep(-Inf, J)
    hi <- rep(Inf, J)
  } else {
    lo <- rep(0, J)
    hi <- rep(1, J)
  }
  w0 <- rep(1 / J, J)
  res <- tryCatch(
    optim(w0, obj, gr, method = "L-BFGS-B", lower = lo, upper = hi,
      control = list(fnscale = 1, maxit = 1000)),
    error = function(e) NULL
  )
  if (is.null(res) || !is.null(res$convergence) && res$convergence != 0) {
    w <- w0
  } else {
    w <- res$par
  }
  if (!allow_negative_weights) {
    w <- pmax(w, 0)
    s <- sum(w)
    w <- if (s > 0) w / s else w0
  }
  names(w) <- pd$donors

  syn_full <- as.numeric(pd$panel[, pd$donors, drop = FALSE] %*% w)
  out <- data.frame(date = pd$dates, observed = pd$panel[, treated_unit],
    synthetic = syn_full)
  out$effect <- out$observed - out$synthetic
  list(synthetic = out, weights = w)
}

#' Difference-in-Differences Baseline
#'
#' Parallel-trends counterfactual using the donor pool as control.
#' Useful as a sanity check against more elaborate SCMs.
#'
#' @inheritParams nm_scm
#'
#' @return A list with \code{synthetic} and \code{weights} (uniform).
#' @export
nm_did_baseline <- function(df, date_col = "date", unit_col = "code",
                            outcome_col = "poll", treated_unit = NULL,
                            cutoff_date = NULL, donors = NULL) {
  if (is.null(treated_unit) || is.null(cutoff_date)) {
    stop("`treated_unit` and `cutoff_date` are required.")
  }
  pd <- .pivot_panel(df, date_col, unit_col, outcome_col, treated_unit, donors)
  cutoff_ts <- as.Date(cutoff_date)
  pre_mask <- pd$dates < cutoff_ts

  treated_pre <- mean(pd$panel[pre_mask, treated_unit], na.rm = TRUE)
  donor_pre <- mean(rowMeans(pd$panel[pre_mask, pd$donors, drop = FALSE], na.rm = TRUE), na.rm = TRUE)
  donor_mean_t <- rowMeans(pd$panel[, pd$donors, drop = FALSE], na.rm = TRUE)

  syn <- treated_pre + (donor_mean_t - donor_pre)
  out <- data.frame(date = pd$dates, observed = pd$panel[, treated_unit], synthetic = syn)
  out$effect <- out$observed - out$synthetic
  weights <- rep(1 / length(pd$donors), length(pd$donors))
  names(weights) <- pd$donors
  list(synthetic = out, weights = weights)
}

#' Matrix Completion with Nuclear-Norm Minimisation (MC-NNM)
#'
#' Implements the Athey et al. (2021) matrix completion method for
#' synthetic control. Treats the panel as low-rank with two-way fixed effects,
#' imputing masked post-treated entries.
#'
#' @inheritParams nm_scm
#' @param lam Numeric. Nuclear-norm regularisation strength. If NULL,
#'        defaults to \code{0.1 * sigma_max} of the observed pre-period matrix.
#' @param max_iter Integer. Maximum iterations. Default 300.
#' @param tol Numeric. Convergence tolerance. Default 1e-5.
#' @param with_unit_fe Logical. Include unit fixed effects. Default TRUE.
#' @param with_time_fe Logical. Include time fixed effects. Default TRUE.
#'
#' @return A list with \code{synthetic}, \code{weights} (filled with NaN),
#'         and \code{rank_lambda}.
#' @export
nm_scm_mcnnm <- function(df, date_col = "date", unit_col = "code",
                         outcome_col = "poll", treated_unit = NULL,
                         cutoff_date = NULL, donors = NULL,
                         lam = NULL, max_iter = 300, tol = 1e-5,
                         with_unit_fe = TRUE, with_time_fe = TRUE) {
  if (is.null(treated_unit) || is.null(cutoff_date)) {
    stop("`treated_unit` and `cutoff_date` are required.")
  }
  pd <- .pivot_panel(df, date_col, unit_col, outcome_col, treated_unit, donors)
  cutoff_ts <- as.Date(cutoff_date)

  cols <- c(pd$donors, treated_unit)
  Y <- pd$panel[, cols, drop = FALSE]
  T_ <- nrow(Y)
  N <- ncol(Y)
  treated_idx <- N

  pre_mask <- pd$dates < cutoff_ts
  M_obs <- !is.na(Y)
  M_obs[!pre_mask, treated_idx] <- FALSE

  if (!any(M_obs)) stop("Observation mask is empty.")

  Y0 <- Y
  Y0[!M_obs] <- 0
  unit_fe <- rep(0, N)
  time_fe <- rep(0, T_)
  L <- matrix(0, T_, N)

  if (is.null(lam)) {
    sigma_max <- tryCatch(svd(Y0, nu = 0, nv = 0)$d[1], error = function(e) 1)
    lam <- 0.1 * sigma_max
  }

  soft_threshold_svd <- function(M, lam_) {
    s <- svd(M)
    s_thr <- pmax(s$d - lam_, 0)
    s$u %*% diag(s_thr) %*% t(s$v)
  }

  prev_obj <- Inf
  for (it in seq_len(max_iter)) {
    R <- Y - L
    if (with_unit_fe) {
      R <- R - outer(time_fe, rep(1, N))
      denom <- colSums(M_obs)
      numer <- colSums(ifelse(M_obs, R, 0), na.rm = TRUE)
      unit_fe <- ifelse(denom > 0, numer / pmax(denom, 1), 0)
      R <- R - outer(rep(1, T_), unit_fe)
    }
    if (with_time_fe) {
      denom <- rowSums(M_obs)
      numer <- rowSums(ifelse(M_obs, R, 0), na.rm = TRUE)
      time_fe <- ifelse(denom > 0, numer / pmax(denom, 1), 0)
    }

    FE <- outer(rep(1, T_), if (with_unit_fe) unit_fe else 0) +
      outer(if (with_time_fe) time_fe else 0, rep(1, N))
    target <- ifelse(M_obs, Y - FE, L)
    L_new <- soft_threshold_svd(target, lam)

    diff_ <- sqrt(sum((L_new - L)^2)) / max(1, sqrt(sum(L^2)))
    L <- L_new
    if (diff_ < tol) break
    prev_obj <- diff_
  }

  FE <- outer(rep(1, T_), if (with_unit_fe) unit_fe else 0) +
    outer(if (with_time_fe) time_fe else 0, rep(1, N))
  Y_hat <- L + FE
  syn_treated <- Y_hat[, treated_idx]

  out <- data.frame(date = pd$dates,
    observed = pd$panel[, treated_unit],
    synthetic = syn_treated)
  out$effect <- out$observed - out$synthetic
  weights <- rep(NaN, length(pd$donors))
  names(weights) <- pd$donors
  list(synthetic = out, weights = weights, rank_lambda = lam)
}

#' Hard Singular-Value Thresholding (HSVT)
#'
#' Keep the top \code{rank} singular values (or the fewest values capturing
#' \code{energy} of the squared-singular-value spectrum) and zero the rest,
#' returning the de-noised matrix, the retained rank, and the full spectrum.
#' @noRd
.hsvt <- function(M, rank = NULL, energy = 0.95) {
  sv <- svd(M)
  s <- sv$d
  if (length(s) == 0) {
    return(list(M_hat = M, k = 0L, s = s))
  }
  if (!is.null(rank)) {
    k <- as.integer(min(max(as.integer(rank), 1L), length(s)))
  } else {
    e <- cumsum(s^2) / sum(s^2)
    k <- which(e >= energy)[1]
    if (is.na(k)) k <- length(s)
    k <- as.integer(min(max(k, 1L), length(s)))
  }
  s_keep <- s
  if (k < length(s)) s_keep[(k + 1L):length(s)] <- 0
  # U diag(s_keep) V^T  (s_keep scales the rows of t(V))
  m_hat <- sv$u %*% (s_keep * t(sv$v))
  list(M_hat = m_hat, k = k, s = s)
}

#' Robust Synthetic Control (Amjad, Shah & Shen 2018)
#'
#' De-noises the donor outcome matrix via hard singular-value thresholding
#' (HSVT), then learns unconstrained (optionally ridge-regularised) donor
#' weights by regressing the treated pre-period outcome on the de-noised
#' donors. The synthetic series is the de-noised donor matrix projected through
#' those weights. Unlike \code{nm_scm_abadie}, weights are \strong{not}
#' simplex-constrained — the SVD de-noising is what controls overfitting.
#'
#' @inheritParams nm_scm
#' @param rank Integer or NULL. Number of singular values to retain in HSVT.
#'        If NULL (default), chosen as the smallest rank capturing \code{energy}
#'        of the spectral energy.
#' @param energy Numeric. Target cumulative spectral energy for automatic rank
#'        selection (ignored when \code{rank} is given). Default 0.95.
#' @param alpha Numeric. Ridge penalty on donor weights (the intercept is never
#'        penalised). 0 gives ordinary least squares on the de-noised donors.
#'        Default 0.
#' @param rescale_missing Logical. Divide the recovered low-rank component by
#'        the observed fraction \code{p} to debias HSVT under (approximately)
#'        missing-at-random gaps. Default TRUE.
#' @param verbose Logical. Print an INFO log line with the retained rank.
#'        Default TRUE.
#'
#' @return A list with \code{synthetic} (data.frame with \code{date},
#'         \code{observed}, \code{synthetic}, \code{effect}), \code{weights}
#'         (named numeric vector), \code{rank} (integer), and \code{intercept}.
#' @export
nm_scm_robust <- function(df, date_col = "date", unit_col = "code",
                          outcome_col = "poll", treated_unit = NULL,
                          cutoff_date = NULL, donors = NULL,
                          rank = NULL, energy = 0.95, alpha = 0,
                          rescale_missing = TRUE, verbose = TRUE) {
  if (is.null(treated_unit) || is.null(cutoff_date)) {
    stop("`treated_unit` and `cutoff_date` are required.")
  }
  pd <- .pivot_panel(df, date_col, unit_col, outcome_col, treated_unit, donors)
  cutoff_ts <- as.Date(cutoff_date)
  pre_mask <- pd$dates < cutoff_ts

  X <- pd$panel[, pd$donors, drop = FALSE]   # (T, J)
  y <- as.numeric(pd$panel[, treated_unit])  # (T,)

  # De-noise the donor matrix: centre per donor, fill gaps with 0, HSVT,
  # debias by 1/p, then add the column means back.
  obs <- is.finite(X)
  col_mean <- vapply(seq_len(ncol(X)), function(j) {
    cj <- X[, j]
    if (any(is.finite(cj))) mean(cj[is.finite(cj)]) else 0
  }, numeric(1))
  Xc <- X
  for (j in seq_len(ncol(X))) {
    cj <- X[, j] - col_mean[j]
    cj[!is.finite(X[, j])] <- 0
    Xc[, j] <- cj
  }
  p <- if (rescale_missing) mean(obs) else 1
  if (!is.finite(p) || p <= 0) p <- 1
  hs <- .hsvt(Xc, rank = rank, energy = energy)
  X_hat <- sweep(hs$M_hat / p, 2, col_mean, "+")

  # Regress treated pre-period outcome on de-noised donors (with intercept).
  fit_rows <- pre_mask & is.finite(y)
  if (sum(fit_rows) < 2) stop("Not enough observed pre-treatment rows to fit robust SCM.")
  A <- cbind(1, X_hat[fit_rows, , drop = FALSE])  # (T_pre, J+1)
  b <- y[fit_rows]

  J <- length(pd$donors)
  if (!is.null(alpha) && alpha > 0) {
    # Ridge in closed form; do not penalise the intercept column.
    pen <- diag(J + 1) * alpha
    pen[1, 1] <- 0
    coef <- solve(crossprod(A) + pen, crossprod(A, b))
  } else {
    # Minimum-norm least squares via SVD (mirrors numpy.linalg.lstsq), robust
    # to the rank-deficiency introduced by HSVT de-noising.
    sv <- svd(A)
    tol <- max(dim(A)) * .Machine$double.eps * max(sv$d)
    d_inv <- ifelse(sv$d > tol, 1 / sv$d, 0)
    coef <- sv$v %*% (d_inv * crossprod(sv$u, b))
  }
  coef <- as.numeric(coef)
  intercept <- coef[1]
  w <- coef[-1]
  names(w) <- pd$donors

  syn <- intercept + as.numeric(X_hat %*% w)
  out <- data.frame(date = pd$dates,
    observed = as.numeric(pd$panel[, treated_unit]),
    synthetic = syn)
  out$effect <- out$observed - out$synthetic

  if (verbose) {
    log <- nm_get_logger("causal.scm_robust")
    log$info("Robust SCM | retained rank=%d | donors=%d | p_obs=%.3f", hs$k, J, p)
  }
  list(synthetic = out, weights = w, rank = as.integer(hs$k), intercept = intercept)
}
