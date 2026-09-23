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
#' @param groups,attribution,n_permutations Forwarded to
#'        \code{\link{nm_decom_met}} (`method = "meteorology"` only; refused
#'        for `method = "emission"`).
#' @param resample_pools,conditional_on Forwarded to
#'        \code{\link{nm_decom_met}} or \code{\link{nm_decom_emi}}.
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
                         variable_order = NULL,
                         groups = NULL,
                         attribution = NULL,
                         n_permutations = NULL,
                         resample_pools = NULL,
                         conditional_on = NULL) {
  # --- 1. Validate Common Inputs ---
  if (is.null(df) || is.null(target)) stop("`df` and `target` must be provided.")
  if (is.null(model) && is.null(covariates)) stop("Either `model` or `covariates` must be provided.")
  if (is.null(model) && is.null(backend)) stop("When training a model, `backend` must be specified.")

  # --- 2. Dispatch Based on Method ---
  if (method == "emission") {
    if (!is.null(groups) || !is.null(n_permutations) || !is.null(attribution)) {
      stop("`groups`, `n_permutations` and `attribution` apply to the meteorological ",
           "decomposition (nm_decom_met); nm_decom_emi freezes the time variables in its own ",
           "calendar order.")
    }
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
      cache_dir = cache_dir,
      resample_pools = resample_pools,
      conditional_on = conditional_on
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
      variable_order = variable_order,
      groups = groups,
      attribution = attribution,
      n_permutations = n_permutations,
      resample_pools = resample_pools,
      conditional_on = conditional_on
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
#' @param resample_pools Named list of data frames, or NULL (default). Extra
#'        pools some variables are drawn from instead of `resample_df`,
#'        forwarded to every \code{\link{nm_normalise}} call -- see
#'        \code{\link{nm_normalise_lgb}}.
#' @param conditional_on Named list, or NULL (default). Filter on the
#'        `resample_df` pool (see \code{\link{nm_normalise_ext}}), applied once
#'        before the decomposition.
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
                         cache_dir = NULL,
                         resample_pools = NULL,
                         conditional_on = NULL) {

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
  if (target != "value") {
    df_work$value <- df_work[[target]]
  }

  # Prepare Resampling Pool
  if (is.null(resample_df)) {
    resample_df <- df_work
  } else {
    resample_df <- nm_process_date(resample_df)
  }
  if (!is.null(conditional_on)) {
    resample_df <- nm_apply_conditional_filter(resample_df, conditional_on)
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

  # Observed values come from the frame actually decomposed: a model trained
  # here drops rows with a missing covariate.
  observed_series <- df_work$value

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
  # No n_tasks cap here: this is forwarded to nm_normalise() rather than used to
  # size a cluster directly, and nm_normalise() caps it against its own batches.
  n_cores_eff <- .nm_resolve_cores(n_cores)

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
      resample_pools = resample_pools,
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


# ---------------------------------------------------------------------------
# Attribution engine for nm_decom_met: what to attribute to (single features
# or named groups) and how (sequential or Shapley). Mirrors normet-py's
# analysis/decomposition.py.
# ---------------------------------------------------------------------------

.NM_TIME_VARS <- c("date_unix", "day_julian", "weekday", "hour")
# nm_decom_met's own result columns, which a group may not be named after.
.NM_MET_RESULT_COLUMNS <- c("date", "observed", "emi_total", "met_total", "met_base", "met_noise")
# Exact Shapley values need 2^k normalisations for k features or groups.
.NM_SHAPLEY_EXACT_MAX <- 10L

# Validate the attribution options that do not depend on the model's features,
# so a bad call fails before a model is trained. Returns the resolved method.
.nm_attribution_method <- function(groups, attribution, n_permutations, variable_order) {
  method <- if (!is.null(attribution)) attribution else if (!is.null(groups)) "shapley" else "sequential"
  if (!is.character(method) || length(method) != 1 || !method %in% c("sequential", "shapley")) {
    stop(sprintf("`attribution` must be 'sequential' or 'shapley', got '%s'.",
                 paste(attribution, collapse = ", ")))
  }
  if (!is.null(n_permutations)) {
    if (method != "shapley") stop("`n_permutations` only applies to attribution = 'shapley'.")
    if (!is.numeric(n_permutations) || length(n_permutations) != 1 || !is.finite(n_permutations) ||
        n_permutations != round(n_permutations)) {
      stop(sprintf("`n_permutations` must be a whole number, got %s.", format(n_permutations)))
    }
    if (n_permutations < 1) {
      stop(sprintf("`n_permutations` must be at least 1, got %s.", format(n_permutations)))
    }
  }
  if (!is.null(groups) && !is.null(variable_order)) {
    stop("`variable_order` orders single features; with `groups` the groups are the units, ",
         "taken in the order they are listed.")
  }
  if (is.null(groups) && !is.null(variable_order) && method == "shapley") {
    stop("`variable_order` has no effect with attribution = 'shapley', which averages over every order.")
  }
  method
}

.nm_players_from_groups <- function(groups, features) {
  if (!is.list(groups) || is.data.frame(groups) || length(groups) == 0 || is.null(names(groups)) ||
      any(!nzchar(names(groups))) || anyDuplicated(names(groups))) {
    stop("`groups` must be a non-empty named list of feature vectors, e.g. ",
         "list(local = met_cols, transport = traj_cols).")
  }
  owner <- character(0)
  players <- list()
  for (name in names(groups)) {
    if (name %in% .NM_MET_RESULT_COLUMNS) {
      stop(sprintf("group name '%s' clashes with a result column; rename the group.", name))
    }
    feats <- as.character(groups[[name]])
    if (length(feats) == 0) stop(sprintf("group '%s' is empty.", name))
    for (f in feats) {
      if (f %in% .NM_TIME_VARS) {
        stop(sprintf(paste0("group '%s' lists the time variable '%s'; nm_decom_met holds the time ",
                            "variables at their observed values and does not attribute them."), name, f))
      }
      if (!f %in% features) {
        stop(sprintf(paste0("group '%s' lists '%s', which is not a meteorological (non-time) ",
                            "feature of the model. Features: %s."), name, f, paste(features, collapse = ", ")))
      }
      if (f %in% names(owner)) {
        where <- if (owner[[f]] == name) sprintf("twice in group '%s'", name) else
          sprintf("in two groups ('%s' and '%s')", owner[[f]], name)
        stop(sprintf("feature '%s' is listed %s.", f, where))
      }
      owner[f] <- name
    }
    players[[length(players) + 1L]] <- list(name = name, feats = feats)
  }
  unassigned <- setdiff(features, names(owner))
  if (length(unassigned) > 0) {
    stop(sprintf(paste0("every meteorological (non-time) model feature must be in exactly one group; ",
                        "not in any: %s."), paste(unassigned, collapse = ", ")))
  }
  players
}

# Decide what nm_decom_met attributes to and how. `features` arrive in the
# default sequential order (fitted importance). Returns list(players, method),
# players in result-column order, each list(name, feats).
.nm_attribution_plan <- function(features, groups, attribution, n_permutations, variable_order) {
  method <- .nm_attribution_method(groups, attribution, n_permutations, variable_order)
  if (!is.null(groups)) {
    players <- .nm_players_from_groups(groups, features)
  } else if (!is.null(variable_order)) {
    if (!setequal(features, variable_order)) {
      stop(sprintf(paste0("`variable_order` must be exactly the model's meteorological (non-time) ",
                          "features, in any order. Missing: %s. Not in model: %s."),
                   paste(setdiff(features, variable_order), collapse = ", "),
                   paste(setdiff(variable_order, features), collapse = ", ")))
    }
    twice <- unique(variable_order[duplicated(variable_order)])
    if (length(twice) > 0) {
      stop(sprintf("`variable_order` lists %s more than once.", paste(twice, collapse = ", ")))
    }
    players <- lapply(variable_order, function(f) list(name = f, feats = f))
  } else {
    players <- lapply(features, function(f) list(name = f, feats = f))
  }
  k <- length(players)
  if (method == "shapley" && is.null(n_permutations) && k > .NM_SHAPLEY_EXACT_MAX) {
    stop(sprintf(paste0("exact Shapley values over %d features need 2^%d = %s normalisations. Pass ",
                        "`groups` to attribute to fewer, larger units, or `n_permutations` for a ",
                        "sampled estimate."), k, k, format(2^k, big.mark = ",")))
  }
  list(players = players, method = method)
}

# Split v(every player fixed) - v(none fixed) among `players`. value_of(resample)
# returns the normalised series with the features in `resample` resampled and
# every other feature at its observed values; a coalition is the set of players
# held at observed values, and each is evaluated once. Returns list(emi_total,
# contributions), the contributions adding up to v(all fixed) - emi_total for
# every method.
.nm_attribute <- function(players, value_of, method, n_permutations, seed, verbose) {
  k <- length(players)
  if (method == "shapley" && !is.null(n_permutations)) {
    n_orders <- n_permutations + n_permutations %% 2
    # Sampling that evaluates as many coalitions as the exact values need.
    if (n_orders * max(k - 1, 1) + 2 >= 2^k) n_permutations <- NULL
  }
  planned <- if (method == "sequential") k + 1 else if (is.null(n_permutations)) 2^k else
    (n_permutations + n_permutations %% 2) * (k - 1) + 2
  pb <- if (verbose) progress::progress_bar$new(
    format = "  Decomposing [:bar] :percent | Step :current/:total | ETA: :eta",
    total = planned, clear = FALSE, width = 80
  ) else NULL

  values <- new.env(parent = emptyenv())
  v <- function(fixed) {
    key <- if (length(fixed)) paste(sort(fixed), collapse = ",") else "none"
    if (!exists(key, envir = values, inherits = FALSE)) {
      if (!is.null(pb)) pb$tick()
      resample <- unlist(lapply(seq_len(k), function(i) if (!i %in% fixed) players[[i]]$feats),
                         use.names = FALSE)
      if (is.null(resample)) resample <- character(0)
      assign(key, as.numeric(value_of(resample)), envir = values)
    }
    get(key, envir = values, inherits = FALSE)
  }

  emi_total <- v(integer(0))
  totals <- rep(list(numeric(length(emi_total))), k)

  if (method == "sequential") {
    prev <- integer(0)
    for (i in seq_len(k)) {
      cur <- c(prev, i)
      totals[[i]] <- v(cur) - v(prev)
      prev <- cur
    }
  } else if (is.null(n_permutations)) {
    # Exact: phi_i = sum over S not containing i of |S|!(k-|S|-1)!/k! * (v(S+i) - v(S)).
    weight <- vapply(0:(k - 1), function(s) factorial(s) * factorial(k - s - 1) / factorial(k),
                     numeric(1))
    coalitions <- lapply(0:(2^k - 1), function(m) which(bitwAnd(m, 2^(0:(k - 1))) > 0))
    coalitions <- coalitions[order(lengths(coalitions))]
    for (s in coalitions) v(s)
    for (s in coalitions) {
      for (i in setdiff(seq_len(k), s)) {
        totals[[i]] <- totals[[i]] + weight[length(s) + 1] * (v(c(s, i)) - v(s))
      }
    }
  } else {
    # Monte Carlo over orders, in antithetic pairs: an order and its reverse.
    # All orders are drawn up front: every nm_normalise() call re-seeds R's
    # global generator, which would otherwise hand back the same order each time.
    n_pairs <- (n_permutations + 1) %/% 2
    set.seed(seed)
    perms <- lapply(seq_len(n_pairs), function(p) sample.int(k))
    for (perm in perms) {
      for (ord in list(perm, rev(perm))) {
        prev <- integer(0)
        for (i in ord) {
          cur <- c(prev, i)
          totals[[i]] <- totals[[i]] + (v(cur) - v(prev))
          prev <- cur
        }
      }
    }
    totals <- lapply(totals, function(t) t / (2 * n_pairs))
  }
  names(totals) <- vapply(players, function(p) p$name, character(1))
  list(emi_total = emi_total, contributions = totals)
}


#' Decompose Meteorological Influences (Weather Contributions)
#'
#' @description
#' `nm_decom_met` quantifies the contribution of individual meteorological variables,
#' or of named groups of them, to the target variable (e.g., "How much did Wind Speed
#' contribute vs Temperature?", or "local weather vs long-range transport?").
#'
#' @details
#' `emi_total` is the normalised series with **every** meteorological (non-time)
#' feature shuffled (resampled); the time variables stay at their observed values
#' throughout. The model's prediction minus `emi_total` -- the part the meteorology
#' accounts for -- is split into one contribution per feature, or per group
#' (`groups`), by re-running \code{\link{nm_normalise}} with some of them frozen at
#' their observed values instead of shuffled:
#' \itemize{
#'   \item `attribution = "sequential"` freezes them one at a time and reports each
#'     step's change. This is cumulative freezing, not leave-one-out: each
#'     contribution is conditional on everything frozen before it, so the split
#'     depends on the order -- `variable_order` if given, else fitted importance
#'     (`importance_ascending`), which can reorder when the model is refitted; with
#'     `groups`, the order they are listed in.
#'   \item `attribution = "shapley"` averages each feature's (or group's) marginal
#'     effect over every order it could be frozen in: the Shapley value of the game
#'     whose value for a set `S` is the normalised series with `S` at observed
#'     values. No order is privileged, so the split does not move when features are
#'     listed differently or importance reshuffles.
#' }
#' Either way the contributions add up exactly to the prediction minus `emi_total`,
#' and every \code{\link{nm_normalise}} call uses the same seed, so the differences
#' between calls are paired (common random numbers).
#'
#' Separating transport from local effects is what `groups` is for:
#' `nm_decom_met(df, model, groups = list(local = met_cols, transport = traj_cols))`
#' gives one `local` and one `transport` column (Shapley by default). Both are
#' measured against `emi_total`, which averages over the air masses in the resample
#' pool, so over the record they are anomalies with a mean near zero. To measure
#' transport against a reference air mass instead, give the trajectory features a
#' pool of their own -- `resample_pools = list(transport = clean_hours[, traj_cols])`
#' makes `emi_total` the level under that air mass and the `transport` column the
#' change from it to the air that actually arrived.
#'
#' Note the asymmetry with \code{\link{nm_decom_emi}}, which freezes the time
#' variables in a hardcoded calendar order chosen so each component has a specific
#' temporal-frequency meaning.
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
#'        model's importance ranking. An incomplete/mismatched vector, or one
#'        listing a feature twice, raises an immediate, clear error.
#' @param groups Named list of character vectors, or NULL (default). Attribute
#'        the meteorological features in named groups rather than one by one,
#'        e.g. `list(local = met_cols, transport = traj_cols)`; the result then
#'        has one contribution column per group. Every non-time model feature
#'        must be in exactly one group. A group is frozen and shuffled as a
#'        unit, so its column is the effect of the group as a whole,
#'        interactions among its members included.
#' @param attribution `"sequential"` or `"shapley"`, or NULL (default: `"shapley"`
#'        when `groups` is given, otherwise `"sequential"`, the historical
#'        behaviour). See Details.
#' @param n_permutations Integer or NULL (default). `attribution = "shapley"`
#'        only. NULL computes the Shapley values exactly from all `2^k`
#'        coalitions of the `k` features or groups (allowed up to `k = 10`;
#'        four normalisations for two groups). An integer estimates them from
#'        that many random orders, drawn in antithetic pairs (an order and its
#'        reverse, so odd values round up); when that would evaluate as many
#'        coalitions as the exact values need, the exact values are computed
#'        instead.
#' @param resample_pools Named list of data frames, or NULL (default). Extra
#'        pools some variables are drawn from instead of `resample_df`,
#'        forwarded to every \code{\link{nm_normalise}} call -- see
#'        \code{\link{nm_normalise_lgb}}.
#' @param conditional_on Named list, or NULL (default). Filter on the
#'        `resample_df` pool (see \code{\link{nm_normalise_ext}}), applied once
#'        before the decomposition.
#'
#' @return A data frame containing:
#' \itemize{
#'   \item `date`, `observed`: timestamps and the original series. When the model
#'     is trained here, only the rows it was trained on (as
#'     \code{\link{nm_build_model}} keeps them).
#'   \item `emi_total`: The weather-normalised series (every meteorological
#'     feature shuffled).
#'   \item One contribution column per weather variable (e.g., `ws`, `temp`,
#'     `wd`), or per group, named after it.
#'   \item `met_total`: The total meteorological component (`observed` - `emi_total`).
#'   \item `met_base`: Its mean (a constant).
#'   \item `met_noise`: `met_total - met_base - sum of contributions`, which
#'     equals the model residual (`observed - prediction`) shifted by the constant
#'     `met_base` -- what the model does not explain, not a meteorological term.
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
                         variable_order = NULL,
                         groups = NULL,
                         attribution = NULL,
                         n_permutations = NULL,
                         resample_pools = NULL,
                         conditional_on = NULL) {

  log <- nm_get_logger("analysis.decompose.met")

  # --- 1. Setup & H2O Init ---
  if (is.null(df) || is.null(target)) stop("`df` and `target` must be provided.")
  # Options that do not depend on the model's features fail before any training.
  .nm_attribution_method(groups, attribution, n_permutations, variable_order)

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

  if (target != "value") {
    df_work$value <- df_work[[target]]
  }

  # Prepare Resampling Pool
  if (is.null(resample_df)) {
    resample_df <- df_work
  } else {
    resample_df <- nm_process_date(resample_df)
  }
  if (!is.null(conditional_on)) {
    resample_df <- nm_apply_conditional_filter(resample_df, conditional_on)
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

  # Observed values come from the frame actually decomposed: a model trained
  # here drops rows with a missing covariate, and taking `observed` from before
  # training left it longer than the dates it was paired with.
  observed_series <- df_work$value

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

  # Isolate Weather Variables (Remove Time Components). Already in importance
  # order, which is the default sequential order.
  contrib_candidates <- feat_sorted[!feat_sorted %in% .NM_TIME_VARS]
  plan <- .nm_attribution_plan(contrib_candidates, groups, attribution, n_permutations,
                               variable_order)

  if (length(contrib_candidates) == 0) log$warn("No weather variables found to decompose.")

  # Resolve effective resampling parallelism (mirrors Python's `_effective_cores`).
  # Forwarded to nm_normalise() rather than used to size a cluster here, so the
  # batch-count cap is applied there.
  n_cores_eff <- .nm_resolve_cores(n_cores)

  result <- data.frame(date = df_work$date, observed = observed_series)

  # --- 5. Attribution: one nm_normalise() run per coalition ---
  if (verbose) {
    log$info("Decomposing %d meteorological %s (%s attribution)...", length(plan$players),
             if (is.null(groups)) "variables" else "groups", plan$method)
  }
  value_of <- function(resample) {
    nm_normalise(
      df = df_work,
      model = model,
      resample_vars = resample,
      resample_df = resample_df,
      resample_pools = resample_pools,
      n_samples = n_samples,
      seed = seed,
      memory_save = memory_save,
      verbose = FALSE,
      aggregate = TRUE,
      n_cores = n_cores_eff,
      cache_dir = cache_dir
    )$normalised
  }
  att <- .nm_attribute(plan$players, value_of, plan$method, n_permutations, seed, verbose)

  # --- 6. Recompose Meteorological Components ---
  result$emi_total <- att$emi_total
  for (name in names(att$contributions)) result[[name]] <- att$contributions[[name]]

  # --- 7. Calculate Aggregates (Met Total, Base, Noise) ---
  result$met_total <- result$observed - result$emi_total
  result$met_base <- mean(result$met_total, na.rm = TRUE)

  contrib_names <- names(att$contributions)
  contrib_sum <- if (length(contrib_names) > 0) {
    rowSums(result[, contrib_names, drop = FALSE], na.rm = TRUE)
  } else {
    0.0
  }

  result$met_noise <- result$met_total - (result$met_base + contrib_sum)

  return(result)
}
