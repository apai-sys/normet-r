#' Perform All Steps for Meteorological Normalisation
#'
#' @description
#' `nm_do_all` is a high-level convenience pipeline that:
#' \enumerate{
#'   \item Initializes the computing cluster (H2O) with specific resources.
#'   \item Prepares the data and trains a model (`nm_build_model`).
#'   \item Runs the normalisation process (`nm_normalise`).
#' }
#'
#' @param df The raw input data frame.
#' @param target The target variable name as a string (default 'value').
#' @param backend The modeling backend to use for training: 'lightgbm' (default) or 'h2o'.
#' @param covariates The names of the features used for **training**.
#' @param resample_vars Character vector of variables to resample (shuffle) during normalisation.
#'        If NULL, defaults to all covariates except time variables.
#' @param resample_df External resampling pool. If NULL, `df` is used as the source pool.
#' @param n_samples Number of resampling iterations for normalisation.
#' @param aggregate Logical. If TRUE, returns aggregated means; if FALSE, returns raw rows.
#' @param seed A random seed for reproducibility.
#' @param split_method Method for splitting data for model training (e.g., 'random').
#' @param train_fraction Proportion of data used for training (default 0.75).
#' @param model_config A list of configuration parameters passed to the model training function.
#' @param n_cores Number of CPU cores to use for **H2O cluster initialization**.
#' @param max_mem_size Maximum memory for H2O (e.g., "16G"). If NULL, auto-detected.
#' @param memory_save Logical. If TRUE, enables memory-efficient processing (batching/GC).
#' @param verbose Logical. Should the function print progress messages?
#' @param cache_dir Character. Directory for on-disk result caching. If NULL (default),
#'        caching is disabled. When set, a hit on a matching cache key skips training
#'        and normalisation entirely.
#' @param ... Additional arguments passed to underlying functions (e.g. `output_dir`).
#'
#' @return A list containing:
#' \describe{
#'   \item{res}{The normalised data frame.}
#'   \item{model}{The trained model object.}
#'   \item{df_prep}{The prepared data frame used for training.}
#' }
#'
#' @examples
#' \donttest{
#' if (requireNamespace("lightgbm", quietly = TRUE)) {
#'   covariates <- c("ws", "wd", "temp", "RH", "blh", "ssrd")
#'   predictors <- c(covariates, "date_unix", "day_julian", "weekday", "hour")
#'   result <- nm_do_all(
#'     my1[1:150, c("date", "NO2", covariates)],
#'     target = "NO2", covariates = predictors,
#'     model_config = list(n_trials = 1, cv_folds = 2, nrounds = 15,
#'                          num_leaves_min = 5, num_leaves_max = 15),
#'     n_samples = 5, seed = 42, n_cores = 1, memory_save = FALSE, verbose = FALSE
#'   )
#'   names(result)
#'   head(result$res)
#' }
#' }
#'
#' @export
nm_do_all <- function(df = NULL, target = "value", backend = "lightgbm", covariates = NULL,
                      resample_vars = NULL, resample_df = NULL, n_samples = 300,
                      aggregate = TRUE, seed = 7654321,
                      split_method = "random", train_fraction = 0.75,
                      model_config = NULL, n_cores = NULL,
                      max_mem_size = NULL,
                      memory_save = TRUE, verbose = TRUE,
                      cache_dir = NULL, ...) {
  log <- nm_get_logger("workflow.do_all")
  start_time <- Sys.time()

  if (verbose) {
    log$info("Starting pipeline | backend=%s | target=%s | n_samples=%d", backend, target, n_samples)
  }

  # --- 0. Cache check ---
  cache_key <- NULL
  if (!is.null(cache_dir)) {
    cache_key <- nm_config_hash(
      nm_dataframe_hash(df, include_index = FALSE),
      target, backend, covariates, resample_vars, n_samples,
      aggregate, seed, split_method, train_fraction, model_config
    )
    cached <- nm_cache_load(cache_dir, cache_key)
    if (!is.null(cached)) {
      if (verbose) log$info("Cache hit (%s). Returning cached result.", cache_key)
      return(cached)
    }
    if (verbose) log$info("Cache miss. Running pipeline...")
  }

  # --- 1. Initialize Backend ---
  if (backend == "h2o") {
    nm_init_h2o(n_cores = n_cores, max_mem_size = max_mem_size, verbose = verbose)
  }

  # --- 2) & 3) Prepare data and Train model ---
  build_results <- nm_build_model(
    df = df,
    target = target,
    backend = backend,
    covariates = covariates,
    split_method = split_method,
    train_fraction = train_fraction,
    model_config = model_config,
    seed = seed,
    verbose = verbose
  )

  df_prep <- build_results$df_prep
  model <- build_results$model

  # --- 4) Normalise ---
  res <- nm_normalise(
    df = df_prep,
    model = model,
    resample_vars = resample_vars,
    resample_df = resample_df,
    n_samples = n_samples,
    aggregate = aggregate,
    seed = seed,
    memory_save = memory_save,
    verbose = verbose,
    ...
  )

  if (verbose) {
    duration <- difftime(Sys.time(), start_time, units = "secs")
    log$info("Pipeline finished in %.1f seconds.", as.numeric(duration))
  }

  result <- list(res = res, model = model, df_prep = df_prep)

  # --- 5) Write cache ---
  if (!is.null(cache_dir) && !is.null(cache_key)) {
    nm_cache_save(cache_dir, cache_key, result)
    if (verbose) log$info("Result cached to '%s'.", cache_dir)
  }

  return(result)
}



#' Perform Normalisation with Uncertainty Estimation (Ensemble)
#'
#' @description
#' `nm_do_all_unc` runs a robust uncertainty estimation pipeline by training multiple models
#' (Ensemble Learning) with different random seeds. It aggregates their predictions to provide
#' confidence intervals and a performance-weighted consensus prediction.
#'
#' @details
#' The function performs the following steps:
#' \enumerate{
#'   \item **Ensemble Training**: Trains `n_models` independent models using different random seeds.
#'   \item **Normalisation**: Each model produces its own weather-normalised trend.
#'   \item **Aggregation**: Calculates the Mean, Median, Standard Deviation, and Confidence Intervals (e.g., 95%) across all models.
#'   \item **Weighted Consensus**: Calculates a weighted average trend based on model performance (R2 or RMSE) on the test set.
#' }
#'
#' @param df The raw input data frame.
#' @param target The target variable name as a string (default 'value').
#' @param backend The modeling backend to use (default 'lightgbm', or 'h2o').
#' @param covariates Character vector of features used for **training**.
#' @param resample_vars Character vector of variables to resample during normalisation.
#' @param resample_df External resampling pool.
#' @param n_samples Number of resampling iterations per model for normalisation.
#' @param n_models Number of models to train for the ensemble (default 5).
#' @param memory_save Logical. If TRUE, enables aggressive memory management.
#' @param confidence_level The confidence level for uncertainty bands (default 0.95).
#' @param weighted_method Metric for model weighting: "r2" (default) or "rmse".
#' @param seed Base random seed for reproducibility.
#' @param split_method Method for splitting data (e.g., 'random').
#' @param train_fraction Proportion of data used for training (default 0.75).
#' @param model_config List of configuration parameters for `nm_build_model`.
#' @param n_cores Number of CPU cores to use for **H2O Initialization**.
#' @param max_mem_size Maximum memory for H2O (e.g., "16G"). If NULL, auto-detected.
#' @param verbose Logical. Print progress?
#' @param cleanup_every Integer. How often (in iterations) to clear H2O memory.
#'
#' @return A list containing:
#' \describe{
#'   \item{res}{A data frame with the `observed`, `mean` normalised prediction, `weighted` prediction, and uncertainty bands (`lower_bound`, `upper_bound`).}
#'   \item{mod_stats}{A summary table of performance metrics (R2, RMSE) for all trained models.}
#' }
#'
#' @importFrom dplyr rename_with bind_cols bind_rows filter left_join
#' @importFrom progress progress_bar
#' @export
nm_do_all_unc <- function(df = NULL, target = "value", backend = "lightgbm", covariates = NULL,
                          resample_vars = NULL, resample_df = NULL, n_samples = 300, n_models = 5,
                          memory_save = TRUE, confidence_level = 0.95, weighted_method = "r2", seed = 7654321,
                          split_method = "random", train_fraction = 0.75, model_config = NULL,
                          n_cores = NULL, max_mem_size = NULL, verbose = TRUE, cleanup_every = 5) {

  log <- nm_get_logger("workflow.do_all_unc")

  # ... (Validations and Setup remain the same) ...
  if (!weighted_method %in% c("r2", "rmse")) stop("`weighted_method` must be 'r2' or 'rmse'.")

  set.seed(seed)
  seeds <- sample(1:1000000, n_models, replace = FALSE)

  if (backend == "h2o") {
    nm_require("h2o", hint = "install.packages('h2o')")
    h2o::h2o.no_progress()
    tryCatch(
      {
        nm_init_h2o(n_cores = n_cores, max_mem_size = max_mem_size, verbose = verbose)
      },
      error = function(e) stop("Failed to initialize H2O: ", e$message))
  }

  # Helper: run one nm_do_all iteration, return named list or NULL on error
  .run_one <- function(current_seed) {
    tryCatch(
      nm_do_all(
        df = df, target = target, backend = backend, covariates = covariates,
        resample_vars = resample_vars, split_method = split_method, train_fraction = train_fraction,
        model_config = model_config, n_samples = n_samples, seed = current_seed,
        n_cores = NULL, resample_df = resample_df,
        memory_save = memory_save, verbose = FALSE, aggregate = TRUE
      ),
      error = function(e) NULL
    )
  }

  if (verbose) log$info("Starting ensemble run with %d models...", n_models)

  if (backend == "lightgbm") {
    # Fork-parallel for lightgbm: each worker is fully independent.
    # Falls back to serial on Windows (mc.cores is ignored there).
    sys_cores <- parallel::detectCores(logical = FALSE)
    if (is.na(sys_cores)) sys_cores <- parallel::detectCores(logical = TRUE)
    mc_cores <- max(1L, min(n_models, sys_cores - 1L))
    if (verbose) log$info("lightgbm ensemble: running %d models in parallel (%d cores).", n_models, mc_cores)

    raw_results <- parallel::mclapply(seeds, .run_one, mc.cores = mc_cores)

  } else {
    # H2O must be sequential: single shared cluster
    sys_cores <- parallel::detectCores(logical = FALSE)
    if (is.na(sys_cores)) sys_cores <- parallel::detectCores(logical = TRUE)
    n_r_workers <- max(1, min(2, sys_cores - 1))
    if (verbose) log$info("H2O ensemble: sequential, R resampling restricted to %d core(s).", n_r_workers)

    cl <- parallel::makeCluster(n_r_workers)
    on.exit(parallel::stopCluster(cl), add = TRUE)

    raw_results <- vector("list", n_models)
    pb_h2o <- if (verbose) progress::progress_bar$new(
      format = "  Ensemble Training [:bar] :percent | Model :current/:total | ETA: :eta",
      total = n_models, clear = FALSE, width = 80) else NULL

    for (i in seq_along(seeds)) {
      if (backend == "h2o" && !h2o::h2o.clusterIsUp()) {
        log$warn("H2O cluster down before model %d. Restarting...", i)
        try(nm_stop_h2o(quiet = TRUE), silent = TRUE)
        Sys.sleep(2)
        nm_init_h2o(n_cores = n_cores, max_mem_size = max_mem_size, verbose = FALSE)
      }
      raw_results[[i]] <- .run_one(seeds[i])
      if (!is.null(pb_h2o)) pb_h2o$tick()
      if (i %% cleanup_every == 0) { h2o::h2o.removeAll(); gc(verbose = FALSE) }
    }
    h2o::h2o.removeAll()
    gc(verbose = FALSE)
  }

  # Assemble results
  series_list <- list()
  stats_list  <- list()
  observed_ref <- NULL

  for (i in seq_along(seeds)) {
    current_seed <- seeds[i]
    res_i <- raw_results[[i]]

    if (is.null(res_i) || is.null(res_i$res)) {
      log$warn("Model iteration %d (Seed %d) returned no results. Skipping.", i, current_seed)
      next
    }
    out_i <- res_i$res
    if (!"normalised" %in% colnames(out_i)) {
      log$warn("Model iteration %d missing 'normalised' column. Skipping.", i)
      next
    }
    if (is.null(observed_ref) && "observed" %in% colnames(out_i)) {
      observed_ref <- out_i[, "observed", drop = FALSE]
    }
    series_list[[length(series_list) + 1]] <- stats::setNames(
      out_i[, "normalised", drop = FALSE],
      paste0("normalised_", current_seed)
    )
    tryCatch({
      if (exists("nm_modStats")) {
        stats_i <- nm_modStats(df = res_i$df_prep, model = res_i$model)
        stats_i$seed <- current_seed
        stats_list[[length(stats_list) + 1]] <- stats_i
      }
    }, error = function(e) log$warn("Failed to compute metrics: %s", e$message))
  }

  series_list <- Filter(Negate(is.null), series_list)
  stats_list <- Filter(Negate(is.null), stats_list)

  if (length(series_list) == 0 || is.null(observed_ref)) {
    log$error("Ensemble failed: All %d models failed.", n_models)
    stop("Ensemble execution failed: No outputs generated.")
  }

  out <- cbind(observed_ref, dplyr::bind_cols(series_list))
  mod_stats <- if (length(stats_list) > 0) dplyr::bind_rows(stats_list) else data.frame()

  pred_cols <- grep("^normalised_", colnames(out), value = TRUE)
  P <- out[, pred_cols, drop = FALSE]

  out$mean   <- rowMeans(P, na.rm = TRUE)
  out$std    <- apply(P, 1, sd, na.rm = TRUE)
  out$median <- apply(P, 1, median, na.rm = TRUE)

  alpha <- (1.0 - confidence_level) / 2.0
  out$lower_bound <- apply(P, 1, quantile, probs = alpha, na.rm = TRUE)
  out$upper_bound <- apply(P, 1, quantile, probs = 1.0 - alpha, na.rm = TRUE)

  w <- rep(1.0 / length(pred_cols), length(pred_cols))

  if (nrow(mod_stats) > 0) {
    testing_stats <- mod_stats %>% dplyr::filter(set == "testing")
    if (nrow(testing_stats) > 0) {
      if (weighted_method == "r2") {
        scores <- sapply(testing_stats$R2, function(x) max(as.numeric(x), 0.0))
      } else {
        eps <- 1e-9
        scores <- sapply(testing_stats$RMSE, function(x) 1.0 / (as.numeric(x) + eps))
      }
      score_sum <- sum(scores, na.rm = TRUE)
      if (!is.na(score_sum) && score_sum > 0) {
        w <- scores / score_sum
      }
    }
  }

  if (ncol(P) > 0 && length(w) == ncol(P)) {
    out$weighted <- as.numeric(as.matrix(P) %*% w)
  } else {
    out$weighted <- out$mean
  }

  if (nrow(mod_stats) > 0 && length(w) == nrow(mod_stats)) {
    mod_stats$weight <- w
  }

  return(list(res = out, mod_stats = mod_stats))
}
