#' Placebo-in-Space Test for Synthetic Control
#'
#' @description
#' Runs placebo-in-space tests by iteratively treating each donor unit as if it
#' were the treated unit. This is used to calculate p-values for causal inference
#' by comparing the observed effect to the distribution of placebo effects.
#'
#' @details
#' **Resource Management:**
#' If using `mlscm` (H2O), the cluster is initialized **once** globally at the start.
#' The internal SCM runs attach to this existing cluster (by passing `n_cores=NULL`),
#' ensuring the connection remains active throughout the loop. The cluster is
#' shut down automatically when the function exits.
#'
#' @param df A long-format panel data frame.
#' @param date_col Name of the date column.
#' @param unit_col Name of the unit identifier column.
#' @param outcome_col Name of the outcome variable column.
#' @param treated_unit The identifier for the treated unit.
#' @param cutoff_date The intervention cutoff date (string or Date).
#' @param donors Optional vector of donor units. If NULL, uses all non-treated units.
#' @param scm_backend The backend to use: \code{"scm"} or \code{"mlscm"}.
#' @param model_config List of model parameters passed to the backend.
#' @param post_agg Method to aggregate post-treatment effects: \code{"mean"} or \code{"sum"}.
#' @param n_cores Number of CPU cores. For \code{scm_backend = "scm"}, donor
#'        placebo runs are dispatched in parallel via \pkg{foreach}/\pkg{doSNOW}
#'        using this many workers (default: detected cores minus one). For
#'        \code{"mlscm"}, this instead sets the H2O cluster size and donors
#'        are run sequentially (an H2O cluster isn't safely shared across
#'        separate worker processes).
#' @param max_mem_size Maximum memory for H2O (e.g., "16G").
#' @param verbose Logical; whether to print log messages.
#' @param ... Additional arguments passed to the internal SCM runner.
#'
#' @return A list containing:
#' \describe{
#'   \item{treated}{Data frame of the effect for the actual treated unit.}
#'   \item{placebos}{List of data frames for each placebo run.}
#'   \item{p_value}{The calculated two-sided p-value.}
#'   \item{ref_band}{Data frame containing aggregated quantiles (confidence bands) of the placebos.}
#' }
#' @export
nm_placebo_in_space <- function(df, date_col, unit_col, outcome_col,
                                treated_unit, cutoff_date, donors = NULL,
                                scm_backend = "scm",
                                model_config = NULL,
                                post_agg = "mean",
                                n_cores = NULL,
                                max_mem_size = NULL,
                                verbose = TRUE, ...) {
  # --- 0. Environment Setup ---
  log <- nm_get_logger("causal.placebo.space")
  scm_backend <- tolower(scm_backend)
  cutoff_ts <- as.Date(cutoff_date)

  # Validate Aggregation Method
  post_agg <- tolower(post_agg)
  if (!post_agg %in% c("mean", "sum")) {
    log$warn("Invalid post_agg='%s'; falling back to 'mean'.", post_agg)
    post_agg <- "mean"
  }

  # --- 1. Resource Initialization (Global) ---
  # Initialize H2O once here. Internal calls will attach to this instance.
  if (scm_backend == "mlscm") {
    nc_log <- if (is.null(n_cores)) "Auto" else n_cores
    mem_log <- if (is.null(max_mem_size)) "Auto" else max_mem_size

    if (verbose) log$info("Initializing H2O for Placebo Tests (Cores: %s, Mem: %s)...", nc_log, mem_log)

    nm_init_h2o(n_cores = n_cores, max_mem_size = max_mem_size, verbose = verbose)
    on.exit(nm_stop_h2o(quiet = TRUE), add = TRUE) # Ensure shutdown on exit
    h2o::h2o.no_progress()
  }

  # --- 2. Basic Validation ---
  all_units <- sort(unique(df[[unit_col]]))
  if (!(treated_unit %in% all_units)) {
    stop("treated_unit must be a valid unit identifier.")
  }

  # Define Donor Pool
  valid_donors <- if (is.null(donors)) {
    setdiff(all_units, treated_unit)
  } else {
    intersect(donors, setdiff(all_units, treated_unit))
  }

  if (length(valid_donors) == 0) {
    log$warn("No donor units available for placebo-in-space.")
    return(list(treated = NULL, placebos = list(), p_value = NA_real_, ref_band = NULL))
  }

  # --- 3. Run SCM for the TRUE Treated Unit ---
  if (verbose) log$info("Step 1/2: Running SCM for TRUE treated unit: %s", treated_unit)

  # Construct base arguments
  base_args_true <- list(
    df = df, date_col = date_col, unit_col = unit_col, outcome_col = outcome_col,
    treated_unit = treated_unit, cutoff_date = cutoff_date, donors = donors,
    scm_backend = scm_backend,
    model_config = model_config,
    n_cores = NULL,
    max_mem_size = NULL,
    verbose = FALSE
  )

  dots <- list(...)

  # Execute safely
  df_true <- tryCatch(
    {
      internal_safe_run_scm(base_args_true, dots, scm_backend, verbose = verbose)
    },
    error = function(e) {
      stop("Failed to run SCM for the treated unit: ", e$message)
    })

  # --- 4. Placebo Loop ---
  # Each donor's placebo run is independent of the others, so for the
  # classic "scm" backend (ridge regression, no shared cluster state) they
  # are dispatched in parallel via foreach/doSNOW -- the same pattern used
  # by nm_placebo_in_time() and nm_scm_all(). "mlscm" stays sequential: an
  # H2O cluster isn't safely shared across separate worker processes, and
  # the existing crash-recovery/cleanup-every logic below assumes a single
  # persistent connection.
  if (verbose) log$info("Step 2/2: Running Placebos on %d donors...", length(valid_donors))

  run_one_donor <- function(u) {
    # Exclude the TRUE treated unit from the placebo's donor pool to avoid contamination
    current_donors <- setdiff(all_units, c(u, treated_unit))

    base_args_u <- list(
      df = df, date_col = date_col, unit_col = unit_col, outcome_col = outcome_col,
      treated_unit = u, cutoff_date = cutoff_date, donors = current_donors,
      scm_backend = scm_backend,
      model_config = model_config,
      # [CRITICAL FIX]: Reuse existing cluster
      n_cores = NULL,
      max_mem_size = NULL,
      verbose = FALSE
    )

    tryCatch(
      {
        syn_u <- internal_safe_run_scm(base_args_u, dots, scm_backend, verbose = FALSE)
        res_df <- syn_u[, c("date", "effect")]
        res_df$unit <- as.character(u)
        res_df
      },
      error = function(e) NULL
    )
  }

  placebo_results_list <- list()

  # Resolve worker count for the classic SCM backend (mirrors nm_placebo_in_time / nm_scm_all)
  n_cores_eff <- n_cores
  if (is.null(n_cores_eff)) {
    if (Sys.getenv("_R_CHECK_LIMIT_CORES_", "") != "") {
      n_cores_eff <- 2
    } else {
      detected <- parallel::detectCores(logical = FALSE) - 1
      if (is.na(detected) || length(detected) == 0) {
        detected <- parallel::detectCores(logical = TRUE) - 1
      }
      n_cores_eff <- max(1, detected)
    }
  }
  if (Sys.getenv("_R_CHECK_LIMIT_CORES_", "") != "") {
    n_cores_eff <- min(n_cores_eff, 2)
  }
  n_cores_eff <- max(1, n_cores_eff)

  use_parallel <- scm_backend == "scm" && n_cores_eff > 1 && length(valid_donors) > 1 &&
    requireNamespace("foreach", quietly = TRUE) && requireNamespace("doSNOW", quietly = TRUE)

  if (use_parallel) {
    if (verbose) log$info("Running %d placebo-in-space donors using %d parallel cores.", length(valid_donors), n_cores_eff)

    cl <- parallel::makeCluster(n_cores_eff)
    .nm_propagate_libpaths(cl)
    doSNOW::registerDoSNOW(cl)
    on.exit(parallel::stopCluster(cl), add = TRUE)

    opts <- list()
    if (requireNamespace("progress", quietly = TRUE)) {
      pb <- progress::progress_bar$new(
        format = "  Placebos [:bar] :percent | :current/:total | ETA: :eta",
        total = length(valid_donors), clear = FALSE, width = 70
      )
      opts <- list(progress = function(n) pb$tick())
    }

    results <- foreach::foreach(
      u = valid_donors,
      .packages = c("glmnet", "quadprog", "stats"),
      .export = c("internal_safe_run_scm", "nm_run_scm", "nm_scm", "run_one_donor"),
      .options.snow = opts
    ) %dopar% run_one_donor(u)

    for (i in seq_along(valid_donors)) {
      if (!is.null(results[[i]])) placebo_results_list[[as.character(valid_donors[i])]] <- results[[i]]
    }
  } else {
    if (!requireNamespace("progress", quietly = TRUE)) stop("Package 'progress' is required.")
    pb <- progress::progress_bar$new(
      format = "  Placebos [:bar] :percent | :current/:total | ETA: :eta",
      total = length(valid_donors), clear = FALSE, width = 70
    )

    counter <- 0
    cleanup_every <- if ("cleanup_every" %in% names(dots)) dots$cleanup_every else 10

    for (u in valid_donors) {
      pb$tick()

      # Safety check: Restart H2O if it crashed during previous iteration
      if (scm_backend == "mlscm" && !h2o::h2o.clusterIsUp()) {
        try(nm_init_h2o(n_cores = n_cores, max_mem_size = max_mem_size, verbose = FALSE), silent = TRUE)
        h2o::h2o.no_progress()
      }

      res_df <- run_one_donor(u)
      if (!is.null(res_df)) placebo_results_list[[as.character(u)]] <- res_df

      # Periodic Cleanup to prevent Out-Of-Memory errors
      counter <- counter + 1
      if (scm_backend == "mlscm" && counter %% cleanup_every == 0) {
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
  }

  if (length(placebo_results_list) == 0) {
    log$warn("All placebo runs failed.")
    return(list(treated = df_true, placebos = list(), p_value = NA_real_, ref_band = NULL))
  }

  # --- 5. Process Results & Reference Bands (Base R Approach) ---

  # Combine list into one long dataframe
  all_placebos_long <- do.call(rbind, placebo_results_list)

  # 1. Get unique sorted keys
  unique_dates <- sort(unique(all_placebos_long$date))
  unique_units <- sort(unique(all_placebos_long$unit))

  # 2. Initialize matrix with NAs (Rows=Dates, Cols=Units)
  effect_mat <- matrix(NA, nrow = length(unique_dates), ncol = length(unique_units))
  rownames(effect_mat) <- as.character(unique_dates)
  colnames(effect_mat) <- unique_units

  # 3. Map long data to matrix coordinates
  row_idx <- match(all_placebos_long$date, unique_dates)
  col_idx <- match(all_placebos_long$unit, unique_units)

  # 4. Fill matrix directly
  effect_mat[cbind(row_idx, col_idx)] <- all_placebos_long$effect

  # Extract date vector for alignment
  date_vec <- unique_dates

  # Calculate Statistics (Quantiles for bands)
  ref_band <- data.frame(
    date = date_vec,
    p10   = apply(effect_mat, 1, quantile, 0.10, na.rm = TRUE),
    p90   = apply(effect_mat, 1, quantile, 0.90, na.rm = TRUE),
    p2_5  = apply(effect_mat, 1, quantile, 0.025, na.rm = TRUE),
    p97_5 = apply(effect_mat, 1, quantile, 0.975, na.rm = TRUE),
    mean  = rowMeans(effect_mat, na.rm = TRUE),
    std   = apply(effect_mat, 1, sd, na.rm = TRUE)
  )

  # Add 1-SD bands
  ref_band$band_low_1sd <- ref_band$mean - ref_band$std
  ref_band$band_high_1sd <- ref_band$mean + ref_band$std

  # --- 6. Compute P-Value ---
  post_mask <- df_true$date >= cutoff_ts
  agg_fun <- if (post_agg == "sum") sum else mean
  obs_stat <- agg_fun(df_true$effect[post_mask], na.rm = TRUE)

  # Match post-treatment indices
  mat_post_indices <- which(date_vec >= cutoff_ts)

  if (length(mat_post_indices) > 0) {
    # Calculate statistic for each placebo unit
    plc_stats <- apply(effect_mat[mat_post_indices, , drop = FALSE], 2, agg_fun, na.rm = TRUE)

    # Two-sided P-value calculation
    n_extreme <- sum(abs(plc_stats) >= abs(obs_stat), na.rm = TRUE)
    n_valid <- sum(!is.na(plc_stats))
    p_value <- (n_extreme + 1) / (n_valid + 1)
  } else {
    p_value <- NA_real_
  }

  return(list(
    treated = df_true,
    placebos = placebo_results_list,
    p_value = p_value,
    ref_band = ref_band
  ))
}
