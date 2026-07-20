#' Create a value grid for Partial Dependence Plots (Internal Helper)
#'
#' @noRd
.create_pdp_grid <- function(series, quantile_range = c(0.01, 0.99), grid_points = 50) {
  # Convert to numeric and remove non-finite values
  s <- as.numeric(series)
  s <- s[is.finite(s)]

  if (length(s) == 0) return(NULL)

  # Compute quantiles to determine the range of interest
  lo_hi <- stats::quantile(s, probs = quantile_range, na.rm = TRUE)

  # Return NULL if the range is invalid or flat
  if (any(!is.finite(lo_hi)) || lo_hi[1] == lo_hi[2]) return(NULL)

  # Generate a sequence of points grid
  return(seq(lo_hi[1], lo_hi[2], length.out = max(2, grid_points)))
}


#' Compute Partial Dependence Plots (PDP)
#'
#' @description
#' Main dispatcher function that routes PDP calculation to either the H2O backend
#' or the Generic backend based on the model type.
#'
#' @param df Data frame containing the input data.
#' @param model The trained model object. Must have a 'backend' attribute.
#' @param var_list Character vector of variables to compute PDP for. If NULL, computes for all features.
#' @param verbose Logical. If TRUE, shows progress bars and logs.
#' @param ... Additional arguments passed to the backend functions.
#'
#' @return A data frame with PDP results.
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
#'   pdp <- nm_pdp(build$df_prep, build$model, var_list = c("temp"), n_cores = 1, verbose = FALSE)
#'   head(pdp)
#' }
#' }
#'
#' @export
nm_pdp <- function(df, model, var_list = NULL, verbose = TRUE, ...) {
  log <- nm_get_logger("analysis.pdp")
  model_backend <- nm_detect_backend(model)

  # Dispatch to H2O backend if applicable
  if (!is.null(model_backend) && startsWith(model_backend, "h2o")) {
    if (verbose) log$info("Dispatching to H2O backend for PDP calculation.")
    return(nm_pdp_h2o(df = df, model = model, var_list = var_list, verbose = verbose, ...))
  } else {
    # Default to Generic backend
    if (verbose) log$info("Dispatching to generic backend for PDP calculation.")
    return(nm_pdp_generic(df = df, model = model, var_list = var_list, verbose = verbose, ...))
  }
}


#' Compute PDP for H2O Models
#'
#' @description
#' Internal backend for computing PDPs using H2O's optimized `partialPlot`.
#' Suppresses H2O's internal progress bars to prevent console flooding.
#'
#' @keywords internal
nm_pdp_h2o <- function(df, model, var_list = NULL, training_only = TRUE, verbose = TRUE) {

  log <- nm_get_logger("analysis.pdp.h2o")
  nm_require("h2o", hint = "install.packages('h2o')")

  # --- OPTIMIZATION: Suppress H2O internal progress bars ---
  # This prevents the " |==========| 100%" spam in the console.
  h2o::h2o.no_progress()
  # Ensure progress bars are restored when the function exits (even on error)
  on.exit(h2o::h2o.show_progress(), add = TRUE)

  # Extract feature names and determine which variables to process
  feature_names <- nm_extract_features(model)
  vars_for_pdp <- if (is.null(var_list)) feature_names else intersect(var_list, feature_names)

  # Prepare H2O Frame
  X_df <- if ("set" %in% colnames(df) && training_only) df[df$set == "training", ] else df
  cols_to_use <- c(feature_names, "value")
  # Intersect ensures we only select columns that actually exist in the dataframe
  df_h2o <- h2o::as.h2o(X_df[, intersect(cols_to_use, colnames(X_df))])

  # Initialize custom progress bar
  if (verbose) {
    if (!requireNamespace("progress", quietly = TRUE)) {
      stop("Package 'progress' is required for progress bars. Please install it.")
    }
    pb <- progress::progress_bar$new(
      format = "  Calculating PDP [:bar] :percent | Elapsed: :elapsed | ETA: :eta",
      total = length(vars_for_pdp), clear = FALSE, width = 80
    )
  }

  pieces <- list()

  # Iterate through variables
  for (var in vars_for_pdp) {
    tryCatch(
      {
        # Calculate partial dependence using H2O's native method
        fr <- h2o::h2o.partialPlot(
          object = model,
          newdata = df_h2o,
          cols = var,
          plot = FALSE
        )

        # Standardize output format
        out_df <- data.frame(
          variable = var,
          value = as.character(fr[[var]]), # Convert to char to handle mixed types later
          pdp_mean = fr$mean_response,
          pdp_std = fr$stddev_response
        )

        pieces[[var]] <- out_df

      },
      error = function(e) {
        log$warn("PDP failed for '%s' (H2O): %s", var, e$message)
      })

    if (verbose) pb$tick()
  }

  return(dplyr::bind_rows(pieces))
}


#' Compute PDP for Generic Models
#'
#' @description
#' Internal backend for computing PDPs using parallel processing (foreach).
#' Works with any model that supports `nm_predict`.
#'
#' @keywords internal
nm_pdp_generic <- function(df, model, var_list = NULL, training_only = TRUE, n_cores = NULL,
                           grid_points = 50, quantile_range = c(0.01, 0.99), verbose = TRUE) {

  log <- nm_get_logger("analysis.pdp.generic")
  feature_names <- nm_extract_features(model)
  vars_for_pdp <- if (is.null(var_list)) feature_names else intersect(var_list, feature_names)

  # Prepare data — add time features if missing (e.g. when df is raw input, not prepared)
  # Coerce to a plain data.frame so the data.frame-style indexing below (`X_df[i, j]`
  # with `j` as a character vector variable) is well-defined even if `df` is a data.table.
  X_df <- as.data.frame(df)
  if (!"date_unix" %in% colnames(X_df) && any(c("date_unix", "day_julian", "weekday", "hour") %in% feature_names)) {
    X_df <- nm_process_date(X_df, verbose = FALSE)
    data.table::setDT(X_df)
    X_df <- nm_add_date_variables(X_df)
    data.table::setDF(X_df)
  }
  X_df <- if ("set" %in% colnames(X_df) && training_only) {
    X_df[X_df$set == "training", feature_names, drop = FALSE]
  } else {
    X_df[, feature_names, drop = FALSE]
  }

  # Setup parallel cluster
  if (is.null(n_cores)) {
    is_r_check <- Sys.getenv("_R_CHECK_LIMIT_CORES_", "") != ""
    if (is_r_check) {
      n_cores <- 2
    } else {
      detected <- parallel::detectCores() - 1
      if (is.na(detected) || length(detected) == 0) {
        detected <- 2
      }
      n_cores <- max(1, detected)
    }
  }
  if (Sys.getenv("_R_CHECK_LIMIT_CORES_", "") != "") {
    n_cores <- min(n_cores, 2)
  }
  n_cores <- max(1, n_cores)
  cl <- parallel::makeCluster(n_cores)
  .nm_propagate_libpaths(cl)
  doSNOW::registerDoSNOW(cl)
  on.exit(parallel::stopCluster(cl), add = TRUE)

  # Setup progress bar for parallel execution
  if (verbose) {
    log$info("Calculating PDP in parallel for %d variables on %d cores...", length(vars_for_pdp), n_cores)
    if (!requireNamespace("progress", quietly = TRUE)) {
      stop("Package 'progress' is required for progress bars. Please install it.")
    }
    pb <- progress::progress_bar$new(
      format = "  Calculating PDP [:bar] :percent | Elapsed: :elapsed | ETA: :eta",
      total = length(vars_for_pdp), clear = FALSE, width = 80
    )
    opts <- list(progress = function(n) pb$tick())
  } else {
    opts <- list()
  }

  # Execute calculation in parallel
  pieces <- foreach::foreach(
    var = vars_for_pdp,
    # Explicitly export necessary internal functions and objects to workers
    .export = c(".LOGGER_NAME", "nm_get_logger", "nm_require", "%||%", "nm_predict", "nm_predict_h2o",
      "nm_predict_lgb", "nm_auto_target_mb", "nm_extract_features",
      "nm_extract_features_h2o", ".create_pdp_grid"),
    .packages = c("data.table", "lightgbm"),
    .options.snow = opts
  ) %dopar% {
    # Create grid for the current variable
    grid <- .create_pdp_grid(X_df[[var]], quantile_range, grid_points)
    if (is.null(grid)) return(NULL)

    X_work <- X_df

    # Calculate marginal effects
    pdp_results <- sapply(grid, function(g) {
      X_work[[var]] <- g
      yhat <- nm_predict(model, X_work, verbose = FALSE)
      c(mean = mean(yhat, na.rm = TRUE), sd = sd(yhat, na.rm = TRUE))
    })

    # Return results
    data.frame(
      variable = var,
      value = grid,
      pdp_mean = pdp_results["mean", ],
      pdp_std = pdp_results["sd", ]
    )
  }

  return(dplyr::bind_rows(Filter(Negate(is.null), pieces)))
}


#' Plot Partial Dependence Results (Smart Sort & Formatted)
#'
#' @description
#' Visualizes the output of `nm_pdp`.
#' Key Features:
#' 1. **Smart Sorting**: Correctly orders Numbers, Weekdays (Mon-Sun), and Months (Jan-Dec).
#' 2. **Trend-Focused Ticks**: Selects "round" numbers (ending in 0 or 5) to emphasize trends.
#' 3. **Clean Formatting**: Removes unnecessary decimals for integers or large numbers.
#'
#' @param pdp_df Output from `nm_pdp`.
#' @param ncol Number of columns for faceting.
#'
#' @export
nm_plot_pdp <- function(pdp_df, ncol = 2) {
  nm_require("ggplot2", hint = "install.packages('ggplot2')")

  # ============================================================================
  # STEP 0: Intelligent Sorting (Global)
  # Purpose: Ensure x-axis follows a logical order (Numeric -> Time -> Alphabetical)
  # instead of default alphabetical order (which causes "1, 10, 2" issues).
  # ============================================================================

  unique_vals <- unique(pdp_df$value)

  # Helper function to assign a numeric rank to every value
  get_sort_rank <- function(v) {
    v_lower <- tolower(v)

    # 1. Try to parse as Number
    num <- suppressWarnings(as.numeric(v))
    if (!is.na(num)) return(num)

    # 2. Try to parse as Weekday (Mon-Sun)
    # Assign specific ranks (0-6) so they sort chronologically
    days <- c("mon", "tue", "wed", "thu", "fri", "sat", "sun",
      "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday")
    match_idx <- match(v_lower, days)
    if (!is.na(match_idx)) {
      return((match_idx - 1) %% 7) # Normalizes 'Mon' and 'Monday' to the same rank
    }

    # 3. Try to parse as Month (Jan-Dec)
    months <- c("jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec",
      "january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december")
    match_month <- match(v_lower, months)
    if (!is.na(match_month)) {
      return((match_month - 1) %% 12)
    }

    # 4. Fallback: Return Inf (Infinity) to place categorical text at the end
    return(Inf)
  }

  # Compute ranks and sort
  rank_df <- data.frame(val = unique_vals, stringsAsFactors = FALSE)
  rank_df$rank <- sapply(unique_vals, get_sort_rank)

  # Sort order: Rank first, then alphabetical (for ties)
  sort_order <- order(rank_df$rank, rank_df$val, na.last = TRUE)
  sorted_levels <- rank_df$val[sort_order]

  # Apply sorted levels to the dataframe as a Factor
  pdp_df$value <- factor(pdp_df$value, levels = sorted_levels)

  # Sort rows to ensure the line plot draws continuously from left to right
  pdp_df <- pdp_df[order(pdp_df$variable, pdp_df$value), ]


  # ============================================================================
  # STEP 1: Smart "Round" Breaks (Trend Focused)
  # Purpose: Pick ticks that look like "0, 100, 200" rather than "1, 102, 199".
  # ============================================================================
  get_trend_breaks <- function(x) {
    # 'x' contains the factor levels (strings) for the current subplot
    nums <- suppressWarnings(as.numeric(x))

    # If categorical (contains NAs), return all values (rely on overlap check later)
    if (any(is.na(nums))) return(x)

    # Algorithm to find "Pretty" numbers:
    # n = 4: Requests fewer ticks (focus on trend, not detail).
    # min.n = 3: Ensures we have at least start, middle, end.
    # high.u.bias: Strongly prefers round numbers (multiples of 1, 2, 5, 10).
    ideal_breaks <- base::pretty(nums, n = 4, min.n = 3, high.u.bias = 1.5)

    # Snap these ideal round numbers to the *closest existing data point*
    closest_indices <- unique(sapply(ideal_breaks, function(target) {
      which.min(abs(nums - target))
    }))

    return(x[closest_indices])
  }

  # ============================================================================
  # STEP 2: Adaptive Label Formatter
  # Purpose: Remove visual noise (decimals) to emphasize the trend.
  # ============================================================================
  clean_label_formatter <- function(x) {
    sapply(x, function(val) {
      num_val <- suppressWarnings(as.numeric(val))

      # Return categorical labels (e.g., "Mon") as is
      if (is.na(num_val)) return(val)

      # Logic:
      # 1. If it's effectively an Integer (e.g., 12.00001) -> Show "12"
      # 2. If it's a Large Number (>= 100) -> Show "100" (drop decimals)
      if (abs(num_val - round(num_val)) < 0.001 || abs(num_val) >= 100) {
        return(sprintf("%.0f", num_val))
      }

      # 3. For small numbers (< 100), keep up to 3 significant digits
      # 'drop0trailing' ensures 0.50 becomes 0.5
      return(format(num_val, digits = 3, nsmall = 0, scientific = FALSE, trim = TRUE, drop0trailing = TRUE))
    })
  }

  # ============================================================================
  # STEP 3: Plot Construction
  # ============================================================================
  ggplot2::ggplot(pdp_df, ggplot2::aes(x = value, y = pdp_mean, group = variable)) +

    # Line for trend (Using 'linewidth' instead of deprecated 'size')
    ggplot2::geom_line(color = "#0073C2", linewidth = 1) +
    # Points to show actual data density (optional, kept small)
    ggplot2::geom_point(size = 1.5, alpha = 0.5) +

    # Facet with free X scales allows different ranges per feature
    ggplot2::facet_wrap(~variable, scales = "free_x", ncol = ncol) +

    # Apply the custom break and label logic
    ggplot2::scale_x_discrete(
      breaks = get_trend_breaks,       # Selects the "roundest" indices
      labels = clean_label_formatter,  # Removes decimals
      guide = ggplot2::guide_axis(check.overlap = TRUE) # Prevents text collision
    ) +

    ggplot2::labs(
      title = "Partial Dependence Plots",
      y = "Mean Predicted Response",
      x = "Feature Value"
    ) +
    ggplot2::theme_minimal() +
    ggplot2::theme(
      strip.background = ggplot2::element_rect(fill = "grey90", color = NA),
      strip.text = ggplot2::element_text(face = "bold"),
      # Horizontal text is cleaner for reading trends
      axis.text.x = ggplot2::element_text(angle = 0, hjust = 0.5, size = 9)
    )
}
