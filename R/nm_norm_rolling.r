#' Rolling Window Normalisation
#'
#' @description
#' Performs meteorological normalisation using a rolling window approach.
#' This allows visualizing how the normalised concentration changes over time (trend analysis).
#'
#' @param df Input data frame containing 'date', target 'value', and predictor columns.
#' @param model Pre-trained model. If NULL, a model is trained internally using the full dataset.
#' @param value Target variable name.
#' @param predictors Character vector of ALL features to be used for training the model (if model is NULL).
#' @param resample_vars Variables to be resampled (de-weathered).
#' @param resample_df Resampling pool. Defaults to the full dataset.
#' @param split_method Split method for training (if model is NULL).
#' @param fraction Training fraction (if model is NULL).
#' @param backend Backend for training (if model is NULL): 'lightgbm' (default) or 'h2o'.
#' @param model_config Config for training (if model is NULL).
#' @param n_samples Number of resampling iterations per window.
#' @param window_days Width of the rolling window in days.
#' @param rolling_every Step size for the rolling window in days.
#' @param seed Random seed.
#' @param n_cores Number of CPU cores to use for **H2O Initialization**.
#' @param max_mem_size Maximum memory for H2O (e.g., "16G"). If NULL, auto-detected.
#' @param memory_save Save memory during normalisation?
#' @param verbose Print progress?
#'
#' @return A data frame with one row per timestamp and one column per rolling
#'   window, containing the normalised (de-weathered) values for that window.
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
#'   roll <- nm_rolling(
#'     build$df_prep, model = build$model, predictors = predictors,
#'     resample_vars = covariates, window_days = 4, rolling_every = 8,
#'     n_samples = 1, n_cores = 1, verbose = FALSE
#'   )
#'   head(roll)
#' }
#' }
#'
#' @export
nm_rolling <- function(df,
                       model = NULL,
                       value = "value",
                       predictors = NULL,
                       resample_vars = NULL,
                       resample_df = NULL,
                       split_method = "random",
                       fraction = 0.75,
                       backend = "lightgbm",
                       model_config = NULL,
                       n_samples = 300,
                       window_days = 14,
                       rolling_every = 7,
                       seed = 7654321,
                       n_cores = NULL,
                       max_mem_size = NULL,
                       memory_save = FALSE,
                       verbose = TRUE) {

  log <- nm_get_logger("analysis.rolling")
  nm_require("data.table")

  # --- 1. Setup & Validation ---
  df <- data.table::as.data.table(df)
  if (!"date" %in% names(df)) stop("Input `df` must contain a 'date' column.")

  # Ensure date is standard Date/POSIXct type
  if (!inherits(df$date, "Date") && !inherits(df$date, "POSIXt")) {
    df[, date := as.POSIXct(date)]
  }

  # Default resample pool is the FULL dataset
  if (is.null(resample_df)) {
    resample_df <- df
  } else {
    resample_df <- data.table::as.data.table(resample_df)
  }

  set.seed(seed)

  # Initialize Backend (Resource Management)
  if (backend == "h2o") {
    # Pass both cores and memory settings
    nm_init_h2o(n_cores = n_cores, max_mem_size = max_mem_size, verbose = verbose)
  }

  # --- 2. Model Training (Auto-Train) ---
  if (is.null(model)) {
    if (verbose) log$info("No model provided. Training new model on full dataset...")

    # Pass 'predictors' to nm_build_model
    # Note: Removed n_cores from this call as per new design
    build_results <- nm_build_model(
      df = df,
      value = value,
      backend = backend,
      predictors = predictors,
      split_method = split_method,
      fraction = fraction,
      model_config = model_config,
      seed = seed,
      verbose = verbose
    )

    df <- data.table::as.data.table(build_results$df_prep)
    model <- build_results$model
  }

  # --- 3. Rolling Window Calculation ---
  date_min <- min(df$date, na.rm = TRUE)
  date_max <- max(df$date, na.rm = TRUE)

  # Generate start dates
  start_dates <- seq(from = date_min, to = date_max - lubridate::days(window_days), by = paste(rolling_every, "days"))

  if (length(start_dates) == 0) {
    log$warn("Dataset is too short for the requested window_days.")
    return(data.frame())
  }

  # --- Calculate Zero-Padding Width ---
  # e.g., if 150 windows, width=3 -> window_001, window_010, ...
  pad_width <- nchar(as.character(length(start_dates)))
  # Create a dynamic format string like "window_%03d"
  id_fmt <- paste0("window_%0", pad_width, "d")

  if (verbose) {
    log$info("Processing %d rolling windows (Window: %d days, Step: %d days).", length(start_dates), window_days, rolling_every)
    pb <- progress::progress_bar$new(
      format = "  Rolling [:bar] :percent | Window :current/:total | ETA: :eta",
      total = length(start_dates), clear = FALSE, width = 80
    )
  }

  rolling_results_list <- vector("list", length(start_dates))
  data.table::setkey(df, date)

  for (i in seq_along(start_dates)) {
    ds <- start_dates[i]
    de <- ds + lubridate::days(window_days)

    # Fast subset
    dfa <- df[date >= ds & date < de]

    if (nrow(dfa) > 0) {
      tryCatch(
        {
          # Normalise
          # Note: Resource args are NOT passed here (handled internally)
          dfar <- nm_normalise(
            df = dfa,
            model = model,
            resample_vars = resample_vars,
            resample_df = resample_df,
            n_samples = n_samples,
            replace = TRUE,
            aggregate = TRUE,
            seed = seed + i,
            memory_save = memory_save,
            verbose = FALSE
          )

          res_dt <- data.table::as.data.table(dfar)

          # --- Use sprintf for sorted IDs ---
          window_id_str <- sprintf(id_fmt, i)

          rolling_results_list[[i]] <- res_dt[, .(date, normalised, window_id = window_id_str)]

        },
        error = function(e) {
          log$warn("Window %d (%s) failed: %s", i, as.character(ds), e$message)
        })
    }
    if (verbose && exists("pb")) pb$tick()
  }

  # --- 4. Aggregation ---
  rolling_results_list <- rolling_results_list[!sapply(rolling_results_list, is.null)]

  if (length(rolling_results_list) == 0) {
    log$warn("No rolling windows were successfully processed.")
    return(data.frame())
  }

  if (verbose) log$info("Aggregating results into wide format...")

  combined_long <- data.table::rbindlist(rolling_results_list)

  # Pivot to wide format
  # Because window_id is now "window_001", "window_002", dcast will sort them correctly by default.
  combined_wide <- data.table::dcast(
    combined_long,
    date ~ window_id,
    value.var = "normalised"
  )

  data.table::setorder(combined_wide, date)

  data.table::setDF(combined_wide)
  return(combined_wide)
}
