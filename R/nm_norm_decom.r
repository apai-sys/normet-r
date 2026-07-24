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
#' @param target The target variable name as a string.
#' @param backend The modeling backend to use (default 'lightgbm', or 'h2o').
#' @param covariates The names of the features used for training (if model is NULL).
#' @param split_method Method for splitting data for model training (e.g.,
#'   'random'). See \code{\link{nm_split_into_sets}} for the exact mechanics
#'   and its warning about `"month_ts"`/`"season_ts"`'s fixed-position
#'   training blind spot.
#' @param train_fraction Proportion of data for training if a model is trained.
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
#' @param cache_dir Character. Directory for on-disk caching of the internal
#'        model fit (when `model` is NULL) and of every per-component
#'        \code{\link{nm_normalise}} call in the decomposition loop -- see
#'        \code{\link{nm_normalise}}'s `cache_dir` for why this matters
#'        (each step is a full Monte Carlo resample-and-predict). If NULL
#'        (default), caching is disabled.
#' @param variable_order Character vector or NULL. Explicit meteorological-
#'        feature decomposition order, forwarded to \code{\link{nm_decom_met}}
#'        (ignored when `method = "emission"`, which always uses its own
#'        hardcoded calendar order). See \code{\link{nm_decom_met}}'s
#'        `variable_order` for details.
#'
#' @return A data frame with the decomposed components.
#'
#' @examples
#' \donttest{
#' if (requireNamespace("lightgbm", quietly = TRUE)) {
#'   covariates <- c("ws", "wd", "temp", "RH", "blh", "ssrd")
#'   predictors <- c(covariates, "date_unix", "day_julian", "weekday", "hour")
#'   build <- nm_build_model(
#'     my1[1:150, c("date", "NO2", covariates)],
#'     target = "NO2", covariates = predictors,
#'     model_config = list(n_trials = 1, cv_folds = 2, nrounds = 15,
#'                          num_leaves_min = 5, num_leaves_max = 15),
#'     seed = 42, verbose = FALSE
#'   )
#'   decomp <- nm_decompose(
#'     method = "emission", df = build$df_prep, model = build$model,
#'     covariates = predictors, n_samples = 2, n_cores = 1, verbose = FALSE
#'   )
#'   head(decomp)
#' }
#' }
#'
#' @export
nm_decompose <- function(method = "emission",
                         df = NULL,
                         model = NULL,
                         target = "value",
                         covariates = NULL,
                         backend = "lightgbm",
                         split_method = "random",
                         train_fraction = 0.75,
                         model_config = NULL,
                         n_samples = 300,
                         seed = 7654321,
                         importance_ascending = FALSE,
                         n_cores = NULL,
                         max_mem_size = NULL,
                         resample_df = NULL,
                         memory_save = FALSE,
                         verbose = TRUE,
                         cache_dir = NULL,
                         variable_order = NULL) {
  # --- 1. Validate Common Inputs ---
  if (is.null(df) || is.null(target)) stop("`df` and `target` must be provided.")
  if (is.null(model) && is.null(covariates)) stop("Either `model` or `covariates` must be provided.")
  if (is.null(model) && is.null(backend)) stop("When training a model, `backend` must be specified.")

  # --- 2. Dispatch Based on Method ---
  if (method == "emission") {
    return(nm_decom_emi(
      df = df,
      model = model,
      target = target,
      covariates = covariates,
      backend = backend,
      split_method = split_method,
      train_fraction = train_fraction,
      model_config = model_config,
      n_samples = n_samples,
      seed = seed,
      n_cores = n_cores,
      max_mem_size = max_mem_size,
      resample_df = resample_df,
      memory_save = memory_save,
      verbose = verbose,
      cache_dir = cache_dir
    ))
  }

  if (method == "meteorology") {
    return(nm_decom_met(
      df = df,
      model = model,
      target = target,
      covariates = covariates,
      backend = backend,
      split_method = split_method,
      train_fraction = train_fraction,
      model_config = model_config,
      n_samples = n_samples,
      seed = seed,
      importance_ascending = importance_ascending,
      n_cores = n_cores,
      max_mem_size = max_mem_size,
      resample_df = resample_df,
      memory_save = memory_save,
      verbose = verbose,
      cache_dir = cache_dir,
      variable_order = variable_order
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
#' **This fixed order is not just bookkeeping -- it determines what each
#' component can and cannot represent.** Because `date_unix` is frozen
#' *before* `day_julian`, `weekday`, and `hour`, the returned `date_unix`
#' ("Trend") component is computed while every within-year calendar
#' position is still being shuffled -- it cannot carry a recurring,
#' calendar-aligned signal (e.g. a Christmas/New Year dip that recurs every
#' year), only a genuine long-term drift. Conversely, `day_julian`
#' (labelled "Seasonality" above) is computed with `date_unix` already
#' frozen at *each row's own observed value*, so it is NOT a pooled,
#' climatological quantity the way a bottom-up seasonal factor would be --
#' it stays native to the specific year and can register a one-off,
#' non-repeating event (e.g. a single year's holiday dip, or a structural
#' break such as a lockdown) despite its "Seasonality" label. If you need
#' to examine a recurring calendar effect, look at `day_julian`, not
#' `date_unix`, even though "Trend" sounds like the more natural place to
#' look for it.
#'
#' Time variables are opt-in at the model level (see
#' \code{\link{nm_build_model}}'s `covariates`), not mandatory -- this
#' function adapts automatically. Only whichever of
#' `date_unix`/`day_julian`/`weekday`/`hour` actually ended up as a model
#' feature get decomposed into their own component; the rest are simply
#' absent from the result (no error). A model trained on none of the four
#' (e.g. meteorology/traffic predictors only) still decomposes cleanly into
#' `base`/`emi_base`/`emi_noise` with no time-variable columns at all.
#'
#' @param df The input data frame. Must contain a 'date' column and the target variable.
#' @param model Pre-trained model. If NULL, a new model will be trained.
#' @param target The target variable name as a string (default 'value').
#' @param covariates Character vector of features used for **training** (if model is NULL).
#' @param backend The modeling backend to use (default 'lightgbm', or 'h2o').
#' @param split_method Method for splitting data (e.g., 'random'). See
#'   \code{\link{nm_split_into_sets}} for the exact mechanics -- in
#'   particular, `"month_ts"`/`"season_ts"` hold out a block at a *fixed
#'   relative position* within every period, which can create a permanent
#'   training blind spot aligned with a specific calendar window (see that
#'   function's warning).
#' @param train_fraction Proportion of data used for training (default 0.75).
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
#' @param cache_dir Character. Directory for on-disk caching of the internal
#'        model fit (when `model` is NULL, forwarded to
#'        \code{\link{nm_build_model}}) and of every per-component
#'        \code{\link{nm_normalise}} call. If NULL (default), disabled.
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
nm_decom_emi <- function(df = NULL, model = NULL, target = "value",
                         covariates = NULL, backend = "lightgbm",
                         split_method = "random", train_fraction = 0.75,
                         model_config = NULL, n_samples = 300, seed = 7654321,
                         n_cores = NULL,
                         max_mem_size = NULL,
                         resample_df = NULL,
                         memory_save = FALSE, verbose = TRUE,
                         cache_dir = NULL) {

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
  if (!target %in% names(df_work)) stop(sprintf("Target column '%s' not found in df.", target))
  df_work <- df_work %>%
    dplyr::filter(!is.na(date) & !is.na(.data[[target]])) %>%
    dplyr::arrange(date)

  # Standardize target column name locally
  observed_series <- df_work[[target]]
  if (target != "value") {
    df_work$value <- df_work[[target]]
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
      target = "value",
      backend = backend,
      covariates = covariates,
      split_method = split_method,
      train_fraction = train_fraction,
      model_config = model_config,
      seed = seed,
      verbose = verbose,
      cache_dir = cache_dir
    )
    df_work <- build_results$df_prep
    model <- build_results$model
  }

  # --- 4. Identify Model Features ---
  model_feats <- tryCatch(
    nm_extract_features(model, verbose = verbose),
    error = function(e) covariates
  )

  if (is.null(model_feats)) stop("Could not determine model features. Please provide `covariates` or a valid model.")

  # date_unix/day_julian/weekday/hour are opt-in at the model level (see
  # this function's docs above) but aren't generated by nm_process_date()
  # itself -- only nm_build_model()'s own internal prep adds them, so a
  # pre-trained `model` passed in without `covariates` (feature list
  # coming from nm_extract_features() instead) needs them generated here
  # too, or the intersect() below silently drops whichever of the four the
  # model actually needs.
  missing_time_vars <- setdiff(
    intersect(c("date_unix", "day_julian", "weekday", "hour"), model_feats),
    colnames(df_work)
  )
  if (length(missing_time_vars) > 0) {
    df_work <- nm_add_date_variables(df_work)
    if (verbose) log$info("Generated time variables: %s", paste(missing_time_vars, collapse = ", "))
  }

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
      n_cores = n_cores_eff,
      cache_dir = cache_dir
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
#' Note the asymmetry with \code{\link{nm_decom_emi}}: that function
#' freezes time variables in a *hardcoded* calendar order (`date_unix`
#' before `day_julian` before `weekday` before `hour`, chosen so each
#' component has a specific temporal-frequency meaning -- see its
#' details), whereas this function orders meteorological variables by
#' *fitted importance* (`importance_ascending`), which can vary run to run
#' with the underlying model. The two are not directly comparable in how
#' "which component comes first" was decided. Pass `variable_order` to pin
#' an explicit order instead, for results that stay comparable across
#' model refits.
#'
#' @param df The input data frame. Must contain a 'date' column.
#' @param model Pre-trained model. If NULL, a model will be trained.
#' @param target The target variable name as a string (default 'value').
#' @param covariates Character vector of features used for **training** (if model is NULL).
#' @param backend The modeling backend (default 'lightgbm', or 'h2o').
#' @param split_method Method for splitting data (e.g., 'random').
#' @param train_fraction Proportion of data used for training.
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
#' @param cache_dir Character. Directory for on-disk caching of the internal
#'        model fit (when `model` is NULL, forwarded to
#'        \code{\link{nm_build_model}}) and of every per-component
#'        \code{\link{nm_normalise}} call. If NULL (default), disabled.
#' @param variable_order Character vector or NULL (default). Explicit
#'        meteorological-feature decomposition order. If NULL, order is
#'        derived from fitted feature importance via `importance_ascending`,
#'        which can silently reorder "which component comes first" across
#'        refits of the same features/data with a different seed --
#'        results aren't directly comparable run to run. Pass an explicit
#'        vector (must be exactly the model's non-time-variable features,
#'        in any permutation) to get a decomposition order that stays
#'        fixed and comparable across runs regardless of the underlying
#'        model's importance ranking. An incomplete/mismatched vector
#'        raises an immediate, clear error.
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
nm_decom_met <- function(df = NULL, model = NULL, target = "value",
                         covariates = NULL, backend = "lightgbm",
                         split_method = "random", train_fraction = 0.75,
                         model_config = NULL, n_samples = 300, seed = 7654321,
                         importance_ascending = FALSE,
                         n_cores = NULL,
                         max_mem_size = NULL,
                         resample_df = NULL,
                         memory_save = FALSE, verbose = TRUE,
                         cache_dir = NULL,
                         variable_order = NULL) {

  log <- nm_get_logger("analysis.decompose.met")

  # --- 1. Setup & H2O Init ---
  if (is.null(df) || is.null(target)) stop("`df` and `target` must be provided.")

  if (backend == "h2o") {
    # Pass both cores and memory settings
    nm_init_h2o(n_cores = n_cores, max_mem_size = max_mem_size, verbose = verbose)
    h2o::h2o.no_progress()
  }

  # --- 2. Prepare Data ---
  df_work <- nm_process_date(df)

  if (!target %in% names(df_work)) stop(sprintf("Target column '%s' not found.", target))
  df_work <- df_work %>%
    dplyr::filter(!is.na(date) & !is.na(.data[[target]])) %>%
    dplyr::arrange(date)

  observed_series <- df_work[[target]]
  if (target != "value") {
    df_work$value <- df_work[[target]]
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
      df = df_work, target = "value", backend = backend, covariates = covariates,
      split_method = split_method, train_fraction = train_fraction, model_config = model_config,
      seed = seed, verbose = verbose, cache_dir = cache_dir
    )
    df_work <- build_results$df_prep
    model <- build_results$model
  }

  # --- 4. Identify Features & Sort by Importance ---
  feat_sorted <- tryCatch(
    nm_extract_features(model, importance_ascending = importance_ascending),
    error = function(e) {
      if (backend == "h2o" && inherits(model, "H2OModel")) return(model@parameters$x)
      return(covariates)
    }
  )

  # Ensure features exist in dataframe
  feat_sorted <- intersect(feat_sorted, colnames(df_work))
  if (length(feat_sorted) == 0) stop("No valid model features found in `df`.")

  # Isolate Weather Variables (Remove Time Components)
  time_vars <- c("hour", "weekday", "day_julian", "date_unix")
  contrib_candidates <- feat_sorted[!feat_sorted %in% time_vars]

  if (!is.null(variable_order)) {
    actual_set <- unique(contrib_candidates)
    requested_set <- unique(variable_order)
    if (!setequal(actual_set, requested_set)) {
      missing <- setdiff(actual_set, requested_set)
      extra <- setdiff(requested_set, actual_set)
      stop(sprintf(
        "`variable_order` must be exactly the model's meteorological (non-time) features, in any order. Missing: %s. Not in model: %s.",
        paste(missing, collapse = ", "), paste(extra, collapse = ", ")
      ))
    }
    contrib_candidates <- variable_order
  }

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
      n_cores = n_cores_eff,
      cache_dir = cache_dir
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
