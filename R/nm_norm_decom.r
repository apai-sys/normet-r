#' Decompose Time Series Influences
#'
#' @description
#' `nm_decompose` is a high-level wrapper that performs time series decomposition,
#' separating a target variable (e.g., pollutant concentration) into components
#' driven by emissions/trends and meteorology.
#'
#' @details
#' This function supports two decomposition methods:
#' \itemize{
#'   \item \strong{`emission`}: Isolates the influence of time-based features (Trend, Seasonality, Weekday, Hour).
#'     The result is a breakdown of the "emissions-driven" or "human activity" signal.
#'   \item \strong{`meteorology`}: Isolates the influence of individual meteorological features.
#'     The result is a breakdown of the "meteorology-driven" signal.
#' }
#' If a pre-trained `model` is not provided, the function will first train one.
#'
#' @param method The decomposition method to use. One of `"emission"` or `"meteorology"`.
#' @param df Data frame containing the input data.
#' @param model Optional pre-trained model. If `NULL`, a model will be trained.
#' @param value The target variable name as a string.
#' @param backend The modeling backend to use (default 'lightgbm', or 'h2o').
#' @param predictors The names of the features used for training (if model is NULL).
#' @param split_method Method for splitting data for model training (e.g., 'random').
#' @param fraction Proportion of data for training if a model is trained.
#' @param model_config A list of configuration parameters for model training.
#' @param n_samples Number of samples for the normalisation process.
#' @param seed A random seed for reproducibility.
#' @param importance_ascending Logical. If `TRUE`, sorts meteorological features by
#'        ascending importance. (Used only when `method = "meteorology"`).
#' @param n_cores Number of CPU cores to use for **H2O Initialization** (when
#'        `backend = "h2o"`) and for parallel resampling in each
#'        `nm_normalise()` call (default: detected cores minus one).
#' @param max_mem_size Maximum memory for H2O (e.g., "16G"). If NULL, auto-detected.
#' @param resample_df External resampling pool. If NULL, `df` is used.
#' @param memory_save Logical flag for memory-efficient normalisation.
#' @param verbose Should the function print progress messages and logs?
#'
#' @return A data frame with the decomposed components.
#'
#' @examples
#' \donttest{
#' if (requireNamespace("lightgbm", quietly = TRUE)) {
#'   covariates <- c("u10", "v10", "d2m", "t2m", "blh", "ssrd")
#'   predictors <- c(covariates, "date_unix", "day_julian", "weekday", "hour")
#'   build <- nm_build_model(
#'     my1[1:150, c("date", "NO2", covariates)],
#'     value = "NO2", predictors = predictors,
#'     model_config = list(n_trials = 1, cv_folds = 2, nrounds = 15,
#'                          num_leaves_min = 5, num_leaves_max = 15),
#'     seed = 42, verbose = FALSE
#'   )
#'   decomp <- nm_decompose(
#'     method = "emission", df = build$df_prep, model = build$model,
#'     predictors = predictors, n_samples = 2, n_cores = 1, verbose = FALSE
#'   )
#'   head(decomp)
#' }
#' }
#'
#' @export
nm_decompose <- function(method = "emission",
                         df = NULL,
                         model = NULL,
                         value = "value",
                         predictors = NULL,
                         backend = "lightgbm",
                         split_method = "random",
                         fraction = 0.75,
                         model_config = NULL,
                         n_samples = 300,
                         seed = 7654321,
                         importance_ascending = FALSE,
                         n_cores = NULL,
                         max_mem_size = NULL,
                         resample_df = NULL,
                         memory_save = FALSE,
                         verbose = TRUE) {
  # --- 1. Validate Common Inputs ---
  if (is.null(df) || is.null(value)) stop("`df` and `value` must be provided.")
  if (is.null(model) && is.null(predictors)) stop("Either `model` or `predictors` must be provided.")
  if (is.null(model) && is.null(backend)) stop("When training a model, `backend` must be specified.")

  # --- 2. Dispatch Based on Method ---
  if (method == "emission") {
    return(nm_decom_emi(
      df = df,
      model = model,
      value = value,
      predictors = predictors,
      backend = backend,
      split_method = split_method,
      fraction = fraction,
      model_config = model_config,
      n_samples = n_samples,
      seed = seed,
      n_cores = n_cores,
      max_mem_size = max_mem_size,
      resample_df = resample_df,
      memory_save = memory_save,
      verbose = verbose
    ))
  }

  if (method == "meteorology") {
    return(nm_decom_met(
      df = df,
      model = model,
      value = value,
      predictors = predictors,
      backend = backend,
      split_method = split_method,
      fraction = fraction,
      model_config = model_config,
      n_samples = n_samples,
      seed = seed,
      importance_ascending = importance_ascending,
      n_cores = n_cores,
      max_mem_size = max_mem_size,
      resample_df = resample_df,
      memory_save = memory_save,
      verbose = verbose
    ))
  }

  # --- 3. Unsupported Method ---
  stop(sprintf("Unsupported decomposition method: '%s'. Use 'emission' or 'meteorology'.", method))
}



#' Decompose Emissions Influences (Trend, Seasonality, Weather)
#'
#' @description
#' `nm_decom_emi` performs a "Freeze-and-Shuffle" decomposition to isolate the contributions
#' of different time components (Trend, Seasonality, Weekday, Hour) from weather variability.
#'
#' @details
#' The function works by iteratively "freezing" time components while keeping others (and weather) shuffled:
#' \enumerate{
#'   \item **Base State**: Everything (Time + Weather) is shuffled. Result: Global Mean.
#'   \item **Trend State**: `date_unix` is frozen; others shuffled. Result: Trend line.
#'   \item **Seasonal State**: `date_unix` + `day_julian` frozen. Result: Trend + Seasonality.
#'   \item **...and so on**.
#' }
#' The final differences between these states reveal the net contribution of each component.
#'
#' @param df The input data frame. Must contain a 'date' column and the target variable.
#' @param model Pre-trained model. If NULL, a new model will be trained.
#' @param value The target variable name as a string (default 'value').
#' @param predictors Character vector of features used for **training** (if model is NULL).
#' @param backend The modeling backend to use (default 'lightgbm', or 'h2o').
#' @param split_method Method for splitting data (e.g., 'random').
#' @param fraction Proportion of data used for training (default 0.75).
#' @param model_config List of configuration parameters for model training.
#' @param n_samples Number of resampling iterations per step (default 300).
#' @param seed Random seed for reproducibility.
#' @param n_cores Number of CPU cores to use for **H2O Initialization** (when
#'        `backend = "h2o"`) and for parallel resampling in each
#'        `nm_normalise()` call (default: detected cores minus one).
#' @param max_mem_size Maximum memory for H2O (e.g., "16G"). If NULL, auto-detected.
#' @param resample_df External resampling pool. **Important**: Usually the full dataset.
#'        If NULL, defaults to `df`.
#' @param memory_save Logical. Enable memory-efficient processing.
#' @param verbose Logical. Print progress messages.
#'
#' @return A data frame containing:
#' \itemize{
#'   \item `date`: Timestamp.
#'   \item `observed`: Original value.
#'   \item `emi_total`: The fully normalised value (Time Fixed, Weather Shuffled).
#'   \item `emi_base`: The global constant baseline.
#'   \item `emi_noise`: Residual noise (`base` - `emi_base`).
#'   \item Component columns: `date_unix` (Trend), `day_julian` (Seasonality), `weekday`, `hour` (if applicable).
#' }
#'
#' @export
nm_decom_emi <- function(df = NULL, model = NULL, value = "value",
                         predictors = NULL, backend = "lightgbm",
                         split_method = "random", fraction = 0.75,
                         model_config = NULL, n_samples = 300, seed = 7654321,
                         n_cores = NULL,
                         max_mem_size = NULL,
                         resample_df = NULL,
                         memory_save = FALSE, verbose = TRUE) {

  log <- nm_get_logger("analysis.decompose.emissions")

  # --- 1. Setup & Dependencies ---
  if (is.null(df)) stop("Input `df` must be provided.")

  if (backend == "h2o") {
    # Pass resource constraints explicitly
    nm_init_h2o(n_cores = n_cores, max_mem_size = max_mem_size, verbose = verbose)
    h2o::h2o.no_progress()
  }

  # --- 2. Prepare Data ---
  df_work <- nm_process_date(df)

  # Filter NAs in target to prevent training errors
  if (!value %in% names(df_work)) stop(sprintf("Target column '%s' not found in df.", value))
  df_work <- df_work %>%
    dplyr::filter(!is.na(date) & !is.na(.data[[value]])) %>%
    dplyr::arrange(date)

  # Standardize target column name locally
  observed_series <- df_work[[value]]
  if (value != "value") {
    df_work$value <- df_work[[value]]
  }

  # Prepare Resampling Pool
  if (is.null(resample_df)) {
    resample_df <- df_work
  } else {
    resample_df <- nm_process_date(resample_df)
  }

  # --- 3. Train Model if Needed ---
  if (is.null(model)) {
    if (verbose) log$info("No model provided. Training new model (Backend: %s)...", backend)

    build_results <- nm_build_model(
      df = df_work,
      value = "value",
      backend = backend,
      predictors = predictors,
      split_method = split_method,
      fraction = fraction,
      model_config = model_config,
      seed = seed,
      verbose = verbose
    )
    df_work <- build_results$df_prep
    model <- build_results$model
  }

  # --- 4. Identify Model Features ---
  model_feats <- if (backend == "h2o" && inherits(model, "H2OModel")) {
    model@parameters$x
  } else {
    predictors
  }

  if (is.null(model_feats)) stop("Could not determine model features. Please provide `predictors` or a valid H2O model.")

  model_feats <- intersect(model_feats, colnames(df_work))
  if (length(model_feats) == 0) stop("None of the model features match columns in `df`.")

  # --- 5. Decomposition Loop ---
  # Resolve effective resampling parallelism (mirrors Python's `_effective_cores`).
  if (!is.null(n_cores)) {
    n_cores_eff <- max(1, n_cores)
  } else {
    detected <- parallel::detectCores(logical = FALSE) - 1
    if (is.na(detected) || length(detected) == 0) {
      detected <- parallel::detectCores(logical = TRUE) - 1
    }
    n_cores_eff <- max(1, detected)
  }
  if (Sys.getenv("_R_CHECK_LIMIT_CORES_", "") != "") {
    n_cores_eff <- min(n_cores_eff, 2)
  }

  result <- data.frame(date = df_work$date, observed = observed_series)

  # Define hierarchy: Base -> Trend -> Season -> Weekday -> Hour
  time_vars_order <- c("date_unix", "day_julian", "weekday", "hour")

  # Only decompose variables that were actually used in the model
  decomp_vars <- c("base", intersect(time_vars_order, model_feats))

  if (verbose) {
    log$info("Decomposing %d components: %s", length(decomp_vars), paste(decomp_vars, collapse = ", "))
    pb <- progress::progress_bar$new(
      format = "  Decomposing [:bar] :percent | Step :current/:total | ETA: :eta",
      total = length(decomp_vars), clear = FALSE, width = 80
    )
  }

  tmp_results <- list()

  # Start by assuming EVERYTHING needs to be resampled (shuffled)
  current_features_to_resample <- model_feats

  for (var_to_freeze in decomp_vars) {
    if (verbose) pb$tick()

    # If not 'base', freeze variable by REMOVING it from resampling list
    if (var_to_freeze != "base") {
      current_features_to_resample <- setdiff(current_features_to_resample, var_to_freeze)
    }

    # Run Normalisation
    df_norm <- nm_normalise(
      df = df_work,
      model = model,
      resample_vars = current_features_to_resample,
      resample_df = resample_df,
      n_samples = n_samples,
      seed = seed,
      memory_save = memory_save,
      verbose = FALSE,
      aggregate = TRUE,
      n_cores = n_cores_eff
    )

    tmp_results[[var_to_freeze]] <- df_norm$normalised
  }

  # Combine results
  result <- cbind(result, as.data.frame(tmp_results))

  # --- 6. Recompose Components (Calculate Differences) ---
  last_var <- decomp_vars[length(decomp_vars)]
  result$emi_total <- result[[last_var]]

  if (any(is.na(result$emi_total))) {
    result$emi_total[is.na(result$emi_total)] <- result$observed[is.na(result$emi_total)]
  }

  # Difference Logic: Component = State(Current) - State(Previous)
  recomp_pairs <- list(
    c("hour", "weekday"),
    c("weekday", "day_julian"),
    c("day_julian", "date_unix"),
    c("date_unix", "base")
  )

  for (pair in recomp_pairs) {
    current_state <- pair[1]
    prev_state    <- pair[2]

    if (current_state %in% colnames(result) && prev_state %in% colnames(result)) {
      result[[current_state]] <- result[[current_state]] - result[[prev_state]]
    }
  }

  # --- 7. Finalize Base and Noise ---
  base_mean <- mean(result$base, na.rm = TRUE)
  result$emi_base <- base_mean
  result$emi_noise <- result$base - base_mean
  result$base <- NULL

  return(result)
}


#' Decompose Meteorological Influences (Weather Contributions)
#'
#' @description
#' `nm_decom_met` quantifies the specific contribution of individual meteorological variables
#' to the target variable (e.g., "How much did Wind Speed contribute vs Temperature?").
#'
#' @details
#' The function uses a sequential "Freeze-and-Shuffle" approach:
#' \enumerate{
#'   \item **Step 1 (emi_total)**: Calculate the trend where **ALL** weather variables are shuffled (resampled). This removes all weather influence.
#'   \item **Step 2 (First Weather Var)**: Freeze the first variable (use observed values) while keeping others shuffled. The difference from Step 1 is the contribution of this variable.
#'   \item **Step 3 (Next Weather Var)**: Freeze the next variable (plus previous ones) and compare to the previous state.
#'   \item **Residuals**: `met_noise` captures the variance not explained by the model's main effects.
#' }
#'
#' @param df The input data frame. Must contain a 'date' column.
#' @param model Pre-trained model. If NULL, a model will be trained.
#' @param value The target variable name as a string (default 'value').
#' @param predictors Character vector of features used for **training** (if model is NULL).
#' @param backend The modeling backend (default 'lightgbm', or 'h2o').
#' @param split_method Method for splitting data (e.g., 'random').
#' @param fraction Proportion of data used for training.
#' @param model_config List of configuration parameters for model training.
#' @param n_samples Number of resampling iterations per step (default 300).
#' @param seed Random seed for reproducibility.
#' @param importance_ascending Logical. If TRUE, decomposes variables from least to most important.
#'        If FALSE (default), decomposes from most important to least.
#' @param n_cores Number of CPU cores to use for **H2O Initialization** (when
#'        `backend = "h2o"`) and for parallel resampling in each
#'        `nm_normalise()` call (default: detected cores minus one).
#' @param max_mem_size Maximum memory for H2O (e.g., "16G"). If NULL, auto-detected.
#' @param resample_df External resampling pool. **Important**: Usually the full dataset.
#'        If NULL, defaults to `df`.
#' @param memory_save Logical. Enable memory-efficient processing.
#' @param verbose Logical. Print progress messages.
#'
#' @return A data frame containing:
#' \itemize{
#'   \item `observed`: The original time series.
#'   \item `emi_total`: The weather-normalised trend.
#'   \item `met_total`: The total meteorological component (`observed` - `emi_total`).
#'   \item `met_base`: The average meteorological influence (constant).
#'   \item `met_noise`: Unexplained meteorological variance.
#'   \item Individual columns for each weather variable (e.g., `ws`, `temp`, `wd`).
#' }
#'
#' @export
nm_decom_met <- function(df = NULL, model = NULL, value = "value",
                         predictors = NULL, backend = "lightgbm",
                         split_method = "random", fraction = 0.75,
                         model_config = NULL, n_samples = 300, seed = 7654321,
                         importance_ascending = FALSE,
                         n_cores = NULL,
                         max_mem_size = NULL,
                         resample_df = NULL,
                         memory_save = FALSE, verbose = TRUE) {

  log <- nm_get_logger("analysis.decompose.met")

  # --- 1. Setup & H2O Init ---
  if (is.null(df) || is.null(value)) stop("`df` and `value` must be provided.")

  if (backend == "h2o") {
    # Pass both cores and memory settings
    nm_init_h2o(n_cores = n_cores, max_mem_size = max_mem_size, verbose = verbose)
    h2o::h2o.no_progress()
  }

  # --- 2. Prepare Data ---
  df_work <- nm_process_date(df)

  if (!value %in% names(df_work)) stop(sprintf("Target column '%s' not found.", value))
  df_work <- df_work %>%
    dplyr::filter(!is.na(date) & !is.na(.data[[value]])) %>%
    dplyr::arrange(date)

  observed_series <- df_work[[value]]
  if (value != "value") {
    df_work$value <- df_work[[value]]
  }

  # Prepare Resampling Pool
  if (is.null(resample_df)) {
    resample_df <- df_work
  } else {
    resample_df <- nm_process_date(resample_df)
  }

  # --- 3. Train Model if Needed ---
  if (is.null(model)) {
    if (verbose) log$info("Training model via backend='%s'...", backend)
    build_results <- nm_build_model(
      df = df_work, value = "value", backend = backend, predictors = predictors,
      split_method = split_method, fraction = fraction, model_config = model_config,
      seed = seed, verbose = verbose
    )
    df_work <- build_results$df_prep
    model <- build_results$model
  }

  # --- 4. Identify Features & Sort by Importance ---
  feat_sorted <- tryCatch(
    nm_extract_features(model, importance_ascending = importance_ascending),
    error = function(e) {
      if (backend == "h2o" && inherits(model, "H2OModel")) return(model@parameters$x)
      return(predictors)
    }
  )

  # Ensure features exist in dataframe
  feat_sorted <- intersect(feat_sorted, colnames(df_work))
  if (length(feat_sorted) == 0) stop("No valid model features found in `df`.")

  # Isolate Weather Variables (Remove Time Components)
  time_vars <- c("hour", "weekday", "day_julian", "date_unix")
  contrib_candidates <- feat_sorted[!feat_sorted %in% time_vars]

  if (length(contrib_candidates) == 0) log$warn("No weather variables found to decompose.")

  # Resolve effective resampling parallelism (mirrors Python's `_effective_cores`).
  if (!is.null(n_cores)) {
    n_cores_eff <- max(1, n_cores)
  } else {
    detected <- parallel::detectCores(logical = FALSE) - 1
    if (is.na(detected) || length(detected) == 0) {
      detected <- parallel::detectCores(logical = TRUE) - 1
    }
    n_cores_eff <- max(1, detected)
  }
  if (Sys.getenv("_R_CHECK_LIMIT_CORES_", "") != "") {
    n_cores_eff <- min(n_cores_eff, 2)
  }

  result <- data.frame(date = df_work$date, observed = observed_series)

  # --- 5. Iterative Decomposition Loop ---
  decomp_order <- c("emi_total", contrib_candidates)
  current_resample_vars <- contrib_candidates
  tmp_results <- list()

  if (verbose) {
    log$info("Decomposing %d meteorological variables...", length(contrib_candidates))
    pb <- progress::progress_bar$new(
      format = "  Decomposing [:bar] :percent | Step :current/:total | ETA: :eta",
      total = length(decomp_order), clear = FALSE, width = 80
    )
  }

  for (var_to_freeze in decomp_order) {
    if (verbose) pb$tick()

    # Freeze variable by REMOVING it from resampling list
    if (var_to_freeze != "emi_total") {
      current_resample_vars <- setdiff(current_resample_vars, var_to_freeze)
    }

    # Run Normalisation
    df_norm <- nm_normalise(
      df = df_work,
      model = model,
      resample_vars = current_resample_vars,
      resample_df = resample_df,
      n_samples = n_samples,
      seed = seed,
      memory_save = memory_save,
      verbose = FALSE,
      aggregate = TRUE,
      n_cores = n_cores_eff
    )

    tmp_results[[var_to_freeze]] <- df_norm$normalised
  }

  # --- 6. Recompose Meteorological Components ---
  result$emi_total <- tmp_results[["emi_total"]]
  prev_key <- "emi_total"

  for (feat in contrib_candidates) {
    result[[feat]] <- tmp_results[[feat]] - tmp_results[[prev_key]]
    prev_key <- feat
  }

  # --- 7. Calculate Aggregates (Met Total, Base, Noise) ---
  result$met_total <- result$observed - result$emi_total
  result$met_base <- mean(result$met_total, na.rm = TRUE)

  contrib_sum <- if (length(contrib_candidates) > 0) {
    rowSums(result[, contrib_candidates, drop = FALSE], na.rm = TRUE)
  } else {
    0.0
  }

  result$met_noise <- result$met_total - (result$met_base + contrib_sum)

  return(result)
}
