#' Safely Initialize H2O Cluster
#'
#' @description
#' Initializes a local or remote H2O cluster with memory and core settings.
#' Handles connection failures, retries initialization, and logs cluster info robustly.
#'
#' @details
#' This function performs the following steps:
#' \enumerate{
#'   \item **Check Existing Connection**: If H2O is already running, it reuses the connection.
#'   \item **Hardware Detection**: Auto-detects available cores (System - 1) and RAM (if configured).
#'   \item **Retry Logic**: Attempts to start the JVM multiple times if the first attempt fails.
#'   \item **Logging**: Captures and logs cluster metadata (version, memory, cores) without duplicating output to the console.
#' }
#'
#' @param n_cores Number of CPU cores to use.
#'        If NULL (default), uses (Total Physical Cores - 2).
#' @param max_mem_size Maximum memory allocation (e.g. "16G").
#'        If NULL (default), it attempts to auto-allocate 75 percent of physical RAM.
#' @param verbose Whether to print progress and cluster info. Default is TRUE.
#' @param max_retries Number of times to retry initialization if it fails. Default is 2.
#' @param retry_delay Seconds to wait between retries. Default is 5.
#' @param port Port for H2O cluster. Default is 54321.
#'
#' @return H2O connection object (invisible)
#' @export
nm_init_h2o <- function(n_cores = NULL, max_mem_size = NULL,
                        verbose = TRUE, max_retries = 2,
                        retry_delay = 5, port = 54321) {

  log <- nm_get_logger("h2o.init")
  nm_require("h2o", hint = "install.packages('h2o')")

  # --- Logic 1: Determine number of threads (Cores - 2) ---
  if (!is.null(n_cores)) {
    nthreads <- as.integer(n_cores)
    user_specified_cores <- TRUE
  } else {
    user_specified_cores <- FALSE

    # Detect PHYSICAL cores (Performance > Hyper-threading)
    # H2O performs better with physical cores for dense matrix math.
    sys_cores <- parallel::detectCores(logical = FALSE)

    # Fallback: If physical detection fails (returns NA/0), use logical
    if (is.na(sys_cores) || length(sys_cores) == 0) {
      sys_cores <- parallel::detectCores(logical = TRUE)
      core_type <- "Logical"
    } else {
      core_type <- "Physical"
    }

    # Reserve 2 cores for R/OS to prevent system freeze
    # Ensure at least 1 core is allocated to H2O
    nthreads <- max(1, sys_cores - 2)

    if (verbose) log$info("Auto-configured H2O cores: %d (System: %d %s Cores)", nthreads, sys_cores, core_type)
  }

  # --- Logic 2: Determine Memory (Smart Auto-Allocation) ---
  if (!is.null(max_mem_size)) {
    # User provided a specific value (e.g., "12G")
    final_mem <- max_mem_size
  } else {
    # Auto-calculate: Try to use 'memuse' package to detect RAM
    final_mem <- "8G" # Safe fallback default

    if (requireNamespace("memuse", quietly = TRUE)) {
      tryCatch(
        {
          # Get total physical RAM
          sys_ram <- memuse::Sys.meminfo()
          # Calculate 75% of RAM
          ram_bytes <- as.numeric(sys_ram$totalram)
          target_bytes <- ram_bytes * 0.75

          # Convert to GB string for H2O (e.g., "12g")
          target_gb <- floor(target_bytes / (1024^3))
          if (target_gb > 1) {
            final_mem <- paste0(target_gb, "g")
            if (verbose) log$info("Auto-detected RAM. Setting H2O memory to %s (75%% of System)", final_mem)
          }
        },
        error = function(e) {
          log$warn("Failed to auto-detect RAM, defaulting to 4G. Error: %s", e$message)
        })
    } else {
      # If memuse is not installed, use a safe default or ask user to install it
      if (verbose) log$info("Package 'memuse' not found. Defaulting H2O memory to '8G'. Install 'memuse' for auto-tuning.")
    }
  }

  # --- 3. If already running, reuse connection ---
  already_running <- tryCatch(
    {
      !is.null(h2o::h2o.getConnection())
    },
    error = function(e) FALSE)

  if (already_running) {
    if (verbose) log$info("H2O is already initialized.")
    return(invisible(h2o::h2o.getConnection()))
  }

  # --- 4. Retry loop ---
  attempt <- 0
  success <- FALSE
  while (!success && attempt < max_retries) {
    attempt <- attempt + 1
    tryCatch(
      {
        h2o::h2o.init(nthreads = nthreads,
          max_mem_size = final_mem, # Use the calculated memory
          port = port)
        success <- TRUE
      },
      error = function(e) {
        log$warn("H2O init attempt %d/%d failed: %s", attempt, max_retries, e$message)
        if (attempt < max_retries) Sys.sleep(retry_delay)
      })
  }

  if (!success) {
    stop("H2O failed to initialize after ", max_retries, " attempts.")
  }

  # --- 5. Progress bar control ---
  if (verbose) h2o::h2o.show_progress() else h2o::h2o.no_progress()

  # --- 6. Log cluster info ---
  tryCatch(
    {
      capture.output(suppressWarnings(cluster_info <- h2o::h2o.clusterInfo()))

      # Ensure cluster_info is a list before trying to access elements.
      if (is.list(cluster_info) && "nodes" %in% names(cluster_info)) {
        node_info <- cluster_info$nodes[1, ]
        mode <- if (h2o::h2o.is_client()) "client" else "local"

        log$info("H2O cluster initialized | mode=%s | version=%s | cores=%s | mem=%s",
          mode, cluster_info$version, node_info$num_cpus, node_info$max_mem)
      } else {
        # Fallback log
        log$info("H2O cluster is running.")
      }

    },
    error = function(e) {
      log$warn("Could not retrieve H2O cluster info: %s", e$message)
    })

  return(invisible(h2o::h2o.getConnection()))
}


#' H2O Cluster Watchdog (Robust)
#'
#' @description
#' Checks whether the H2O cluster is alive using robust health checks.
#' If the connection is lost or the cluster is unresponsive, it automatically
#' restarts the cluster using the default configuration defined in `nm_init_h2o`.
#'
#' @param verbose Logical flag to enable logging messages (INFO/WARN). Default TRUE.
#'
#' @return Invisibly returns TRUE if the cluster is alive (or successfully restarted), FALSE otherwise.
#' @export
nm_h2o_watchdog <- function(verbose = TRUE) {
  log <- nm_get_logger("h2o.watchdog")
  nm_require("h2o", hint = "install.packages('h2o')")

  # --- 1. Efficient Health Check ---
  # h2o.clusterIsUp() is the preferred way to check status without throwing errors
  if (h2o::h2o.clusterIsUp()) {
    if (verbose) log$info("H2O cluster is alive and healthy.")
    return(invisible(TRUE))
  }

  # --- 2. Failure Detected: Restart Sequence ---
  if (verbose) log$warn("H2O connection lost or cluster is down. Initiating restart...")

  tryCatch(
    {
      # Clean shutdown of any zombie processes
      nm_stop_h2o(quiet = TRUE)

      # Wait for ports to release (crucial on macOS/Linux)
      Sys.sleep(3)

      # Restart using defaults (Smart Auto-Allocation from nm_init_h2o)
      nm_init_h2o(verbose = verbose)

    },
    error = function(e) {
      log$error("Critical failure during H2O restart: %s", e$message)
      return(invisible(FALSE))
    })

  # --- 3. Final Verification ---
  if (h2o::h2o.clusterIsUp()) {
    if (verbose) log$info("H2O cluster successfully restarted.")
    return(invisible(TRUE))
  } else {
    log$error("H2O cluster failed to restart. Please check Java environment or ports.")
    return(invisible(FALSE))
  }
}


#' Save Trained H2O Model
#'
#' @description
#' `nm_save_h2o` saves a trained H2O model. It handles path normalization
#' and file renaming. This is the H2O-specific implementation.
#'
#' @param model The trained H2O model object to save.
#' @param path A string specifying the directory path where the model will be saved.
#' @param filename A string specifying the desired filename for the saved model.
#' @param verbose Should the function print log messages? Default is `TRUE`.
#'
#' @return A string indicating the full path of the saved model.
#' @keywords internal
nm_save_h2o <- function(model, path = "./", filename = "automl", verbose = TRUE) {
  log <- nm_get_logger("model.save.h2o")
  nm_require("h2o", hint = "install.packages('h2o')")

  # Convert the directory path to an absolute path before using it.
  # mustWork = FALSE because the directory might not exist yet.
  path <- normalizePath(path, mustWork = FALSE)

  # Ensure the output directory exists
  if (!dir.exists(path)) {
    dir.create(path, recursive = TRUE)
  }

  model_path <- h2o::h2o.saveModel(model, path = path, force = TRUE)
  new_model_path <- file.path(path, filename)

  if (verbose) log$info("Saving H2O model to: %s", new_model_path)

  file.rename(model_path, new_model_path)

  if (verbose) log$info("H2O model saved successfully.")

  return(new_model_path)
}



#' Load Saved H2O Model
#'
#' \code{nm_load_h2o} loads a previously saved H2O model from disk
#'
#' @param path A string specifying the directory path where the model is saved. Default is './'.
#' @param filename A string specifying the name of the saved model file. Default is 'automl'.
#' @param verbose Should the function print log messages? Default is TRUE.
#'
#' @return The loaded H2O model object with its "backend" attribute correctly set.
nm_load_h2o <- function(path = "./", filename = "automl", verbose = TRUE) {

  log <- nm_get_logger("model.load.h2o")
  nm_require("h2o", hint = "install.packages('h2o')")

  # --- Path normalization from previous step ---
  model_path <- file.path(path, filename)
  tryCatch(
    {
      full_model_path <- normalizePath(model_path, mustWork = TRUE)
    },
    warning = function(w) {
      stop("File not found at path: '", model_path, "'", call. = FALSE)
    })

  if (verbose) log$info("Loading H2O model from: %s", full_model_path)

  # Load the H2O model
  model <- h2o::h2o.loadModel(full_model_path)

  attr(model, "backend") <- "h2o"

  if (verbose) log$info("H2O model loaded successfully and 'backend' attribute attached.")

  return(model)
}


#' Train a model using H2O AutoML
#'
#' \code{nm_train_h2o} trains a model using H2O AutoML with built-in retry logic.
#'
#' @details
#' This function focuses purely on model training. It assumes the H2O cluster is managed
#' externally (e.g., via `nm_init_h2o`). If the cluster is unstable, it attempts to
#' restart it using the default settings defined in `nm_init_h2o`.
#'
#' Key steps:
#' \itemize{
#'   \item **Data Selection**: Filters for "training" set.
#'   \item **Sanitization**: Checks variance and fills missing factor levels.
#'   \item **Self-Healing**: Restarts H2O (with default args) if training crashes.
#' }
#'
#' @param df Prepared data frame containing the data. If a "set" column exists, filters for "training".
#' @param target Name of the target column (response variable).
#' @param covariates Character vector of predictor column names.
#' @param model_config Optional list of AutoML configuration overrides.
#'        Examples: `list(max_runtime_secs = 60, include_algos = c("GBM"), nfolds = 5)`.
#' @param seed Random seed for reproducibility. Default is 7654321.
#' @param verbose Whether to print progress and diagnostics. Default is TRUE.
#'
#' @return The trained H2O model object (the leader model), with attributes `backend="h2o"`.
#' @export
nm_train_h2o <- function(df, target = "value", covariates = NULL, model_config = NULL,
                         seed = 7654321, verbose = TRUE) {

  log <- nm_get_logger("model.train.h2o")
  nm_require("h2o", hint = "install.packages('h2o')")

  # --- 1. Validate input ---
  if (length(unique(covariates)) != length(covariates)) stop("`covariates` contains duplicates.")
  if (!all(covariates %in% colnames(df))) stop("Some `covariates` not found in input data.")

  # Select training data
  df_train <- if ("set" %in% colnames(df)) {
    df %>% dplyr::filter(set == "training") %>% dplyr::select(dplyr::all_of(c(target, covariates)))
  } else {
    df %>% dplyr::select(dplyr::all_of(c(target, covariates)))
  }

  # --- 2. Configuration Setup ---
  # Only model-related configs here. No hardware configs.
  default_model_config <- list(
    max_retries = 3,
    max_models = NULL,
    max_runtime_secs = 60,
    nfolds = 5,
    cv_type = "random",
    include_algos = c("GBM"),
    sort_metric = "AUTO",
    save_model = FALSE,
    filename = "automl",
    path = "./",
    seed = seed
  )

  # Merge user config
  final_config <- default_model_config
  if (!is.null(model_config)) {
    unknown_keys <- setdiff(names(model_config), names(default_model_config))
    if (length(unknown_keys) > 0) {
      hw_keys <- c("max_mem_size", "nthreads", "port", "name", "n_cores", "ip")
      hint <- if (any(unknown_keys %in% hw_keys)) {
        sprintf(" (%s %s hardware/cluster setting(s) that belong in h2o.init(), not model_config)",
          paste(intersect(unknown_keys, hw_keys), collapse = ", "),
          if (sum(unknown_keys %in% hw_keys) > 1) "look like" else "looks like a")
      } else {
        ""
      }
      stop(sprintf(
        "Unrecognised model_config key(s): %s%s.\nValid model_config keys are: %s.",
        paste(unknown_keys, collapse = ", "), hint,
        paste(names(default_model_config), collapse = ", ")
      ), call. = FALSE)
    }
    final_config <- utils::modifyList(default_model_config, model_config)
  }

  # --- PROGRESS BAR CONTROL ---
  if (!verbose) {
    h2o::h2o.no_progress()
    on.exit(h2o::h2o.show_progress(), add = TRUE)
  }

  # --- 3. Internal training function ---
  train_model_internal <- function() {
    # Data Checks
    if (nrow(df_train) < 5) stop("Too few rows in training data.")
    if (any(is.na(df_train[[target]]))) stop("Target column contains NA.")

    # Variance Check
    numeric_cols <- covariates[vapply(df_train[covariates], is.numeric, logical(1))]
    if (length(numeric_cols) > 0) {
      zero_var_mask <- apply(df_train[, numeric_cols, drop = FALSE], 2, var, na.rm = TRUE) == 0
      if (all(zero_var_mask) && length(numeric_cols) == length(covariates)) {
        stop("All covariates have zero variance.")
      }
    }

    # Sanitize Factor Variables
    cat_cols <- covariates[vapply(df_train[covariates], function(x) is.factor(x) || is.character(x), logical(1))]
    if (length(cat_cols) > 0) {
      if (verbose) log$info("Sanitizing %d categorical features...", length(cat_cols))
      for (col in cat_cols) {
        vals <- as.character(df_train[[col]])
        if (any(is.na(vals))) vals[is.na(vals)] <- "Missing"
        df_train[[col]] <<- as.factor(vals)
      }
    }

    # Time-aware internal validation (mirrors the Python flaml `split_type="time"`
    # fix): with cv_type="time", assign rows to contiguous time-ordered blocks and
    # pass them as a fold_column so cross-validation respects temporal order
    # instead of using leaky random folds. Ordered by `date_unix` when present.
    use_time_cv <- identical(final_config$cv_type, "time")
    if (use_time_cv) {
      ord <- if ("date_unix" %in% names(df_train)) order(df_train[["date_unix"]]) else seq_len(nrow(df_train))
      fid <- integer(nrow(df_train))
      fid[ord] <- as.integer(cut(seq_along(ord), breaks = final_config$nfolds, labels = FALSE)) - 1L
      df_train[[".fold"]] <- fid
    }

    # Ensure H2O connection exists (Check before Action)
    # [FIX] Use clusterIsUp() for robust health check
    if (!h2o::h2o.clusterIsUp()) {
      if (verbose) log$info("H2O cluster is down. Initializing...")
      nm_init_h2o(verbose = verbose)
    }

    # Upload Data
    if (verbose) log$info("Uploading data to H2O cluster...")
    df_h2o <- h2o::as.h2o(df_train, destination_frame = paste0("train_", Sys.getpid()))

    response <- target
    x_vars <- setdiff(colnames(df_h2o), c(response, if (use_time_cv) ".fold"))

    if (verbose) {
      limit_msg <- if (!is.null(final_config$max_runtime_secs)) paste0(final_config$max_runtime_secs, "s") else "Unlimited"
      log$info("Training H2O AutoML (Algos: %s, Max Time: %s)...",
        paste(final_config$include_algos, collapse = ","), limit_msg)
    }

    # Construct arguments for AutoML
    # Remove our internal control keys, pass the rest to H2O
    internal_keys <- c("max_retries", "save_model", "filename", "path", "cv_type")
    automl_params <- final_config[setdiff(names(final_config), internal_keys)]

    # With time-aware CV, drive cross-validation from the fold column instead of nfolds.
    if (use_time_cv) {
      automl_params$nfolds <- NULL
      automl_params$fold_column <- ".fold"
    }

    automl_args <- c(
      list(x = x_vars, y = response, training_frame = df_h2o),
      automl_params
    )

    # Execute training
    auto_ml <- do.call(h2o::h2o.automl, automl_args)

    if (verbose) log$info("Best model obtained: %s", auto_ml@leader@model_id)
    return(auto_ml@leader)
  }

  # --- 4. Retry loop with watchdog ---
  retry_count <- 0
  model <- NULL

  # Initial Start (if needed, using defaults)
  if (!h2o::h2o.clusterIsUp()) nm_init_h2o(verbose = verbose)

  while (is.null(model) && retry_count < final_config$max_retries) {
    retry_count <- retry_count + 1

    tryCatch(
      {
        model <- train_model_internal()
      },
      error = function(e) {
        log$error("Training attempt %d failed: %s", retry_count, e$message)

        if (retry_count < final_config$max_retries) {
          log$warn("Retrying... (%d of %d)", retry_count, final_config$max_retries)

          # RESTART LOGIC:
          # We assume nm_init_h2o() has sensible defaults or detects environment variables
          nm_stop_h2o(quiet = TRUE)
          Sys.sleep(5)
          nm_init_h2o(verbose = verbose)

          if (!verbose) h2o::h2o.no_progress()
        }
      })
  }

  if (is.null(model)) {
    # Leave H2O in a definitively clean (stopped) state before raising --
    # otherwise the cluster can be mid-restart from the retry loop above,
    # and a *later* R-level error/GC touching that half-initialised JVM
    # connection can segfault the whole R session instead of just failing
    # this call.
    tryCatch(nm_stop_h2o(quiet = TRUE), error = function(e) NULL)
    stop("Failed to train the model after ", final_config$max_retries, " attempts.",
        call. = FALSE)
  }

  # --- 5. Attach backend and metadata ---
  attr(model, "backend") <- "h2o"
  attr(model, "names") <- covariates

  if (final_config$save_model) {
    nm_save_model(model, final_config$path, final_config$filename, verbose = verbose)
  }

  return(model)
}


#' Predict using a trained H2O model with Auto-Batching
#'
#' @description
#' `nm_predict_h2o` performs predictions using a trained H2O model.
#' It is designed for production stability:
#' \enumerate{
#'   \item **Auto-Feature Detection**: Prioritizes metadata attached by `nm_train_h2o`, falling back to H2O internals.
#'   \item **Memory Safety**: Automatically splits large datasets into batches to prevent Java Out-Of-Memory (OOM) errors.
#'   \item **Data Sanitization**: Auto-fills `NA`s in categorical columns with a "Missing" level.
#' }
#'
#' @param model A trained H2O model object (S4 class `H2OModel`).
#' @param newdata A data frame or data.table containing the feature matrix.
#' @param verbose Logical flag to enable detailed logging. Default is FALSE.
#'
#' @return A numeric vector of predicted values.
#' @export
nm_predict_h2o <- function(model, newdata, verbose = FALSE) {

  log <- nm_get_logger("model.predict.h2o")
  if (!requireNamespace("data.table", quietly = TRUE)) stop("Package 'data.table' is required.")

  # --- 1. Robust Feature Detection ---
  # Priority 1: Use the explicit predictor names we attached in nm_train_h2o
  feature_cols <- attr(model, "names")

  # Priority 2: Use H2O internal parameters (Legacy/Fallback)
  if (is.null(feature_cols)) {
    if (inherits(model, "H2OModel")) {
      feature_cols <- model@parameters$x
      # Edge case: If x is missing, try varimp
      if (is.null(feature_cols)) {
        try(
          {
            feature_cols <- h2o::h2o.varimp(model)$variable
          },
          silent = TRUE)
      }
    }
  }

  if (is.null(feature_cols)) {
    log$error("Could not extract feature names from H2O model object.")
    stop("Invalid H2O model: predictors list is empty.")
  }

  # --- 2. Data Validation & Subsetting ---
  # Check if all required features exist in newdata
  missing_cols <- setdiff(feature_cols, colnames(newdata))
  if (length(missing_cols) > 0) {
    log$error("The following %d model features are missing in `newdata`: %s",
      length(missing_cols), paste(head(missing_cols, 5), collapse = ", "))
    stop("Prediction failed: Missing features in input data.")
  }

  # Subset newdata to keep only relevant columns (Saves RAM during as.h2o)
  # Coerce to data.table for efficient in-place processing
  if (data.table::is.data.table(newdata)) {
    X <- newdata[, feature_cols, with = FALSE]
  } else {
    X <- data.table::as.data.table(newdata)[, feature_cols, with = FALSE]
  }

  n_rows <- nrow(X)
  if (n_rows == 0) return(numeric(0))

  # --- 3. Data Sanitization (Factor/NA Handling) ---
  # Explicitly filling NAs with "Missing" to match nm_train_h2o logic
  cat_cols <- names(X)[sapply(X, function(col) is.factor(col) || is.character(col))]

  if (length(cat_cols) > 0) {
    if (verbose) log$info("Sanitizing %d categorical columns...", length(cat_cols))
    for (col in cat_cols) {
      # Robust sanitization: Convert to char -> Fill NA -> Factor
      # This avoids issues where "Missing" level doesn't exist in the factor
      X[, (col) := as.character(get(col))]
      if (any(is.na(X[[col]]))) {
        X[is.na(get(col)), (col) := "Missing"]
      }
      X[, (col) := as.factor(get(col))]
    }
  }

  # --- 4. Ensure H2O is Initialized ---
  if (!requireNamespace("h2o", quietly = TRUE)) stop("Package 'h2o' is required.")
  if (!h2o::h2o.clusterIsUp()) {
    if (verbose) log$info("H2O cluster is down. Initializing...")
    # Using defaults is fine for prediction (low resource usage)
    nm_init_h2o(verbose = verbose)
  }

  # --- 5. Determine Batch Size (Memory Protection) ---
  # Calculate approximate size of one row (in bytes)
  sample_n <- min(n_rows, 100)
  row_size_bytes <- as.numeric(utils::object.size(head(X, sample_n))) / sample_n

  # Target payload: 400MB safe limit
  safe_payload_bytes <- 400 * 1024^2

  # Calculate rows per batch
  # Use max(1, ...) to prevent division by zero or invalid sizes
  rows_per_batch <- floor(safe_payload_bytes / max(1, row_size_bytes))

  # Clamp batch size: Min 1000, Max n_rows
  auto_batch_size <- max(1000, min(rows_per_batch, n_rows))

  # --- 6. Internal Prediction Helper ---
  predict_chunk <- function(df_chunk) {
    hf <- NULL
    preds <- NULL
    tryCatch({
      # 1. Push to H2O Cloud
      if (!verbose) h2o::h2o.no_progress()
      hf <- h2o::as.h2o(df_chunk)

      # 2. Predict
      pred_h2o <- h2o::h2o.predict(model, hf)

      # 3. Pull back to R
      preds <- as.vector(pred_h2o$predict)

    }, error = function(e) {
      # Capture generic errors (including connection drops)
      log$error("H2O prediction error: %s", e$message)
      stop(e)
    }, finally = {
      # 4. Clean up H2O RAM immediately
      if (!is.null(hf)) h2o::h2o.rm(hf)
      if (exists("pred_h2o") && !is.null(pred_h2o)) h2o::h2o.rm(pred_h2o)
    })
    return(preds)
  }

  # --- 7. Execute Prediction (Batched) ---
  if (n_rows <= auto_batch_size) {
    # Small data: Single shot
    if (verbose) log$info("Predicting %d rows (Single Batch).", n_rows)
    return(predict_chunk(X))

  } else {
    # Large data: Split and Loop
    starts <- seq(1, n_rows, by = auto_batch_size)
    if (verbose) log$info("Predicting %d rows in %d batches (Batch size: %d)...", n_rows, length(starts), auto_batch_size)

    all_preds <- vector("list", length(starts))

    for (i in seq_along(starts)) {
      start_idx <- starts[i]
      end_idx <- min(start_idx + auto_batch_size - 1, n_rows)

      # Subset chunk (data.table way)
      chunk <- X[start_idx:end_idx]

      # Predict
      all_preds[[i]] <- predict_chunk(chunk)

      # GC periodically
      if (i %% 10 == 0) gc(verbose = FALSE)
    }

    return(unlist(all_preds))
  }
}


#' Determine Target Batch Size in MB
#'
#' @param model A trained H2O model object.
#' @return Integer value in MB for batch sizing.
#' @keywords internal
nm_auto_target_mb <- function(model) {
  val <- attr(model, "_predict_batch_mb", exact = TRUE)
  if (!is.null(val) && is.numeric(val)) return(max(64, min(as.integer(val), 4096)))

  env_val <- Sys.getenv("NM_H2O_BATCH_MB")
  if (nzchar(env_val)) {
    mb <- suppressWarnings(as.integer(env_val))
    if (!is.na(mb)) return(max(64, min(mb, 4096)))
  }

  return(512)
}


#' Shut Down an H2O Cluster
#'
#' \code{nm_stop_h2o} shuts down the attached H2O cluster if one is running.
#'
#' @details
#' This function performs a graceful shutdown by sending a termination signal
#' to the H2O JVM. It is safe to call even if no cluster is running.
#'
#' @param quiet If TRUE (the default), shut down without a confirmation prompt.
#'   If FALSE, the user will be prompted to confirm.
#'
#' @return This function is called for its side effects and returns nothing.
#'
#' @export
nm_stop_h2o <- function(quiet = TRUE) {

  log <- nm_get_logger("h2o.stop")

  # Ensure the shutdown command (HTTP request) doesn't get blocked by proxies
  Sys.setenv(no_proxy = "localhost,127.0.0.1")

  tryCatch(
    {
      nm_require("h2o", hint = "install.packages('h2o')")

      # Robust check: Only try to stop if it's actually responding
      if (h2o::h2o.clusterIsUp()) {
        h2o::h2o.shutdown(prompt = !quiet)

        # Log info only if we actually did something
        log$info("H2O cluster shutdown requested.")

        # Optional: Small pause to allow JVM to release file locks (Good for Windows)
        Sys.sleep(1)
      } else {
        # Debug level is perfect here to avoid noise during scripts
        log$debug("H2O shutdown skipped: no active cluster found.")
      }

    },
    error = function(e) {
      # Suppress errors during shutdown (e.g. if connection severed mid-request)
      log$debug("H2O shutdown skipped/failed: %s", e$message)
    })

  invisible(NULL)
}
