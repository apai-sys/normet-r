#' Detect Model Backend
#'
#' @param model Trained model object.
#' @return Character string identifying the backend, or NULL if unknown.
#' @keywords internal
nm_detect_backend <- function(model) {
  b <- attr(model, "backend")
  if (is.null(b) && inherits(model, "H2OModel")) b <- "h2o"
  b
}

#' Extract and Sort Feature Names by Importance from a Model
#'
#' \code{nm_extract_features} is a high-level wrapper that extracts feature names from a model.
#' It automatically detects the model backend (e.g., H2O) and dispatches accordingly.
#'
#' @param model The trained model object.
#' @param verbose Should the function print log messages? Default is FALSE.
#' @param ... Additional arguments to be passed to the backend-specific function.
#'
#' @return A vector of feature names (sorted by importance if available, otherwise unsorted).
#' @export
nm_extract_features <- function(model, verbose = FALSE, ...) {

  log <- nm_get_logger("features.extract")

  # 1. Backend Detection + Dispatch
  model_backend <- nm_detect_backend(model)
  if (!is.null(model_backend) && startsWith(model_backend, "h2o")) {
    if (verbose) log$info("Dispatching to backend: %s", model_backend)
    return(nm_extract_features_h2o(model, verbose = verbose, ...))

  } else if (!is.null(model_backend) && model_backend == "lightgbm") {
    feat <- attr(model, "feature_names")
    if (is.null(feat)) feat <- model$feature_names
    if (is.null(feat)) stop("Could not detect feature names from lightgbm model.")
    return(feat)

  } else {
    if (!is.null(attr(model, "names"))) {
      return(attr(model, "names"))
    }

    err_msg <- "Model type not supported or backend could not be determined."
    log$error(err_msg)
    stop(err_msg)
  }
}

#' Extract and Sort Feature Names by Importance from an H2O Model
#'
#' \code{nm_extract_features_h2o} attempts to sort features by importance using `h2o.varimp`.
#' **Robustness**: If the H2O cluster is down (meaning `varimp` is inaccessible),
#' it falls back to the static feature list stored in the model metadata.
#'
#' @param model The trained H2O model object.
#' @param importance_ascending A logical value for sorting order. Default is `FALSE`.
#' @param verbose Should the function print log messages? Default is FALSE.
#'
#' @return A vector of feature names.
#' @export
nm_extract_features_h2o <- function(model, importance_ascending = FALSE, verbose = FALSE) {

  log <- nm_get_logger("features.extract.h2o")
  nm_require("h2o", hint = "install.packages('h2o')")

  if (verbose) log$info("Extracting feature importance from H2O model...")

  # --- Attempt 1: Get Variable Importance (Requires Live Cluster) ---
  # Only try if cluster is up, otherwise we assume the pointer is dead.
  varimp_success <- FALSE
  varimp_df <- NULL

  if (h2o::h2o.clusterIsUp()) {
    tryCatch(
      {
        varimp_obj <- h2o::h2o.varimp(model)
        if (!is.null(varimp_obj)) {
          varimp_df <- as.data.frame(varimp_obj)
          varimp_success <- TRUE
        }
      },
      error = function(e) {
        if (verbose) log$warn("h2o.varimp call failed (Cluster might be reset): %s", e$message)
      })
  }

  # Process Varimp if successful
  if (varimp_success && nrow(varimp_df) > 0) {
    # Handle different column naming conventions
    predictors <- NULL
    scores <- NULL

    if ("variable" %in% names(varimp_df) && "relative_importance" %in% names(varimp_df)) {
      # Standard (GBM, DRF, DL)
      predictors <- varimp_df$variable
      scores <- varimp_df$relative_importance
    } else if ("names" %in% names(varimp_df) && "coefficients" %in% names(varimp_df)) {
      # GLM
      predictors <- varimp_df$names
      scores <- abs(varimp_df$coefficients) # Sort by magnitude
    } else if ("variable" %in% names(varimp_df) && "scaled_importance" %in% names(varimp_df)) {
      # AutoEncoder / other
      predictors <- varimp_df$variable
      scores <- varimp_df$scaled_importance
    }

    if (!is.null(predictors)) {
      # Filter out 'Intercept'
      idx_keep <- predictors != "Intercept"
      predictors <- predictors[idx_keep]
      scores <- scores[idx_keep]

      # Sort
      idx <- order(scores, decreasing = !importance_ascending)
      return(as.character(predictors[idx]))
    }
  }

  # --- Attempt 2: Metadata Fallback (The Safety Net) ---
  # If we are here, either:
  # 1. The model type (e.g. StackedEnsemble) doesn't support varimp.
  # 2. The H2O cluster restarted, so the model object is "dead" (cannot query API),
  #    BUT the R object still holds the metadata we attached in nm_train_h2o.

  if (verbose) log$warn("Variable importance unavailable. Falling back to metadata.")

  # Priority: The explicit attribute we attached (Guaranteed to be correct)
  if (!is.null(attr(model, "names"))) {
    return(attr(model, "names"))
  }

  # Fallback: H2O internal slots (Only works if object structure is intact)
  if (!is.null(model@parameters$x)) return(as.character(model@parameters$x))
  if (!is.null(model@allparameters$x)) return(as.character(model@allparameters$x))

  # Total Failure
  log$warn("Could not extract any feature names from model.")
  return(character(0))
}

#' Extract Feature Importance Table from a Model
#'
#' @description
#' Extracts variable importance values from a trained model and returns a standardized data frame.
#'
#' @param model A trained model object.
#' @param verbose Logical flag to enable progress messages.
#' @param ... Additional arguments passed to the implementation function.
#'
#' @return A data frame containing variables and their importance metrics.
#' @export
nm_feature_importance <- function(model, verbose = FALSE, ...) {
  log <- nm_get_logger("features.importance")

  model_backend <- nm_detect_backend(model)

  if (!is.null(model_backend) && startsWith(model_backend, "h2o")) {
    if (verbose) log$info("Dispatching to H2O backend for feature importance table.")
    return(nm_feature_importance_h2o(model, verbose = verbose, ...))
  } else {
    err_msg <- "Model type not supported or 'backend' attribute is missing."
    log$error(err_msg)
    stop(err_msg)
  }
}

#' Extract Feature Importance Table from an H2O Model
#'
#' @description
#' Helper function that interacts with H2O's backend to extract detailed variable importance.
#'
#' @param model A trained H2O model object (class `H2OModel`).
#' @param verbose Logical flag to enable progress messages.
#'
#' @return A data frame containing variables and their importance metrics.
#' @export
nm_feature_importance_h2o <- function(model, verbose = FALSE) {

  log <- nm_get_logger("features.importance.h2o")
  nm_require("h2o", hint = "install.packages('h2o')")

  if (!h2o::h2o.clusterIsUp()) {
    log$error("Cannot extract feature importance table: H2O cluster is down.")
    return(data.frame())
  }

  if (verbose) log$info("Retrieving detailed variable importance from H2O model...")

  imp_obj <- tryCatch(
    {
      h2o::h2o.varimp(model)
    },
    error = function(e) {
      if (verbose) log$warn("h2o.varimp failed: %s", e$message)
      return(NULL)
    })

  if (is.null(imp_obj)) {
    if (verbose) log$warn("No variable importance information found for this model.")
    return(data.frame())
  }

  df_imp <- as.data.frame(imp_obj)

  if (nrow(df_imp) > 0) {
    # Normalize GLM to look like GBM output
    if ("names" %in% colnames(df_imp) && "coefficients" %in% colnames(df_imp)) {
      colnames(df_imp)[colnames(df_imp) == "names"] <- "variable"
      df_imp$scaled_importance <- abs(df_imp$coefficients)

      # Calculate percentage for consistency
      total_imp <- sum(df_imp$scaled_importance, na.rm = TRUE)
      df_imp$percentage <- if (total_imp > 0) df_imp$scaled_importance / total_imp else 0
    }

    # Normalize GBM/DRF to ensure 'variable' and 'scaled_importance' exist
    if ("variable" %in% names(df_imp) && "relative_importance" %in% names(df_imp)) {
      if (!"scaled_importance" %in% names(df_imp)) {
        df_imp$scaled_importance <- df_imp$relative_importance
      }
    }

    # Final Cleanup
    if ("variable" %in% names(df_imp)) {
      df_imp <- df_imp[df_imp$variable != "Intercept", ]

      if ("scaled_importance" %in% names(df_imp)) {
        df_imp <- df_imp[order(df_imp$scaled_importance, decreasing = TRUE), ]
      }
    }
  }

  return(df_imp)
}
