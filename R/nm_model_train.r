#' Train a model using a specified backend
#'
#' \code{nm_train_model} is a high-level wrapper function that dispatches the training
#' task to a specific backend implementation based on the `backend` parameter.
#' The default backend is 'lightgbm'.
#'
#' @param df Input data frame containing the data to be used for training.
#' @param value The target variable name as a string. Default is "value".
#' @param predictors Independent/explanatory variables used for training the model.
#' @param model_config Optional list of AutoML configuration overrides.
#'        Examples: `list(max_runtime_secs = 60, include_algos = c("GBM"), nfolds = 5)`.
#' @param backend The modeling framework to use: 'lightgbm' (default) or 'h2o'.
#' @param seed A random seed for reproducibility. Default is 7654321.
#' @param verbose Should the function print progress messages? Default is TRUE.
#'
#' @return The trained model object from the specified backend.
#'
#' @examples
#' \donttest{
#' if (requireNamespace("lightgbm", quietly = TRUE)) {
#'   covariates <- c("u10", "v10", "d2m", "t2m", "blh", "ssrd")
#'   df_prep <- nm_prepare_data(
#'     my1[1:150, c("date", "NO2", covariates)],
#'     value = "NO2", covariates = covariates, verbose = FALSE
#'   )
#'   predictors <- c(covariates, "date_unix", "day_julian", "weekday", "hour")
#'   model <- nm_train_model(
#'     df_prep, value = "value", predictors = predictors,
#'     model_config = list(n_trials = 1, cv_folds = 2, nrounds = 15,
#'                          num_leaves_min = 5, num_leaves_max = 15),
#'     seed = 42, verbose = FALSE
#'   )
#'   nm_extract_features(model)
#' }
#' }
#'
#' @export
nm_train_model <- function(df, value = "value", predictors = NULL, model_config = NULL,
                           backend = "lightgbm", seed = 7654321, verbose = TRUE) {

  log <- nm_get_logger("model.train")

  backend <- match.arg(backend, choices = c("lightgbm", "h2o"))

  # --- 1. Input Validation ---
  if (missing(predictors) || is.null(predictors) || length(predictors) == 0) {
    stop("`predictors` argument is missing or empty.")
  }

  # Check for NA values in predictors vector
  if (any(is.na(predictors))) {
    stop("`predictors` vector contains NA values. Please check your variable names.")
  }

  if (verbose) log$info("Dispatching to backend for training: %s", backend)

  # --- 2. Dispatch to Backend ---
  if (backend == "h2o") {
    model <- nm_train_h2o(
      df = df, value = value, predictors = predictors,
      model_config = model_config, seed = seed, verbose = verbose
    )
    return(model)

  } else if (backend == "lightgbm") {
    model <- nm_train_lgb(
      df = df, value = value, predictors = predictors,
      model_config = model_config, seed = seed, verbose = verbose
    )
    return(model)

  } else {
    err_msg <- paste("Unsupported backend:", backend)
    log$error(err_msg)
    stop(err_msg)
  }
}


#' Prepare Data and Train a Model
#'
#' @description
#' `nm_build_model` orchestrates the end-to-end process of data preparation and model training.
#' It separates external covariates from time features, handles data splitting, and dispatches
#' to the specified training backend.
#'
#' @param df The raw input data frame.
#' @param value A string indicating the target column in `df`.
#' @param backend A string for the modeling backend: 'lightgbm' (default) or 'h2o'.
#' @param predictors A character vector of ALL features to be used in the model.
#'        This can include external variables (e.g., "temp") AND specific time variables (e.g., "weekday").
#' @param split_method A string for the data splitting strategy. Default is 'random'.
#' @param fraction A numeric value for the training fraction of the split. Default is 0.75.
#' @param model_config Optional list of AutoML configuration overrides.
#'        Examples: `list(max_runtime_secs = 60, include_algos = c("GBM"), nfolds = 5)`.
#' @param seed An integer for the random seed. Default is 7654321.
#' @param verbose A logical value to enable logging messages. Default is TRUE.
#'
#' @return A list containing `df_prep` (the processed data) and `model` (the trained model object).
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
#'   names(build)
#' }
#' }
#'
#' @export
nm_build_model <- function(df,
                           value,
                           backend = "lightgbm",
                           predictors = NULL,
                           split_method = "random",
                           fraction = 0.75,
                           model_config = NULL,
                           seed = 7654321,
                           verbose = TRUE) {

  log <- nm_get_logger("model.build")
  backend <- match.arg(backend, choices = c("lightgbm", "h2o"))

  # 1. Validate Inputs
  if (missing(predictors) || is.null(predictors) || length(predictors) == 0) {
    stop("`predictors` must be provided and cannot be empty.")
  }
  if (!value %in% colnames(df)) {
    stop(sprintf("Target column '%s' not found.", value))
  }

  # --- 2. Smart Separation of Covariates vs Time Features ---
  # We need to know which of the 'predictors' are external variables (that need checking/imputing)
  # and which are time variables (that are auto-generated).
  known_time_vars <- c("date_unix", "day_julian", "weekday", "hour")

  # Covariates = Predictors - Time Vars
  # These are the columns we expect to find in the raw 'df'
  covariates_for_prep <- setdiff(predictors, known_time_vars)

  if (length(covariates_for_prep) == 0) {
    log$warn("No external covariates detected in `predictors`. Model will use time features only.")
  }

  # --- 3. Prepare Data ---
  if (verbose) log$info("Preparing data... (Covariates: %s)", paste(covariates_for_prep, collapse = ", "))

  df_prep <- nm_prepare_data(
    df = df,
    value = value,
    covariates = covariates_for_prep, # Only pass the non-time vars here
    split_method = split_method,
    fraction = fraction,
    seed = seed,
    verbose = verbose
  )

  # --- 4. Validate Final Predictors ---
  # Ensure all requested predictors (both Met and Time) exist in the prepared data
  missing_preds <- setdiff(predictors, colnames(df_prep))

  if (length(missing_preds) > 0) {
    # If a user asked for "hour" but for some reason it wasn't generated (rare), or a typo in Met var
    stop(sprintf("The following requested predictors are missing from prepared data: %s",
      paste(missing_preds, collapse = ", ")))
  }

  # 5. Train Model
  # We pass the EXACT list of predictors the user requested
  target_col <- if ("value" %in% colnames(df_prep)) "value" else value

  if (verbose) {
    log$info("Training model with %d predictors: %s", length(predictors), paste(predictors, collapse = ", "))
  }

  model <- nm_train_model(
    df = df_prep,
    value = target_col,
    backend = backend,
    predictors = predictors,
    model_config = model_config,
    seed = seed,
    verbose = verbose
  )

  if (verbose) log$info("Model training completed successfully.")

  return(list(
    df_prep = df_prep,
    model = model
  ))
}
