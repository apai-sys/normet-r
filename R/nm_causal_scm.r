#' Augmented Synthetic Control Method (SCM)
#'
#' \code{nm_scm} implements the Augmented Synthetic Control Method for a single treated unit.
#' It combines a ridge regression model (to remove time-varying bias) with a standard
#' synthetic control weighting scheme (QP) on the residuals.
#'
#' @param df Long data frame with columns for date, unit, and outcome.
#' @param date_col Name of the date column (coercible to Date).
#' @param unit_col Name of the unit identifier column.
#' @param outcome_col Name of the outcome column.
#' @param treated_unit The treated unit identifier.
#' @param cutoff_date The intervention cutoff date (character or Date).
#' @param donors Optional character vector of donor unit identifiers. If NULL, uses all non-treated units.
#' @param pre_covariates Optional character vector of pre-period covariate columns to augment features.
#' @param alphas Optional numeric vector of ridge lambdas. If NULL, uses seq(0.1, 10, by = 0.1).
#' @param allow_negative_weights Logical; if TRUE, donor weights may be negative. Default FALSE.
#' @param n_cores Integer; number of CPU cores for fitting the per-timepoint ridge
#'        bias-correction model (one \code{cv.glmnet} fit per date in the panel,
#'        pre- and post-period). Default 1 (sequential). When > 1, fits are
#'        dispatched in parallel via \pkg{foreach}/\pkg{doSNOW} (falls back to
#'        sequential if those packages aren't installed). Leave at the default
#'        when calling \code{nm_scm} from \code{\link{nm_placebo_in_time}},
#'        \code{\link{nm_placebo_in_space}}, or \code{\link{nm_scm_all}} --
#'        those already parallelise across cutoffs/units, and nesting another
#'        parallel cluster inside each worker oversubscribes CPU cores rather
#'        than helping. Most useful for a single standalone \code{nm_scm} call
#'        on a panel with many timepoints.
#' @param verbose Logical; if TRUE, prints log messages and shows a progress bar. Default TRUE.
#'
#' @return A list containing:
#' \describe{
#'   \item{synthetic}{A data frame with observed, synthetic, and effect time series.}
#'   \item{weights}{A named vector of donor weights.}
#'   \item{alpha}{A list mapping each timestamp to the chosen Ridge lambda
#'         (named \code{alpha} for parity with the Python \code{scm()} return).}
#' }
#'
#' @examples
#' \donttest{
#' res <- nm_scm(
#'   df = scm, date_col = "date", unit_col = "ID", outcome_col = "NO2",
#'   treated_unit = "2+26 cities", cutoff_date = "2015-12-01", verbose = FALSE
#' )
#' head(res$synthetic)
#' }
#'
#' @export
nm_scm <- function(df, date_col = "date", unit_col = "code", outcome_col = "poll",
                   treated_unit = NULL, cutoff_date = NULL, donors = NULL,
                   pre_covariates = NULL, alphas = NULL, allow_negative_weights = FALSE,
                   n_cores = 1, verbose = TRUE) {
  # --- 0. Setup and Basic Validation ---
  if (is.null(treated_unit) || is.null(cutoff_date)) {
    stop("Both `treated_unit` and `cutoff_date` must be provided.")
  }

  # Ensure date format
  df[[date_col]] <- as.Date(df[[date_col]])
  cutoff_ts <- as.Date(cutoff_date)

  if (!treated_unit %in% df[[unit_col]]) {
    stop("Treated unit not found in data.")
  }

  # --- 1. Pivot to Wide Panel (Date x Units) ---
  pd <- .pivot_panel(df, date_col, unit_col, outcome_col, treated_unit, donors)
  panel_mat  <- pd$panel
  unique_dates <- pd$dates
  donors     <- pd$donors

  # --- 2. Pre/Post Split ---
  # Ensure strict pre-period definition (< cutoff)
  pre_mask <- unique_dates < cutoff_ts
  dates_pre <- unique_dates[pre_mask]

  if (length(dates_pre) < 3 && verbose) {
    warning("Very short pre-period; results may be unstable.")
  }

  # --- 3. Build Ridge Feature Matrices (Rows = Units, Cols = Pre-Period Times) ---
  # Extract pre-period submatrix
  Y_pre_full <- panel_mat[pre_mask, , drop = FALSE]

  # We need complete cases for the transposition (Features must be non-NA)
  # But in matrix form, NA handling is tricky.
  # Strategy: We assume time-series are mostly complete.
  # Features X = Transpose of Pre-period outcomes.
  # X_donors: (N_donors x T_pre)
  X_donors <- t(Y_pre_full[, donors, drop = FALSE])
  X_treated <- t(Y_pre_full[, treated_unit, drop = FALSE])

  # Filter out donors that have ANY missing values in the pre-period
  # (Standard SCM requirement: donors must be complete in pre-period)
  valid_donor_mask <- apply(X_donors, 1, function(row) !any(is.na(row)))
  if (sum(valid_donor_mask) == 0) stop("No donors have complete pre-treatment data.")

  donors <- donors[valid_donor_mask]
  X_donors <- X_donors[valid_donor_mask, , drop = FALSE]

  # Check treated unit completeness
  if (any(is.na(X_treated))) stop("Treated unit has missing values in the pre-period.")

  # --- 4. Optional Covariate Augmentation ---
  if (!is.null(pre_covariates)) {
    # Filter data to pre-period
    df_pre <- df[df[[date_col]] < cutoff_ts, ]

    # Base R aggregation: Calculate mean of each covariate by unit
    # Formula interface: covariate ~ unit
    # But for multiple covariates, aggregate(x, by, FUN) is cleaner
    cov_agg <- aggregate(df_pre[, pre_covariates, drop = FALSE],
      by = list(unit = df_pre[[unit_col]]),
      FUN = mean, na.rm = TRUE)

    # Align covariates to X matrices
    rownames(cov_agg) <- cov_agg$unit

    # Check if we have covariates for treated and donors
    common_units <- intersect(cov_agg$unit, c(treated_unit, donors))

    if (!treated_unit %in% common_units) stop("Treated unit missing covariate data.")

    # Update donors based on covariate availability
    donors <- intersect(donors, common_units)
    if (length(donors) == 0) stop("No donors left after covariate merging.")

    # Re-subset X_donors
    X_donors <- X_donors[donors, , drop = FALSE]

    # Extract covariate matrices
    cov_donors <- as.matrix(cov_agg[match(donors, cov_agg$unit), pre_covariates, drop = FALSE])
    cov_treated <- as.matrix(cov_agg[match(treated_unit, cov_agg$unit), pre_covariates, drop = FALSE])

    # Augment: bind covariates as extra columns (features)
    X_donors <- cbind(X_donors, cov_donors)
    X_treated <- cbind(X_treated, cov_treated)
  }

  # --- 5. RidgeCV Predictions (Augmentation Step) ---
  if (is.null(alphas)) alphas <- seq(0.1, 10, by = 0.1)
  lambda_grid <- sort(as.numeric(alphas), decreasing = TRUE)

  # Prepare placeholders
  n_times <- nrow(panel_mat)
  m_treated <- rep(NA_real_, n_times)
  m_donors <- matrix(NA_real_, nrow = n_times, ncol = length(donors))
  colnames(m_donors) <- donors
  alpha_map <- list()

  # Loop through every time point t (Pre AND Post)
  # We regress Outcome_t on Pre-Period Features to learn the bias structure.
  # Each t is an independent cv.glmnet fit, so this is dispatched in parallel
  # via foreach/doSNOW when n_cores > 1 (same pattern as nm_placebo_in_time /
  # nm_placebo_in_space / nm_scm_all). Sequential by default (n_cores = 1) so
  # callers that already parallelise at an outer level -- nm_placebo_in_time,
  # nm_placebo_in_space, nm_scm_all, none of which pass n_cores through to
  # nm_scm() -- don't end up nesting parallel clusters inside parallel workers.
  fit_one_time <- function(t) {
    y_t <- panel_mat[t, donors] # Vector of length N_donors

    # Identify valid donors for this time point (outcome observed)
    mask <- is.finite(y_t)

    # Need sufficient data to fit ridge
    if (sum(mask) < 3) return(NULL)

    # glmnet requires samples in rows, features in cols
    # X_donors is (N_donors x Features)
    x_train <- X_donors[mask, , drop = FALSE]
    y_train <- y_t[mask]

    # Fit Ridge
    cv_fit <- glmnet::cv.glmnet(
      x = x_train,
      y = y_train,
      alpha = 0,
      lambda = lambda_grid,
      family = "gaussian",
      standardize = TRUE
    )

    list(
      t = t,
      chosen_lambda = cv_fit$lambda.min,
      # Predict bias component for Treated unit
      m_treated_t = as.numeric(stats::predict(cv_fit, newx = X_treated, s = "lambda.min")),
      # Predict bias component for All Donors (even those missing at time t, if possible)
      # X_donors contains all valid pre-period donors
      m_donors_row = as.numeric(stats::predict(cv_fit, newx = X_donors, s = "lambda.min"))
    )
  }

  n_cores_eff <- if (is.null(n_cores)) 1 else max(1, as.integer(n_cores))
  use_parallel <- n_cores_eff > 1 && n_times > 1 &&
    requireNamespace("foreach", quietly = TRUE) && requireNamespace("doSNOW", quietly = TRUE)

  if (use_parallel) {
    if (verbose) message(sprintf("Fitting %d per-timepoint ridge models using %d parallel cores.", n_times, n_cores_eff))

    cl <- parallel::makeCluster(n_cores_eff)
    .nm_propagate_libpaths(cl)
    doSNOW::registerDoSNOW(cl)
    on.exit(parallel::stopCluster(cl), add = TRUE)

    opts <- list()
    if (verbose && requireNamespace("progress", quietly = TRUE)) {
      pb <- progress::progress_bar$new(total = n_times, format = "  Ridge fits [:bar] :percent :eta", width = 60)
      opts <- list(progress = function(n) pb$tick())
    }

    # `fit_one_time` is auto-detected and exported by foreach since it's
    # referenced directly in the %dopar% expression below; listing it in
    # `.export` too just produces a harmless "already exporting" warning.
    fits <- foreach::foreach(
      t = seq_len(n_times),
      .packages = c("glmnet", "stats"),
      .options.snow = opts
    ) %dopar% fit_one_time(t)
  } else {
    pb <- NULL
    if (verbose) pb <- utils::txtProgressBar(min = 0, max = n_times, style = 3)
    fits <- vector("list", n_times)
    for (t in seq_len(n_times)) {
      if (verbose) utils::setTxtProgressBar(pb, t)
      fits[[t]] <- fit_one_time(t)
    }
    if (verbose && !is.null(pb)) close(pb)
  }

  for (res in fits) {
    if (is.null(res)) next
    t <- res$t
    alpha_map[[as.character(unique_dates[t])]] <- res$chosen_lambda
    m_treated[t] <- res$m_treated_t
    m_donors[t, ] <- res$m_donors_row
  }

  # --- 6. Residual Construction (De-biasing) ---
  # Observed Donors Matrix - Bias Donors Matrix
  # Only use rows/cols that align

  # Extract relevant columns from panel_mat
  Y_donors_all <- panel_mat[, donors, drop = FALSE]

  # Calculate Residuals
  R_don_full <- Y_donors_all - m_donors
  r_treat_full <- panel_mat[, treated_unit] - m_treated

  # Subset to Pre-period for Optimization
  R_pre <- R_don_full[pre_mask, , drop = FALSE]
  r_pre <- r_treat_full[pre_mask]

  # Remove any rows with NAs in residuals (should be rare if pre-period was filtered correctly)
  complete_res_mask <- complete.cases(R_pre) & is.finite(r_pre)

  if (sum(complete_res_mask) < 3) stop("Insufficient complete residuals in pre-period for optimization.")

  R_pre_clean <- R_pre[complete_res_mask, , drop = FALSE]
  r_pre_clean <- r_pre[complete_res_mask]

  # --- 7. Quadratic Programming (Weight Optimization) ---
  # Minimize || r_pre - R_pre * w ||^2

  J <- length(donors)

  # Dmat = 2 * R'R
  Dmat <- 2 * crossprod(R_pre_clean)
  # Regularize slightly to ensure positive definiteness
  Dmat <- Dmat + 1e-8 * diag(J)

  # dvec = 2 * R'r
  dvec <- 2 * crossprod(R_pre_clean, r_pre_clean)

  # Constraint 1: Sum(w) = 1
  A_eq <- matrix(1, nrow = 1, ncol = J)
  b_eq <- 1

  if (allow_negative_weights) {
    # No inequality constraints
    Amat <- t(A_eq)
    bvec <- b_eq
    meq <- 1
  } else {
    # Constraint 2: w >= 0
    A_ineq <- diag(J)
    b_ineq <- rep(0, J)

    # Combine (Equality first)
    Amat <- t(rbind(A_eq, A_ineq))
    bvec <- c(b_eq, b_ineq)
    meq <- 1
  }

  # Solve QP
  w <- tryCatch(
    {
      sol <- quadprog::solve.QP(Dmat, dvec, Amat, bvec, meq = meq)
      sol$solution
    },
    error = function(e) {
      if (verbose) warning(sprintf("QP Solver failed: %s. Defaulting to uniform weights.", e$message))
      rep(1 / J, J)
    })

  # Post-process weights
  if (!allow_negative_weights) w <- pmax(w, 0) # Clip tiny negatives

  # Re-normalize just in case
  sw <- sum(w)
  if (sw <= 1e-9 || !is.finite(sw)) {
    w <- rep(1 / J, J)
  } else {
    w <- w / sw
  }

  weights <- stats::setNames(w, donors)

  # --- 8. Synthetic Path Construction ---
  # Synthetic = Bias_treated + (Residuals_donors * w)
  # synth_res = R_don_full %*% weights

  # Handle potential NAs in post-period donors
  # If a donor is missing in post-period, we can't use it for that day's synthetic.
  # Simple imputation: treat missing residual as 0 (bias explained everything) or skip row.
  # Here we use matrix multiplication which propagates NAs.

  synth_residual <- as.numeric(R_don_full %*% w)
  synthetic_path <- as.numeric(m_treated) + synth_residual

  # Output Data Frame
  out <- data.frame(
    date = unique_dates,
    observed = panel_mat[, treated_unit],
    synthetic = synthetic_path
  )
  out$effect <- out$observed - out$synthetic

  if (verbose) {
    nz <- sum(weights > 1e-4)
    message(sprintf("SCM Fit: %d donors, %d non-zero weights. Pre-period N=%d.",
      length(donors), nz, sum(complete_res_mask)))
  }

  return(list(synthetic = out, weights = weights, alpha = alpha_map))
}


#' Machine Learning Synthetic Control (ML-SCM)
#'
#' \code{nm_mlscm} estimates counterfactual outcomes using a machine learning
#' backend. It pivots the panel to wide format (donors as features), trains a
#' model on the pre-treatment period, and extrapolates to estimate the
#' counterfactual.
#'
#' @param df Long-format panel data.
#' @param date_col Name of the date column.
#' @param unit_col Name of the unit identifier column.
#' @param outcome_col Name of the outcome variable.
#' @param treated_unit Name of the treated unit.
#' @param cutoff_date Date string or object marking the intervention point.
#' @param donors Character vector of donor units.
#' @param backend ML backend to use (default "lightgbm").
#' @param model_config List of backend-specific model configuration parameters (e.g., `nfold`, `algorithm`).
#' @param split_method Data splitting method for validation ("random", "time", etc.).
#' @param fraction Fraction of pre-treatment data used for training (default 1.0).
#' @param seed Random seed for reproducibility.
#' @param n_cores Number of CPU cores for H2O. If NULL, connects to an existing cluster or detects cores automatically.
#' @param max_mem_size Maximum memory for H2O (e.g., "16G").
#' @param verbose Whether to print progress messages.
#'
#' @return A data frame with columns: `date`, `observed`, `synthetic`, and `effect`.
#'
#' @note **Exploratory use only.** ML-SCM lacks the causal guarantees of
#'   classic SCM (Abadie 2010). Key limitations: (1) ML models can overfit
#'   the pre-treatment period when the number of donors approaches the
#'   pre-period length, inflating post-treatment fit and biasing effect
#'   estimates; (2) the RMSPE ratio placebo test is unreliable with ML-SCM
#'   because near-perfect pre-period fit deflates the denominator; (3) no
#'   interpretable donor weights are produced. For inferential conclusions
#'   prefer \code{nm_scm} (lasso), \code{nm_scm_abadie} (QP), \code{nm_scm_mcnnm},
#'   or \code{nm_bayesian_scm}.
#' @export
nm_mlscm <- function(df,
                     date_col,
                     unit_col,
                     outcome_col,
                     treated_unit,
                     cutoff_date,
                     donors,
                     backend = "lightgbm",
                     model_config = NULL,
                     split_method = "random",
                     fraction = 1.0,
                     seed = 7654321,
                     n_cores = NULL,
                     max_mem_size = NULL,
                     verbose = TRUE) {

  log <- nm_get_logger("causal.scm.ml")

  nm_warn_experimental(paste0(
    "nm_mlscm() is experimental and lacks the causal guarantees of classic SCM. ",
    "Prefer nm_scm(), nm_scm_abadie(), nm_scm_mcnnm(), or nm_bayesian_scm() for ",
    "inferential conclusions. See ?nm_mlscm Notes for details."
  ))

  # --- 0. Initialize Backend (Resource Management) ---
  if (backend == "h2o") {
    nm_init_h2o(n_cores = n_cores, max_mem_size = max_mem_size, verbose = verbose)
  }

  # --- 1. Validate Inputs ---
  if (missing(df) || missing(date_col) || missing(outcome_col) || missing(unit_col) ||
    missing(treated_unit) || missing(donors) || missing(cutoff_date)) {
    stop("Missing required arguments for nm_mlscm.")
  }

  df[[date_col]] <- as.Date(df[[date_col]])
  cutoff_ts <- as.Date(cutoff_date)

  # --- 2. Filter and Reshape Panel (Base R) ---
  # Filter to relevant units
  union_units <- unique(c(donors, treated_unit))
  df_sub <- df[df[[unit_col]] %in% union_units, ]

  if (nrow(df_sub) == 0) stop("No data found for the specified treated unit and donors.")

  # Base R Pivot: Long -> Wide (Rows=Date, Cols=Unit)
  unique_dates <- sort(unique(df_sub[[date_col]]))
  unique_units <- sort(unique(df_sub[[unit_col]]))

  # Check treated unit presence
  if (!treated_unit %in% unique_units) {
    log$error("Treated unit '%s' not found in filtered data.", treated_unit)
    stop("Treated unit not found.")
  }

  # Build Matrix
  mat <- matrix(NA, nrow = length(unique_dates), ncol = length(unique_units))
  rownames(mat) <- as.character(unique_dates)
  colnames(mat) <- unique_units

  r_idx <- match(df_sub[[date_col]], unique_dates)
  c_idx <- match(df_sub[[unit_col]], unique_units)
  mat[cbind(r_idx, c_idx)] <- df_sub[[outcome_col]]

  panel <- as.data.frame(mat)
  # Add date column for later use
  panel$date <- unique_dates

  # Validate Donors in Panel
  valid_donors <- intersect(donors, colnames(panel))
  valid_donors <- setdiff(valid_donors, c("date", treated_unit))

  if (length(valid_donors) == 0) stop("No valid donors available in the panel.")

  # --- 3. Safe Column Mapping (Crucial for H2O) ---
  # H2O allows limited characters in column names. We sanitize them.
  safe_name <- function(name) {
    if (name == "date") return("date") # Preserve 'date'
    s <- gsub("[^A-Za-z0-9_]", "_", as.character(name))
    s <- gsub("_+", "_", s)
    s <- gsub("^_|_$", "", s)
    if (nchar(s) == 0) s <- "var"
    # Append prefix if starts with number
    if (grepl("^[0-9]", s)) s <- paste0("v_", s)
    return(s)
  }

  original_cols <- colnames(panel)
  # Map treated unit and donors to safe names
  safe_cols <- sapply(original_cols, safe_name)
  # Ensure uniqueness
  safe_cols <- make.unique(safe_cols, sep = "_")
  col_map <- setNames(safe_cols, original_cols)

  # Apply safe names
  panel_safe <- panel
  colnames(panel_safe) <- safe_cols

  # Get safe identifiers
  treated_safe <- col_map[[treated_unit]]
  donors_safe <- col_map[valid_donors]
  date_safe <- "date" # We manually ensured this exists

  if (any(is.na(donors_safe))) stop("Error mapping donor names.")

  # --- 4. Extract Pre-treatment Data ---
  pre_mask <- panel_safe[[date_safe]] < cutoff_ts
  pre_panel_safe <- panel_safe[pre_mask, , drop = FALSE]

  if (nrow(pre_panel_safe) < 3) stop("Too few pre-treatment time points (N < 3).")

  if (is.null(model_config)) model_config <- list()

  if (verbose) {
    log$info("Training ML-SCM model | backend=%s | donors=%d | cutoff=%s",
      backend, length(donors_safe), as.character(cutoff_date))
  }

  # --- 5. Train Model ---
  # nm_build_model handles the internal H2O training logic
  build_results <- nm_build_model(
    df = pre_panel_safe,
    value = treated_safe,
    backend = backend,
    predictors = unname(donors_safe), # Donors are features
    split_method = split_method,
    fraction = fraction,
    model_config = model_config,
    seed = seed,
    verbose = verbose
  )
  model <- build_results$model

  # --- 6. Predict Full Period ---
  # Select predictors for the full period
  # Note: panel_safe contains 'date', 'treated', and 'donors'.
  # We pass the subset containing donors to the predictor.

  predictors_df <- panel_safe[, donors_safe, drop = FALSE]

  if (backend == "h2o") {
    synth_all <- nm_predict_h2o(model, predictors_df, verbose = FALSE)
  } else {
    synth_all <- nm_predict(model, predictors_df)
  }

  # --- 7. Assemble Output ---
  # Use original panel for accurate Observed values and Dates
  out <- data.frame(
    date = panel[["date"]],
    observed = panel[[treated_unit]],
    synthetic = as.numeric(synth_all)
  )
  out$effect <- out$observed - out$synthetic

  if (verbose) log$info("ML-SCM completed: %d timestamps predicted.", nrow(out))

  return(out)
}


#' Unified Synthetic Control Dispatcher
#'
#' @param df Long-format panel data.
#' @param date_col Name of date column.
#' @param unit_col Name of unit identifier column.
#' @param outcome_col Name of outcome variable.
#' @param treated_unit Name of treated unit.
#' @param cutoff_date Intervention date.
#' @param donors Optional vector of donor units.
#' @param scm_backend Either "scm" (Classic augmented SCM), "mlscm" (ML),
#'        "abadie" (classic Abadie simplex SCM), "did" (difference-in-differences),
#'        "mcnnm" (matrix completion with nuclear-norm minimisation), or
#'        "robust" (HSVT-denoised robust SCM, Amjad et al. 2018).
#' @param model_config List of model parameters (e.g. list(nfold=5)) passed to ML-SCM.
#' @param n_cores Number of CPU cores.
#' @param max_mem_size Maximum memory for H2O.
#' @param verbose Whether to print INFO log messages. Default TRUE.
#' @param ... Additional arguments passed to the backend function.
#'
#' @return A data frame with columns: date, observed, synthetic, effect.
#'
#' @examples
#' \donttest{
#' res <- nm_run_scm(
#'   df = scm, date_col = "date", unit_col = "ID", outcome_col = "NO2",
#'   treated_unit = "2+26 cities", cutoff_date = "2015-12-01",
#'   scm_backend = "scm", verbose = FALSE
#' )
#' head(res)
#' }
#'
#' @export
nm_run_scm <- function(df,
                       date_col,
                       unit_col,
                       outcome_col,
                       treated_unit,
                       cutoff_date,
                       donors = NULL,
                       scm_backend = "scm",
                       model_config = NULL,
                       n_cores = NULL,
                       max_mem_size = NULL,
                       verbose = TRUE,
                       ...) {

  log <- nm_get_logger("causal.core")

  # --- 1. Validate required columns ---
  required_cols <- c(date_col, unit_col, outcome_col)
  missing_cols <- setdiff(required_cols, colnames(df))
  if (length(missing_cols) > 0) stop("Missing required columns: ", paste(missing_cols, collapse = ", "))
  if (is.null(treated_unit) || treated_unit == "") stop("`treated_unit` must be a non-empty string.")

  # --- 2. Normalize backend string ---
  scm_backend <- tolower(scm_backend)

  # --- 3. Resolve donor pool ---
  all_units <- unique(df[[unit_col]])
  if (!(treated_unit %in% all_units)) stop("Treated unit not found in data.")

  base_pool <- if (!is.null(donors)) donors else all_units
  donor_pool <- setdiff(unique(base_pool), treated_unit)

  if (length(donor_pool) == 0) stop("No donors available after excluding treated unit.")

  # --- 4. Parse cutoff date ---
  cutoff_ts <- as.Date(cutoff_date)
  cutoff_str <- format(cutoff_ts, "%Y-%m-%d")

  # --- 5. Extract additional arguments ---
  extra_args <- list(...)

  # --- 6. Dispatch to backend ---
  if (scm_backend == "scm") {
    if (verbose) {
      log$info("Running SCM | treated=%s | donors=%d | cutoff=%s",
        treated_unit, length(donor_pool), cutoff_str)
    }

    # Classic SCM: Pass standard args + extra_args
    args_list <- c(list(
      df = df, date_col = date_col, unit_col = unit_col, outcome_col = outcome_col,
      treated_unit = treated_unit, cutoff_date = cutoff_str, donors = donor_pool,
      verbose = verbose), extra_args)

    out <- do.call(nm_scm, args_list)

    if (is.list(out) && "synthetic" %in% names(out)) return(out$synthetic)
    return(out)

  } else if (scm_backend == "mlscm") {

    backend_val <- if (!is.null(extra_args$backend)) extra_args$backend else "lightgbm"
    backend_val <- tolower(backend_val)

    if (verbose) {
      log$info("Running ML-SCM | backend=%s | treated=%s | donors=%d | cutoff=%s",
        backend_val, treated_unit, length(donor_pool), cutoff_str)
    }

    # Remove backend from extra_args to avoid duplicate arg error
    extra_args$backend <- NULL

    args_list <- c(list(
      df = df, date_col = date_col, unit_col = unit_col, outcome_col = outcome_col,
      treated_unit = treated_unit, cutoff_date = cutoff_str, donors = donor_pool,
      backend = backend_val,
      model_config = model_config,
      n_cores = n_cores,
      max_mem_size = max_mem_size,
      verbose = verbose), extra_args)

    # nm_mlscm() warns on every call that it's experimental, but nm_run_scm()
    # fans it out repeatedly (placebo/bootstrap/batch runs); suppress the
    # repeat noise here while leaving direct nm_mlscm() calls to warn.
    return(withCallingHandlers(
      do.call(nm_mlscm, args_list),
      nm_experimental_warning = function(w) invokeRestart("muffleWarning")
    ))
  }

  # --- Variant backends (Abadie, DiD, MC-NNM, Robust) ---
  if (scm_backend %in% c("abadie", "did", "mcnnm", "robust")) {
    fn <- switch(scm_backend,
      abadie = nm_scm_abadie,
      did = nm_did_baseline,
      mcnnm = nm_scm_mcnnm,
      robust = nm_scm_robust
    )
    if (verbose) {
      log$info("Running SCM | backend=%s | treated=%s | donors=%d | cutoff=%s",
        scm_backend, treated_unit, length(donor_pool), cutoff_str)
    }
    args_list <- c(list(
      df = df, date_col = date_col, unit_col = unit_col, outcome_col = outcome_col,
      treated_unit = treated_unit, cutoff_date = cutoff_str, donors = donor_pool,
      verbose = verbose), extra_args)

    out <- do.call(fn, args_list)
    if (is.list(out) && "synthetic" %in% names(out)) return(out$synthetic)
    return(out)
  }

  stop("Unsupported scm_backend: ", scm_backend, ". Use 'scm', 'mlscm', 'abadie', 'did', 'mcnnm', or 'robust'.")
}


#' Internal helper to run SCM safely with retries and parameter merging
#'
#' @description
#' Wraps `nm_run_scm` to handle argument sanitization (preventing duplicate
#' argument errors) and provides "self-healing" capabilities for H2O
#' connection failures.
#'
#' @param base_args A list of mandatory arguments defined by the caller.
#' @param extra_args A list of optional arguments captured from `...`.
#' @param scm_backend String, "scm" or "mlscm".
#' @param verbose Logical, whether to print internal logs.
#'
#' @return The result of `nm_run_scm` or throws an error.
#' @noRd
internal_safe_run_scm <- function(base_args, extra_args, scm_backend, verbose = FALSE) {
  # 1. Intelligent Argument Merging
  # 'base_args' (explicit internal values) take precedence over 'extra_args' (user input).
  # This prevents "formal argument matched by multiple actual arguments" errors.
  final_args <- utils::modifyList(extra_args, base_args)

  # 2. Extract configuration for local logic (Resource & Backend)
  # We need these to know HOW to restart H2O if it crashes.
  backend <- if ("backend" %in% names(final_args)) final_args$backend else "lightgbm"

  # Extract top-level resource arguments directly from final_args
  # Do not look inside model_config anymore.
  n_cores_val <- if ("n_cores" %in% names(final_args)) final_args$n_cores else NULL
  max_mem_val <- if ("max_mem_size" %in% names(final_args)) final_args$max_mem_size else NULL

  # 3. Define Restart Logic for H2O
  restart_h2o <- function() {
    if (verbose) message(" >> [System] H2O Unstable. Restarting...")

    # Use robust shutdown helper
    try(nm_stop_h2o(quiet = TRUE), silent = TRUE)

    # Wait for ports to release
    Sys.sleep(2)

    # Restart with the EXACT resources requested by the user
    # If NULL, nm_init_h2o handles the defaults logic automatically.
    nm_init_h2o(
      n_cores = n_cores_val,
      max_mem_size = max_mem_val,
      verbose = FALSE
    )

    try(h2o::h2o.no_progress(), silent = TRUE)
  }

  # 4. Execution Loop with Retries
  max_retries <- 3

  for (k in 1:max_retries) {
    tryCatch(
      {
        # Execute the core SCM function
        # do.call passes the merged list as arguments
        return(do.call(nm_run_scm, final_args))

      },
      error = function(e) {
        msg <- e$message

        # Check if the error is related to H2O connectivity
        # Common patterns for Java/HTTP failures
        is_h2o_issue <- grepl("H2O|connection|http|server|curl|java|54321", msg, ignore.case = TRUE)

        # Only relevant if we are actually using H2O backend
        using_h2o <- (tolower(scm_backend) == "mlscm") && (tolower(backend) == "h2o")

        # Self-Healing Logic: Only retry if it's an infrastructure glitch, not a logic error
        if (using_h2o && is_h2o_issue && k < max_retries) {
          if (verbose) message(sprintf(" !! H2O glitch (Attempt %d/%d). Rebooting...", k, max_retries))
          restart_h2o()
          Sys.sleep(1) # Allow JVM to warm up
        } else {
          # If it's a data error, logical error, or we ran out of retries -> Fail hard.
          stop(e)
        }
      })
  }

  stop("Unexpected execution path in internal_safe_run_scm")
}


#' Run Synthetic Control for Many Treated Units (Batch Processing)
#'
#' @description
#' Iterates through all units in the panel, treating each one as the "treated unit"
#' in turn (using the others as donors), and runs the Synthetic Control Method.
#'
#' @details
#' **H2O Lifecycle Management (for ML-SCM):**
#' This function employs a "Smart Lifecycle":
#' 1. If an H2O cluster is already active, it reuses it and leaves it running after completion.
#' 2. If no cluster is active, it starts a new one and shuts it down after completion.
#' 3. You can override this behavior using the \code{shutdown_on_exit} parameter.
#'
#' @param df A long-format panel data frame.
#' @param date_col The name of the date column.
#' @param outcome_col The name of the outcome variable column.
#' @param unit_col The name of the column containing unit identifiers.
#' @param donors Optional character vector specifying the global donor pool.
#'               If NULL, all other units are used as donors for each iteration.
#' @param cutoff_date The treatment cutoff date in "YYYY-MM-DD" format.
#' @param scm_backend The synthetic control method to use: "scm" or "mlscm".
#' @param model_config List of model parameters passed to the backend (e.g. list(nfold=5)).
#' @param n_cores Number of CPU cores.
#' @param max_mem_size Maximum memory for H2O (only used if backend="mlscm").
#' @param verbose Logical; whether to print INFO/WARN log messages.
#' @param shutdown_on_exit Logical; if TRUE, shuts down H2O after completion.
#'        If NULL (default), it auto-detects: TRUE if we started the cluster, FALSE if we reused one.
#' @param ... Additional arguments passed to `nm_run_scm`.
#'
#' @return A single, long-format data frame containing the combined results for all units.
#' @export
nm_scm_all <- function(df,
                       date_col,
                       outcome_col,
                       unit_col,
                       donors = NULL,
                       cutoff_date,
                       scm_backend = "scm",
                       model_config = NULL,
                       n_cores = NULL,
                       max_mem_size = NULL,
                       verbose = TRUE,
                       shutdown_on_exit = NULL, # Default NULL = Auto-detect
                       ...) {

  log <- nm_get_logger("causal.scm.all")

  # --- 0. Setup ---
  scm_backend <- tolower(scm_backend)
  units <- sort(unique(df[[unit_col]]))
  dots <- list(...)

  cleanup_every <- if ("cleanup_every" %in% names(dots)) dots$cleanup_every else 10

  # Default cores if not specified
  if (is.null(n_cores)) {
    is_r_check <- Sys.getenv("_R_CHECK_LIMIT_CORES_", "") != ""
    if (is_r_check) {
      n_cores <- 2
    } else {
      detected <- parallel::detectCores(logical = FALSE) - 1
      if (is.na(detected) || length(detected) == 0) {
        detected <- parallel::detectCores(logical = TRUE) - 1
      }
      n_cores <- max(1, detected)
    }
  }
  # Always cap at 2 if we are under R CMD check
  if (Sys.getenv("_R_CHECK_LIMIT_CORES_", "") != "") {
    n_cores <- min(n_cores, 2)
  }
  n_cores <- max(1, n_cores)

  # --- 1. Execution Branch ---

  # === A. Classic SCM (Parallel R) ===
  if (scm_backend == "scm") {

    if (verbose) log$info("Running Classic SCM on %d units using %d parallel cores.", length(units), n_cores)

    # Initialize Parallel Cluster
    cl <- parallel::makeCluster(n_cores)
    .nm_propagate_libpaths(cl)
    doSNOW::registerDoSNOW(cl)
    on.exit(parallel::stopCluster(cl), add = TRUE)

    # Progress Bar configuration for foreach
    opts <- list()
    if (requireNamespace("progress", quietly = TRUE)) {
      pb <- progress::progress_bar$new(total = length(units), format = "  SCM-all [:bar] :percent :eta", width = 60)
      opts <- list(progress = function(n) pb$tick())
    }

    results <- foreach::foreach(
      code = units,
      .packages = c("glmnet", "quadprog", "stats"), # Reduced package dependency
      .export = c("nm_run_scm", "nm_scm"),
      .options.snow = opts
    ) %dopar% {
      tryCatch(
        {
          # Construct arguments
          base_args <- list(
            df = df, date_col = date_col, outcome_col = outcome_col,
            unit_col = unit_col, treated_unit = code,
            cutoff_date = cutoff_date, donors = donors,
            scm_backend = "scm",
            verbose = FALSE,
            model_config = model_config
          )

          final_args <- utils::modifyList(dots, base_args)
          syn <- do.call(nm_run_scm, final_args)

          # Post-process result (Base R)
          syn[[unit_col]] <- code

          # Rename 'date' back to original date column name if different
          if (date_col != "date") {
            names(syn)[names(syn) == "date"] <- date_col
          }

          return(syn)
        },
        error = function(e) return(NULL))
    }

    # === B. ML-SCM / H2O (Serial Loop, Auto-Recovery, Smart Lifecycle) ===
  } else if (scm_backend == "mlscm") {

    if (verbose) log$info("Running ML-SCM on %d units via H2O.", length(units))

    # --- 1. Smart Initialization Strategy ---
    # Check if H2O is ALREADY running
    h2o_was_running <- tryCatch(h2o::h2o.clusterIsUp(), error = function(e) FALSE)

    # Determine exit strategy
    if (is.null(shutdown_on_exit)) {
      # If it was running, keep it running. If we start it, shut it down.
      shutdown_on_exit <- !h2o_was_running
    }

    # Initialize if needed
    if (h2o_was_running) {
      if (verbose) log$info("Active H2O cluster detected. Reusing existing connection.")
    } else {
      if (verbose) log$info("No active H2O cluster. Initializing new instance (Cores: %s)...", n_cores)
      nm_init_h2o(n_cores = n_cores, max_mem_size = max_mem_size, verbose = verbose)
    }

    # Register Smart Exit Hook
    if (shutdown_on_exit) {
      on.exit(
        {
          if (verbose) log$info("Shutting down H2O cluster (shutdown_on_exit=TRUE)...")
          try(nm_stop_h2o(quiet = TRUE), silent = TRUE)
        },
        add = TRUE)
    } else {
      if (verbose) log$info("H2O cluster kept alive for future runs (shutdown_on_exit=FALSE).")
    }

    h2o::h2o.no_progress()

    # --- 2. Loop Execution ---
    if (!requireNamespace("progress", quietly = TRUE)) stop("Package 'progress' is required.")
    pb <- progress::progress_bar$new(total = length(units), format = "  SCM-all [:bar] :percent :eta", width = 60)

    results <- list()
    counter <- 0

    for (u in units) {
      pb$tick()

      # [Robustness] Check H2O status & Auto-Recover
      if (!h2o::h2o.clusterIsUp()) {
        if (verbose) log$warn("H2O crashed. Restarting...")
        try(nm_init_h2o(n_cores = n_cores, max_mem_size = max_mem_size, verbose = FALSE), silent = TRUE)
        h2o::h2o.no_progress()
      }

      # Base Args
      base_args <- list(
        df = df, date_col = date_col, outcome_col = outcome_col,
        unit_col = unit_col, treated_unit = u,
        cutoff_date = cutoff_date, donors = donors,
        scm_backend = "mlscm",
        n_cores = NULL,      # Force internal to reuse existing cluster
        max_mem_size = NULL, # Force internal to reuse existing cluster
        model_config = model_config,
        verbose = FALSE
      )

      tryCatch(
        {
          syn <- internal_safe_run_scm(base_args, dots, scm_backend, verbose = FALSE)

          # Base R post-processing
          syn[[unit_col]] <- u
          if (date_col != "date") {
            names(syn)[names(syn) == "date"] <- date_col
          }

          results[[length(results) + 1]] <- syn

        },
        error = function(e) {
          msg <- e$message
          # [Robustness] Handle H2O Crashes
          if (grepl("connect", msg, ignore.case = TRUE) || grepl("empty reply", msg, ignore.case = TRUE)) {
            if (verbose) log$warn("H2O crashed on unit %s. Restarting...", u)
            # Kill zombie process to ensure fresh start next loop
            try(h2o::h2o.shutdown(prompt = FALSE), silent = TRUE)
          } else {
            if (verbose) log$warn("Skipping unit %s: %s", u, msg)
          }
        })

      counter <- counter + 1
      if (counter %% cleanup_every == 0) {
        if (h2o::h2o.clusterIsUp()) {
          try(
            {
              h2o::h2o.removeAll()
              gc(verbose = FALSE)
            },
            silent = TRUE)
        }
      }
    }

  } else {
    stop("Unsupported scm_backend: ", scm_backend)
  }

  # --- Final Aggregation (Base R) ---
  results <- Filter(Negate(is.null), results)
  if (length(results) == 0) stop("All synthetic control runs failed.")

  # Combine all results into one dataframe
  return(do.call(rbind, results))
}
