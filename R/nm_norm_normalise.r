#' Format a quantile probability as a column name (e.g. 0.025 -> "q025")
#'
#' Mirrors normet-py's \code{_format_quantile_name} so quantile column names
#' match exactly across languages.
#'
#' @keywords internal
.nm_format_quantile_name <- function(q) {
  q <- as.numeric(q)
  if (q < 0 || q > 1) stop("Quantile must be in [0,1]: got ", q)
  sprintf("q%03d", round(q * 1000))
}


#' Generate a Resampled Data Frame (data.table version)
#'
#' @keywords internal
nm_generate_resampled <- function(df, resample_vars, replace, seed, resample_df) {
  missing_cols <- setdiff(resample_vars, colnames(resample_df))
  if (length(missing_cols) > 0) {
    stop("`resample_df` is missing required columns: ", paste(missing_cols, collapse = ", "))
  }

  set.seed(seed)
  sample_indices <- sample(nrow(resample_df), size = nrow(df), replace = replace)

  # Build output by combining static columns + freshly sampled columns.
  # Avoids a full copy(df) followed by immediate overwrite of resample_vars.
  static_cols <- setdiff(colnames(df), resample_vars)
  out <- data.table::data.table(
    df[, static_cols, with = FALSE],
    resample_df[sample_indices, resample_vars, with = FALSE],
    seed = seed
  )

  # Restore original column order (static cols first, then resample vars, seed appended)
  orig_order <- c(intersect(colnames(df), c(static_cols, resample_vars)), "seed")
  data.table::setcolorder(out, intersect(orig_order, colnames(out)))

  return(out)
}


#' Normalise a Time Series Using a Trained Model
#'
#' \code{nm_normalise} is a high-level wrapper that deweathers a time series. It
#' dispatches to a specific implementation based on the model's backend attribute.
#'
#' @param df The input data frame.
#' @param model The trained model object.
#' @param verbose Logical. If TRUE, prints dispatch info. Default is TRUE.
#' @param ... Additional arguments passed to the implementation function
#'        (e.g., `n_samples`, `aggregate`, `resample_vars` for H2O).
#'
#' @return A data frame containing the normalised results.
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
#'   norm <- nm_normalise(
#'     build$df_prep, build$model,
#'     resample_vars = covariates, n_samples = 5, n_cores = 1, verbose = FALSE
#'   )
#'   head(norm)
#' }
#' }
#'
#' @export
nm_normalise <- function(df, model, verbose = TRUE, ...) {
  log <- nm_get_logger("analysis.normalise")

  # --- 1. Backend Detection + Dispatch ---
  model_backend <- nm_detect_backend(model)
  if (!is.null(model_backend) && startsWith(model_backend, "h2o")) {
    if (verbose) log$info("Dispatching to H2O backend for normalisation.")
    return(nm_normalise_h2o(df = df, model = model, verbose = verbose, ...))

  } else if (!is.null(model_backend) && model_backend == "lightgbm") {
    if (verbose) log$info("Dispatching to lightgbm backend for normalisation.")
    return(nm_normalise_lgb(df = df, model = model, verbose = verbose, ...))

  } else {
    backend_name <- if (is.null(model_backend)) "NULL" else model_backend
    err_msg <- paste("Unsupported or unidentified model backend for normalisation:", backend_name)
    log$error(err_msg)
    stop(err_msg)
  }
}


#' Normalise Data using an H2O Model (Auto-Feature Detection)
#'
#' @description
#' `nm_normalise_h2o` performs meteorological normalisation (deweathering) using a trained H2O model.
#'
#' **Key Features:**
#' \enumerate{
#'   \item **Auto-Feature Detection**: Automatically extracts predictor names from the H2O model.
#'   \item **Resource Optimized**: Automatically restricts R side parallelism to 2 cores to reserve CPU/RAM for H2O.
#'   \item **Memory Safety**: Uses "Auto-Batching" to chunk data and prevent H2O timeouts.
#'   \item **Smart Disk Offloading**: Automatically switches to disk (Parquet) if output > 50M rows.
#' }
#'
#' @param df The input data frame or data.table. Must contain a 'date' column.
#' @param model The trained H2O model object (class `H2OModel`).
#' @param resample_vars A character vector of variables to be resampled.
#'        If NULL, defaults to all model features excluding time components.
#' @param n_samples Integer. Total number of resampling iterations (e.g., 300 or 1000).
#' @param samples_per_batch Integer or NULL. Auto-calculated if NULL.
#' @param replace Logical. Whether to sample weather conditions with replacement. Default is TRUE.
#' @param aggregate Logical. TRUE returns mean per date; FALSE returns all simulations.
#' @param seed Integer. Random seed for reproducibility.
#' @param resample_df External data frame to sample weather from. If NULL, `df` is used.
#' @param memory_save Logical. If TRUE, enables aggressive GC and strict batching.
#' @param verbose Logical. If TRUE, prints detailed logs.
#' @param output_dir Character (Optional). Directory for disk offloading.
#' @param file_format Character. "parquet", "csv", or "rds". Default "parquet".
#' @param n_cores Integer or NULL. If provided, overrides the conservative
#'        default of 2 R-side resampling workers (still capped at
#'        \code{detectCores() - 1}). Ignored if \code{cl} is supplied.
#' @param cl Optional existing parallel cluster object.
#'
#' @return A data frame (if aggregated or small raw) or file paths (if disk offloading).
#' @export
nm_normalise_h2o <- function(df, model, resample_vars = NULL,
                             n_samples = 300, samples_per_batch = NULL,
                             replace = TRUE, aggregate = TRUE, seed = 7654321,
                             resample_df = NULL, memory_save = TRUE, verbose = TRUE,
                             output_dir = NULL, file_format = "parquet",
                             n_cores = NULL, cl = NULL) {

  log <- nm_get_logger("analysis.normalise.h2o")
  nm_require("h2o", hint = "install.packages('h2o')")
  nm_require("data.table", hint = "install.packages('data.table')")

  # --- 1. Auto-Detect Feature Names ---
  # H2O models store the predictor names in the @parameters$x slot.
  if (inherits(model, "H2OModel")) {
    predictors <- model@parameters$x
    if (is.null(predictors) || length(predictors) == 0) {
      try(
        {
          predictors <- h2o::h2o.varimp(model)$variable
        },
        silent = TRUE)
    }
    if (is.null(predictors) || length(predictors) == 0) {
      stop("Could not auto-detect feature names from the H2O model. Is the model object valid?")
    }
  } else {
    stop("The provided 'model' argument is not a valid H2OModel object.")
  }

  if (verbose) log$info("Auto-detected %d features from the model.", length(predictors))

  # --- 2. Validation & Format Setup ---
  file_format <- match.arg(file_format, c("parquet", "csv", "rds"))
  if (file_format == "parquet") nm_require("arrow", hint = "install.packages('arrow')")

  df <- data.table::as.data.table(df)
  if (!is.null(resample_df)) resample_df <- data.table::as.data.table(resample_df)

  # --- 3. Smart Output Validation & Auto-Offloading ---
  if (!aggregate) {
    n_rows_input <- as.numeric(nrow(df))
    n_samples_num <- as.numeric(n_samples)
    total_predicted_rows <- n_rows_input * n_samples_num
    RAM_SAFE_THRESHOLD <- 50 * 10^6 # 50 Million rows

    if (is.null(output_dir) && total_predicted_rows > RAM_SAFE_THRESHOLD) {
      temp_id <- format(Sys.time(), "%Y%m%d_%H%M%S")
      folder_name <- paste0("simulated_batches_", temp_id)
      output_dir <- file.path(getwd(), folder_name)

      if (verbose) {
        log$warn("High RAM Usage Projected!")
        log$info("   -> Predicted Output: %.1f million rows (Safe Limit: %.1f million).",
          total_predicted_rows / 1e6, RAM_SAFE_THRESHOLD / 1e6)
        log$info("   -> Action: Switching to Disk Offloading (%s) at '%s'", toupper(file_format), output_dir)
      }
      if (!dir.exists(output_dir)) dir.create(output_dir, recursive = TRUE)
    }
  }

  if (!is.null(output_dir)) {
    if (!dir.exists(output_dir)) dir.create(output_dir, recursive = TRUE)
    if (verbose) log$info("Disk Offloading ON: Saving results to '%s'.", output_dir)
  }

  # --- 4. Data Preparation ---
  if (verbose) log$info("Step 1/4: Preparing data...")

  df <- nm_process_date(df)
  df <- nm_check_data(df, predictors, "value")

  if (is.null(resample_df)) resample_df <- df

  # Helper to sanitize categorical columns
  sanitize_dt_inplace <- function(dt, name_tag) {
    cat_cols <- names(dt)[sapply(dt, function(x) is.factor(x) || is.character(x))]
    cat_cols <- intersect(cat_cols, predictors)
    if (length(cat_cols) > 0) {
      if (verbose) log$info("Sanitizing %d categorical columns in '%s'...", length(cat_cols), name_tag)
      for (col in cat_cols) {
        if (any(is.na(dt[[col]]))) dt[is.na(get(col)), (col) := "Missing"]
        if (!is.factor(dt[[col]])) dt[, (col) := as.factor(get(col))]
      }
    }
  }

  sanitize_dt_inplace(df, "input df")
  if (!identical(df, resample_df)) sanitize_dt_inplace(resample_df, "resample_df")

  time_vars <- c("date_unix", "day_julian", "weekday", "hour")
  if (is.null(resample_vars)) {
    resample_vars <- setdiff(predictors, time_vars)
  }

  # --- 5. Parallel Cluster Setup ---
  manage_cluster_locally <- is.null(cl)
  if (manage_cluster_locally) {
    # STRATEGY: R Resampling is memory-bound but fast. H2O prediction is CPU-bound.
    # To avoid thrashing, we severely limit R side concurrency.
    # We use at most 2 cores for R, leaving the rest (N-2) for H2O.
    avail_cores <- parallel::detectCores(logical = FALSE)
    if (is.na(avail_cores)) avail_cores <- parallel::detectCores(logical = TRUE)

    # Cap R workers at 2 by default. This is sufficient to feed H2O without
    # stealing its resources. An explicit `n_cores` overrides this cap.
    r_cores <- if (!is.null(n_cores)) {
      max(1, min(as.integer(n_cores), avail_cores - 1))
    } else {
      max(1, min(2, avail_cores - 1))
    }

    if (verbose) {
      log$info("Parallel Resampling: Using %d R-worker(s)%s.", r_cores,
        if (is.null(n_cores)) " (Conservative mode)" else "")
    }

    cl <- parallel::makeCluster(r_cores)
    .nm_propagate_libpaths(cl)
    on.exit(parallel::stopCluster(cl), add = TRUE)
  }
  doSNOW::registerDoSNOW(cl)

  # --- 6. Batch Size Calculation ---
  set.seed(seed)
  random_seeds <- sample(1:1000000, n_samples, replace = FALSE)

  if (memory_save) {
    if (is.null(samples_per_batch)) {
      one_sample_size <- as.numeric(object.size(df))
      safe_payload_bytes <- 400 * 1024^2 # 400MB
      calculated_size <- floor(safe_payload_bytes / one_sample_size)
      chunk_size <- max(1, min(calculated_size, 200, n_samples))
      if (verbose) log$info("Auto-Batching: Calculated safe batch size = %d samples.", chunk_size)
    } else {
      chunk_size <- min(samples_per_batch, n_samples)
    }
  } else {
    chunk_size <- n_samples
    if (verbose) log$info("Memory Save OFF: Processing all %d samples in a single batch.", n_samples)
  }

  seed_chunks <- split(random_seeds, ceiling(seq_along(random_seeds) / chunk_size))
  total_batches <- length(seed_chunks)

  if (verbose) {
    log$info("Execution Plan: Processing %d total samples in %d batch(es).", n_samples, total_batches)
    if (requireNamespace("progress", quietly = TRUE)) {
      pb <- progress::progress_bar$new(
        total = total_batches,
        format = "  Progress [:bar] :percent | Batch :current/:total | ETA: :eta",
        width = 80, clear = FALSE
      )
    }
  }

  # --- 7. Core Execution Loop ---
  running_stats <- NULL
  results_list  <- NULL
  saved_files   <- character()

  store_in_ram <- !aggregate && is.null(output_dir)
  if (store_in_ram) results_list <- vector("list", total_batches)

  samples_processed_count <- 0

  for (i in seq_along(seed_chunks)) {
    current_seeds <- seed_chunks[[i]]
    if (verbose && exists("pb")) {
      samples_processed_count <- samples_processed_count + length(current_seeds)
      pb$tick()
    }

    # 7.1 Generate Resampled Data (Parallel R)
    resampled_batch_list <- foreach::foreach(
      s = current_seeds, .packages = c("data.table"),
      .export = "nm_generate_resampled"
    ) %dopar% {
      nm_generate_resampled(df, resample_vars, replace, s, resample_df)
    }
    df_batch <- data.table::rbindlist(resampled_batch_list)

    # 7.2 Predict (H2O)
    # Explicitly using nm_predict_h2o for clarity and efficiency
    # Note: df_batch is a data.table here
    preds_batch <- nm_predict_h2o(model, df_batch, verbose = FALSE)

    # 7.3 Process Results
    if (aggregate) {
      batch_dt <- data.table::data.table(date = df_batch$date, observed = df_batch$value, normalised = preds_batch)
      batch_stats <- batch_dt[, .(sum_norm = sum(normalised, na.rm = T), n_norm = sum(!is.na(normalised)), sum_obs = sum(observed, na.rm = T), n_obs = sum(!is.na(observed))), by = date]

      if (is.null(running_stats)) {
        running_stats <- batch_stats
      } else {
        running_stats <- data.table::rbindlist(list(running_stats, batch_stats))
        running_stats <- running_stats[, .(sum_norm = sum(sum_norm), n_norm = sum(n_norm), sum_obs = sum(sum_obs), n_obs = sum(n_obs)), by = date]
      }
      rm(batch_dt, batch_stats)
    } else {
      batch_result <- data.table::data.table(
        date = df_batch$date,
        observed = df_batch$value,
        normalised = preds_batch,
        seed = df_batch$seed
      )

      if (!is.null(output_dir)) {
        if (i == 1) {
          batch_wide <- data.table::dcast(batch_result, date + observed ~ seed, value.var = "normalised")
        } else {
          batch_wide <- data.table::dcast(batch_result, date ~ seed, value.var = "normalised")
        }

        file_ext <- switch(file_format, parquet = ".parquet", csv = ".csv", rds = ".rds")
        file_name <- file.path(output_dir, paste0("batch_wide_", i, file_ext))

        if (file_format == "parquet") arrow::write_parquet(batch_wide, file_name)
        else if (file_format == "rds") saveRDS(batch_wide, file_name)
        else data.table::fwrite(batch_wide, file_name)

        saved_files <- c(saved_files, file_name)
        rm(batch_result, batch_wide)
      } else {
        results_list[[i]] <- batch_result
      }
    }

    # 7.4 Cleanup
    rm(df_batch, resampled_batch_list, preds_batch)
    if (memory_save) {
      gc(verbose = FALSE)
    }
  }

  # --- 8. Final Output Generation ---
  if (aggregate) {
    if (verbose) log$info("Finalizing aggregated results...")
    df_out <- running_stats[, .(date = date, observed = sum_obs / n_obs, normalised = sum_norm / n_norm)]
    data.table::setorder(df_out, date)
    if (verbose) log$info("Normalisation complete.")
    data.table::setDF(df_out)
    return(df_out)
  } else {
    if (!is.null(output_dir)) {
      if (verbose) log$info("Success: Saved %d %s files to '%s'.", length(saved_files), toupper(file_format), output_dir)
      return(saved_files)
    } else {
      if (verbose) log$info("Finalizing raw results in memory...")
      df_result <- data.table::rbindlist(results_list)
      wide <- data.table::dcast(df_result, date ~ seed, value.var = "normalised")
      observed <- unique(df_result[, .(date, observed)])
      df_out <- merge(observed, wide, by = "date", all = TRUE)
      data.table::setDF(df_out)
      return(df_out)
    }
  }
}


#' Normalise Data Using a lightgbm Model (In-Process, No JVM)
#'
#' A lightweight normalisation path for lightgbm models. Unlike the H2O path,
#' all resampling and prediction happens in the R process — no serialization,
#' no JVM overhead.
#'
#' @param df Input data frame or data.table. Must contain a \code{date} column.
#' @param model A lightgbm Booster object with attribute \code{backend = "lightgbm"}.
#' @param resample_vars Character vector of variables to resample.
#'   If NULL, uses \code{model$feature_names} minus time variables.
#' @param n_samples Number of resampling iterations. Default 300.
#' @param replace Sample with replacement. Default TRUE.
#' @param aggregate If TRUE (default), returns mean per date.
#'   If FALSE, returns all iterations (one row per sample).
#' @param seed Random seed. Default 7654321.
#' @param resample_df External pool to sample from. If NULL, uses \code{df}.
#' @param memory_save If TRUE, processes in smaller batches. Default TRUE.
#' @param verbose Logical. Default TRUE.
#' @param n_cores Integer or NULL. Number of parallel workers for resampling.
#'   If NULL, uses \code{min(detectCores(logical = FALSE) - 1, 4)}.
#' @param return_quantiles Numeric vector of probabilities in [0,1] (e.g.
#'   \code{c(0.025, 0.5, 0.975)}), or NULL (default). When supplied, the
#'   output gains one column per quantile (named \code{qXXX}, e.g.
#'   \code{q025}), giving a prediction interval on the deweathered signal
#'   itself -- not to be confused with \code{nm_conformal_effect_interval()},
#'   which is a conformal interval on a \emph{causal (SCM) effect estimate}.
#'   Ports normet-py's \code{normalise(..., return_quantiles=...)}.
#'   \strong{Memory note}: quantiles require the full per-date, per-seed
#'   sample distribution, so supplying \code{return_quantiles} switches off
#'   the O(1) running-sum/transient-batch accumulation (Sect. "Transient
#'   memory pipeline") in favour of materialising all \code{n_samples}
#'   predictions per row -- O(n_samples x nrow(df)) memory, same as
#'   \code{aggregate=FALSE}. This mirrors normet-py's own behaviour: FLAML/
#'   lightgbm's \code{return_quantiles} likewise bypasses its \code{batch_size}
#'   O(1) pipeline for the same reason (quantiles are not summarisable via a
#'   running sum). Ignored (with a warning) if \code{aggregate=FALSE}, since
#'   the full per-seed table is already returned in that case.
#'
#' @return A data frame with normalised results. If \code{return_quantiles}
#'   is set, includes one \code{qXXX} column per requested quantile.
#' @export
nm_normalise_lgb <- function(df, model, resample_vars = NULL,
                             n_samples = 300, replace = TRUE,
                             aggregate = TRUE, seed = 7654321,
                             resample_df = NULL, memory_save = TRUE,
                             verbose = TRUE, n_cores = NULL,
                             return_quantiles = NULL) {

  if (!is.null(return_quantiles)) {
    if (any(return_quantiles < 0 | return_quantiles > 1)) {
      stop("`return_quantiles` must all be in [0, 1].")
    }
    if (!aggregate) {
      warning("`return_quantiles` is ignored when aggregate=FALSE (the full per-seed table already contains everything needed to compute quantiles yourself).")
      return_quantiles <- NULL
    }
  }
  want_quantiles <- !is.null(return_quantiles)

  log <- nm_get_logger("analysis.normalise.lgb")
  nm_require("data.table")
  nm_require("lightgbm")

  df <- data.table::as.data.table(df)
  if (!is.null(resample_df)) resample_df <- data.table::as.data.table(resample_df)

  # --- 1. Feature detection ---
  predictors <- attr(model, "feature_names")
  if (is.null(predictors)) {
    predictors <- model$feature_names
  }
  if (is.null(predictors)) stop("Could not detect feature names from lightgbm model.")

  # --- 2. Prepare data ---
  df <- nm_process_date(df)
  df <- nm_check_data(df, predictors, "value")

  if (is.null(resample_df)) resample_df <- df

  time_vars <- c("date_unix", "day_julian", "weekday", "hour")
  if (is.null(resample_vars)) {
    resample_vars <- setdiff(predictors, time_vars)
  }

  # --- 3. Generate seeds ---
  set.seed(seed)
  random_seeds <- sample(1:1e6, n_samples, replace = FALSE)

  # --- 4. Batch size ---
  if (memory_save) {
    one_sample_size <- as.numeric(utils::object.size(df))
    safe_bytes <- 400 * 1024^2
    chunk_size <- max(1L, min(floor(safe_bytes / max(one_sample_size, 1)), n_samples))
  } else {
    chunk_size <- n_samples
  }
  seed_chunks <- split(random_seeds, ceiling(seq_along(random_seeds) / chunk_size))

  # --- 5. Resampling parallelism ---
  if (!is.null(n_cores)) {
    r_cores <- max(1L, as.integer(n_cores))
  } else {
    avail <- parallel::detectCores(logical = FALSE)
    if (is.na(avail)) avail <- parallel::detectCores(logical = TRUE)
    r_cores <- max(1L, min(avail - 1L, 4L))
  }
  if (Sys.getenv("_R_CHECK_LIMIT_CORES_", "") != "") {
    r_cores <- min(r_cores, 2L)
  }

  cl <- parallel::makeCluster(r_cores)
  .nm_propagate_libpaths(cl)
  on.exit(parallel::stopCluster(cl), add = TRUE)
  doSNOW::registerDoSNOW(cl)

  if (verbose) {
    log$info("lightgbm normalisation: %d samples, %d batches, %d cores",
      n_samples, length(seed_chunks), r_cores)
    pb <- progress::progress_bar$new(total = length(seed_chunks),
      format = "  Progress [:bar] :percent | Batch :current/:total | ETA: :eta",
      width = 80, clear = FALSE)
  }

  # --- 6. Core loop ---
  running_stats <- NULL
  results_list <- NULL
  # `want_quantiles` needs the full per-date, per-seed sample matrix, so it
  # forces the same "store every batch in RAM" path as aggregate=FALSE
  # instead of the O(1) running-sum accumulation used otherwise.
  store_in_ram <- !aggregate || want_quantiles
  if (store_in_ram) results_list <- vector("list", length(seed_chunks))

  for (i in seq_along(seed_chunks)) {
    current_seeds <- seed_chunks[[i]]
    if (verbose && exists("pb")) pb$tick()

    # Resample in parallel
    resampled_batch_list <- foreach::foreach(
      s = current_seeds, .packages = c("data.table"),
      .export = "nm_generate_resampled"
    ) %dopar% {
      nm_generate_resampled(df, resample_vars, replace, s, resample_df)
    }
    df_batch <- data.table::rbindlist(resampled_batch_list)

    # Predict in-process (no serialization)
    preds_batch <- nm_predict_lgb(model, df_batch, verbose = FALSE)

    if (want_quantiles) {
      # Store the full batch (needed for quantiles) AND keep the O(1)
      # running-sum mean, so the final mean matches the non-quantile path
      # exactly rather than being recomputed from the (identical) stored data.
      batch_dt <- data.table::data.table(
        date = df_batch$date, observed = df_batch$value, normalised = preds_batch)
      batch_stats <- batch_dt[, .(
        sum_norm = sum(normalised, na.rm = TRUE),
        n_norm = sum(!is.na(normalised)),
        sum_obs  = sum(observed, na.rm = TRUE),
        n_obs    = sum(!is.na(observed))
      ), by = date]
      if (is.null(running_stats)) {
        running_stats <- batch_stats
      } else {
        running_stats <- data.table::rbindlist(list(running_stats, batch_stats))
        running_stats <- running_stats[, .(
          sum_norm = sum(sum_norm), n_norm = sum(n_norm),
          sum_obs  = sum(sum_obs),  n_obs   = sum(n_obs)
        ), by = date]
      }
      results_list[[i]] <- batch_dt[, .(date, normalised)]
      rm(batch_dt, batch_stats)
    } else if (aggregate) {
      batch_dt <- data.table::data.table(
        date = df_batch$date, observed = df_batch$value, normalised = preds_batch)
      batch_stats <- batch_dt[, .(
        sum_norm = sum(normalised, na.rm = TRUE),
        n_norm = sum(!is.na(normalised)),
        sum_obs  = sum(observed, na.rm = TRUE),
        n_obs    = sum(!is.na(observed))
      ), by = date]

      if (is.null(running_stats)) {
        running_stats <- batch_stats
      } else {
        running_stats <- data.table::rbindlist(list(running_stats, batch_stats))
        running_stats <- running_stats[, .(
          sum_norm = sum(sum_norm), n_norm = sum(n_norm),
          sum_obs  = sum(sum_obs),  n_obs   = sum(n_obs)
        ), by = date]
      }
      rm(batch_dt, batch_stats)
    } else {
      batch_result <- data.table::data.table(
        date = df_batch$date, observed = df_batch$value,
        normalised = preds_batch, seed = df_batch$seed)
      results_list[[i]] <- batch_result
      rm(batch_result)
    }
    rm(df_batch, resampled_batch_list, preds_batch)
    if (memory_save) gc(verbose = FALSE)
  }

  # --- 7. Assemble output ---
  if (want_quantiles) {
    df_out <- running_stats[, .(date = date, observed = sum_obs / n_obs,
      normalised = sum_norm / n_norm)]
    data.table::setorder(df_out, date)

    all_samples <- data.table::rbindlist(results_list)
    q_names <- vapply(return_quantiles, .nm_format_quantile_name, character(1))
    q_dt <- all_samples[, as.list(stats::setNames(
      stats::quantile(normalised, probs = return_quantiles, na.rm = TRUE, names = FALSE),
      q_names)), by = date]

    df_out <- merge(df_out, q_dt, by = "date", all.x = TRUE)
    data.table::setorder(df_out, date)
    data.table::setDF(df_out)
    if (verbose) log$info("Normalisation complete (with %d quantile column(s)).", length(return_quantiles))
    return(df_out)
  } else if (aggregate) {
    df_out <- running_stats[, .(date = date, observed = sum_obs / n_obs,
      normalised = sum_norm / n_norm)]
    data.table::setorder(df_out, date)
    data.table::setDF(df_out)
    if (verbose) log$info("Normalisation complete.")
    return(df_out)
  } else {
    df_result <- data.table::rbindlist(results_list)
    wide <- data.table::dcast(df_result, date ~ seed, value.var = "normalised")
    observed <- unique(df_result[, .(date, observed)])
    df_out <- merge(observed, wide, by = "date", all = TRUE)
    data.table::setDF(df_out)
    return(df_out)
  }
}


#' Auto-Adaptive Weather Normalisation (Auto-Pilot)
#'
#' @description
#' An "Auto-Pilot" wrapper for `nm_normalise` that automatically determines the
#' optimal number of resampling iterations required for convergence.
#'
#' @details
#' Instead of guessing `n_samples` (e.g., 1000), this function:
#'
#' 1. Runs simulations in small batches (e.g., 100 samples).
#' 2. Accumulates the daily sums and counts.
#' 3. Monitors the stability of the global mean normalised concentration.
#' 4. Stops when the global mean changes by less than `convergence_tol` for `stability_streak` checks.
#'
#' @param df Input data frame/data.table.
#' @param model Trained model object.
#' @param resample_vars Variables to resample.
#' @param resample_df Data pool to sample from.
#' @param convergence_tol Numeric (0.005) or String ("0.5%"). Stability threshold.
#' @param stability_streak Integer. Consecutive checks required to trigger stop. Default 5.
#' @param batch_size Integer. Samples per iteration. Default 100.
#' @param max_samples Integer. Hard limit to prevent infinite loops. Default 5000.
#' @param verbose Logical. Print progress.
#' @param ... Additional arguments forwarded to each batch's [nm_normalise()]
#'        call (e.g. `n_cores`, `seed`, `replace`, `memory_save`,
#'        `feature_names`).
#'
#' @param return_history Logical. If TRUE, also return a per-batch
#'   convergence trace (`n`, `global_mean`, `rel_change`) -- useful for
#'   visualising/auditing the convergence path (e.g. the "tolerance
#'   tunnel" diagnostic plot). Default FALSE.
#'
#' @return A list containing:
#' * `best_n`: Total samples used.
#' * `res`: Data frame with `date`, `observed`, `normalised`.
#' * `history`: (only if `return_history=TRUE`) data frame with one row
#'   per batch: `n` (cumulative samples), `global_mean`, `rel_change`.
#'
#' @export
nm_normalise_auto <- function(df, model, resample_vars = NULL,
                              resample_df = NULL,
                              convergence_tol = "0.5%",
                              stability_streak = 5,
                              batch_size = 100,
                              max_samples = 5000,
                              seed = 7654321,
                              verbose = TRUE,
                              return_history = FALSE,
                              ...) {
  # NOTE: `seed` is varied per batch below (seed + total_n) so each batch
  # draws an independent Monte-Carlo resample. Without this, every batch
  # would call nm_normalise() with the identical seed and therefore produce
  # bit-identical resampled predictions, making the convergence check
  # meaningless (the "global mean" would trivially be constant from the
  # second batch onward regardless of true stability). Do not pass `seed`
  # via `...` -- it is intercepted below and ignored if supplied that way.
  dots <- list(...)
  dots$seed <- NULL

  # --- 0. Argument Pre-processing ---
  if (is.character(convergence_tol)) {
    if (grepl("%", convergence_tol)) {
      val_num <- as.numeric(gsub("%", "", convergence_tol))
      if (is.na(val_num)) stop("Invalid format for `convergence_tol`.")
      convergence_tol <- val_num / 100
    } else {
      convergence_tol <- as.numeric(convergence_tol)
    }
  }

  if (!requireNamespace("data.table", quietly = TRUE)) stop("data.table is required")
  df <- data.table::as.data.table(df)
  if (is.null(resample_df)) resample_df <- df

  # --- 1. Initialize State ---
  total_n <- 0
  stable_count <- 0
  prev_global_mean <- 0
  history_list <- if (return_history) list() else NULL

  # Accumulator Table: Stores running sums for each date
  # Key: date, Value: sum_norm, n_obs
  accumulator_dt <- df[, .(date, observed = if ("value" %in% names(df)) value else get(grep("obs|value", names(df), value = T)[1]))]
  accumulator_dt[, `:=`(sum_norm = 0, n_total = 0)]
  data.table::setkey(accumulator_dt, date)

  if (verbose) {
    message(sprintf("Starting Auto-Normalisation (Tol: %.2f%%, Batch: %d)", convergence_tol * 100, batch_size))
    pb <- txtProgressBar(min = 0, max = max_samples, style = 3)
  }

  # --- 2. Main Loop ---
  while (total_n < max_samples) {
    # === Step A: Run Batch (Aggregate = TRUE) ===
    # seed = seed + total_n varies every batch (matches nm_rolling's
    # seed + i pattern) so each batch is an independent Monte-Carlo draw.
    batch_res <- tryCatch(
      {
        do.call(nm_normalise, c(list(
          df = df,
          model = model,
          resample_vars = resample_vars,
          resample_df = resample_df,
          n_samples = batch_size,
          aggregate = TRUE,
          seed = seed + total_n,
          verbose = FALSE
        ), dots))
      },
      error = function(e) stop("Batch simulation failed: ", e$message))

    data.table::setDT(batch_res)

    # === Step B: Update Accumulators ===
    # Merge batch results into accumulator
    # Mathematical logic:
    # batch_res$normalised is the mean of 'batch_size' samples.
    # So the sum contribution is: batch_mean * batch_size
    accumulator_dt[batch_res, `:=`(
      sum_norm = sum_norm + (i.normalised * batch_size),
      n_total  = n_total + batch_size
    ), on = "date"]

    # === Step C: Check Convergence ===
    # Calculate current global mean (average of all normalised values across all time)
    daily_means <- accumulator_dt$sum_norm / accumulator_dt$n_total
    current_global_mean <- mean(daily_means, na.rm = TRUE)

    total_n <- total_n + batch_size

    rel_change <- NA_real_
    if (total_n > batch_size) {
      # Calculate relative change from previous total state
      rel_change <- abs((current_global_mean - prev_global_mean) / prev_global_mean)

      if (!is.na(rel_change) && rel_change < convergence_tol) {
        stable_count <- stable_count + 1
      } else {
        stable_count <- 0
      }

      if (verbose) setTxtProgressBar(pb, total_n)

      if (return_history) {
        history_list[[length(history_list) + 1]] <- data.frame(
          n = total_n, global_mean = current_global_mean,
          rel_change = rel_change, stable_count = stable_count)
      }

      if (stable_count >= stability_streak) {
        if (verbose) {
          message(sprintf("\n\n--- Convergence Reached! ---"))
          message(sprintf("Stopped at n = %d | Final Global Mean: %.4f | Change: %.5f%%",
            total_n, current_global_mean, rel_change * 100))
        }
        break
      }
    } else if (return_history) {
      history_list[[length(history_list) + 1]] <- data.frame(
        n = total_n, global_mean = current_global_mean,
        rel_change = NA_real_, stable_count = 0L)
    }

    prev_global_mean <- current_global_mean

    # GC periodically
    if (total_n %% (batch_size * 10) == 0) gc(verbose = FALSE)
  }

  if (verbose) close(pb)
  if (total_n >= max_samples) warning("Reached max_samples limit without strict convergence.")

  # --- 3. Finalize ---
  accumulator_dt[, normalised := sum_norm / n_total]

  # Return standardized format
  final_data <- accumulator_dt[, .(date, observed, normalised)]
  data.table::setDF(final_data)

  out <- list(
    best_n = total_n,
    res = final_data
  )
  if (return_history) {
    out$history <- if (length(history_list) > 0) do.call(rbind, history_list) else data.frame()
  }
  out
}
