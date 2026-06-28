#' Encode Factor/Character Predictors for lightgbm
#'
#' Converts factor/character predictor columns to 0-based integer codes, as
#' required by lightgbm's `categorical_feature`. Returns the resulting
#' numeric matrix together with the level mapping used, so the identical
#' encoding can be reapplied to new data at prediction time.
#'
#' @keywords internal
nm_lgb_encode_predictors <- function(df, predictors) {
  x_df <- df[, predictors, drop = FALSE]
  factor_levels <- list()

  for (p in predictors) {
    col <- x_df[[p]]
    if (is.factor(col) || is.character(col)) {
      lv <- if (is.factor(col)) levels(col) else sort(unique(as.character(col)))
      factor_levels[[p]] <- lv
      x_df[[p]] <- as.integer(factor(as.character(col), levels = lv)) - 1L
    }
  }

  list(x = as.matrix(x_df), factor_levels = factor_levels)
}


#' Apply a Stored lightgbm Factor Encoding to New Data
#'
#' Re-applies the factor/character -> integer code mapping produced by
#' \code{nm_lgb_encode_predictors()} during training, ensuring train and
#' predict time use identical category codes. Levels not seen during
#' training are mapped to \code{NA} (and later set to 0).
#'
#' @keywords internal
nm_lgb_apply_encoding <- function(df, predictors, factor_levels) {
  x_df <- df[, predictors, drop = FALSE]

  for (p in names(factor_levels)) {
    if (p %in% predictors) {
      x_df[[p]] <- as.integer(factor(as.character(x_df[[p]]), levels = factor_levels[[p]])) - 1L
    }
  }

  as.matrix(x_df)
}


#' Train a Model Using lightgbm with Random Hyperparameter Search
#'
#' Performs automatic model training with random hyperparameter search and
#' cross-validarion, similar in spirit to H2O AutoML but using lightgbm
#' in-process (no JVM overhead).
#'
#' @param df Training data frame or data.table.
#' @param value Target column name. Default \code{"value"}.
#' @param predictors Character vector of feature column names. Factor/character
#'   columns (e.g. \code{"weekday"}) are automatically encoded as categorical
#'   features for lightgbm.
#' @param model_config Optional list. Supported keys:
#'   \itemize{
#'     \item \code{n_trials} — number of random search trials (default 50).
#'     \item \code{cv_folds} — number of CV folds (default 5).
#'     \item \code{nrounds} — max boosting rounds (default 1000).
#'     \item \code{early_stopping_rounds} (default 20).
#'     \item \code{num_leaves_min}, \code{num_leaves_max} — tree complexity range.
#'     \item \code{learning_rate_min}, \code{learning_rate_max} (default 0.01 – 0.3).
#'   }
#' @param seed Random seed. Default 7654321.
#' @param verbose Logical. Print progress. Default TRUE.
#'
#' @return A lightgbm Booster object with attribute \code{backend = "lightgbm"}.
#' @export
nm_train_lgb <- function(df, value = "value", predictors = NULL,
                         model_config = NULL, seed = 7654321, verbose = TRUE) {

  nm_require("lightgbm", hint = "install.packages('lightgbm')")
  log <- nm_get_logger("model.train.lgb")
  set.seed(seed)

  cfg <- list(
    n_trials = 50, cv_folds = 5, nrounds = 1000, early_stopping_rounds = 20,
    num_leaves_min = NULL, num_leaves_max = NULL,
    learning_rate_min = 0.01, learning_rate_max = 0.3
  )
  if (!is.null(model_config)) cfg <- utils::modifyList(cfg, model_config)

  n <- nrow(df)
  n_feat <- length(predictors)

  leaves_min <- if (is.null(cfg$num_leaves_min)) max(8L, min(127L, n %/% 20L)) else cfg$num_leaves_min
  leaves_max <- if (is.null(cfg$num_leaves_max)) min(127L, max(16L, n %/% 3L)) else cfg$num_leaves_max
  leaves_max <- max(leaves_min + 1L, leaves_max)

  enc <- nm_lgb_encode_predictors(df, predictors)
  x <- enc$x
  y <- df[[value]]

  if (anyNA(y)) stop("Target column contains NA values.")
  x[!is.finite(x)] <- 0

  cat_features <- names(enc$factor_levels)
  dtrain <- lightgbm::lgb.Dataset(
    x, label = y,
    categorical_feature = if (length(cat_features) > 0) cat_features else NULL
  )

  best_score <- Inf
  best_params <- NULL
  best_nrounds <- cfg$nrounds

  if (verbose) {
    log$info("lightgbm random search: %d trials, %d-fold CV, %d predictors, %d rows",
      cfg$n_trials, cfg$cv_folds, n_feat, n)
  }

  for (i in seq_len(cfg$n_trials)) {

    params <- list(
      objective          = "regression",
      metric             = "rmse",
      verbosity          = -1,
      feature_pre_filter = FALSE,
      num_leaves         = sample(leaves_min:leaves_max, 1L),
      learning_rate    = stats::runif(1, cfg$learning_rate_min, cfg$learning_rate_max),
      min_data_in_leaf = sample(seq(max(3L, min(100L, n %/% 50L)),
        min(500L, max(20L, n %/% 5L))), 1L),
      feature_fraction = stats::runif(1, 0.5, 1.0),
      bagging_fraction = stats::runif(1, 0.5, 1.0),
      bagging_freq     = sample(c(0L, 1L, 5L), 1L),
      lambda_l1        = if (stats::runif(1) < 0.5) 0 else 10^stats::runif(1, -3, 1),
      lambda_l2        = if (stats::runif(1) < 0.5) 0 else 10^stats::runif(1, -3, 1)
    )

    cv <- lightgbm::lgb.cv(
      params = params, data = dtrain, nrounds = cfg$nrounds,
      nfold = cfg$cv_folds, early_stopping_rounds = cfg$early_stopping_rounds,
      verbose = -1L
    )

    score <- cv$best_score

    if (score < best_score) {
      best_score <- score
      best_params <- params
      best_nrounds <- cv$best_iter
      if (verbose) {
        log$info("  Trial %d/%d: best RMSE = %.4f (leaves=%d, lr=%.3f, rounds=%d)",
          i, cfg$n_trials, score, params$num_leaves, params$learning_rate, best_nrounds)
      }
    } else if (verbose && i %% 10 == 0) {
      log$info("  Trial %d/%d: RMSE = %.4f (best = %.4f)", i, cfg$n_trials, score, best_score)
    }
  }

  if (verbose) {
    log$info("Training final model (rounds=%d, leaves=%d)", best_nrounds, best_params$num_leaves)
  }

  model <- lightgbm::lightgbm(
    data = dtrain, params = best_params, nrounds = best_nrounds,
    verbose = -1L
  )

  attr(model, "backend") <- "lightgbm"
  attr(model, "feature_names") <- predictors
  attr(model, "factor_levels") <- enc$factor_levels
  model
}


#' Predict Using a lightgbm Model
#'
#' Automatically detects the model's feature names and subsets \code{newdata}
#' to the correct columns, preventing shape mismatches.
#'
#' @param model A lightgbm Booster object.
#' @param newdata Data frame or data.table of predictors.
#' @param verbose Ignored (for API compatibility).
#'
#' @return Numeric vector of predictions.
#' @export
nm_predict_lgb <- function(model, newdata, verbose = FALSE) {
  feat <- attr(model, "feature_names")
  if (is.null(feat)) feat <- model$feature_names
  if (is.null(feat)) stop("Could not detect feature names from lightgbm model.")

  newdata_df <- data.frame(newdata)[feat]
  factor_levels <- attr(model, "factor_levels")

  x <- if (length(factor_levels) > 0) {
    nm_lgb_apply_encoding(newdata_df, feat, factor_levels)
  } else {
    as.matrix(newdata_df)
  }

  x[!is.finite(x)] <- 0
  as.numeric(stats::predict(model, x))
}


#' Save Trained lightgbm Model
#'
#' @description
#' `nm_save_lgb` persists a trained lightgbm Booster, together with its
#' \code{backend} and \code{feature_names} attributes, to disk via
#' \code{saveRDS}. This is the lightgbm-specific implementation.
#'
#' @param model The trained lightgbm Booster object to save.
#' @param path A string specifying the directory path where the model will be saved.
#' @param filename A string specifying the desired filename for the saved model.
#' @param verbose Should the function print log messages? Default is `TRUE`.
#'
#' @return A string indicating the full path of the saved model.
#' @keywords internal
nm_save_lgb <- function(model, path = "./", filename = "automl", verbose = TRUE) {
  log <- nm_get_logger("model.save.lgb")

  path <- normalizePath(path, mustWork = FALSE)
  if (!dir.exists(path)) dir.create(path, recursive = TRUE)

  model_path <- file.path(path, filename)
  saveRDS(model, model_path)

  if (verbose) log$info("lightgbm model saved to: %s", model_path)

  model_path
}


#' Load Saved lightgbm Model
#'
#' \code{nm_load_lgb} loads a previously saved lightgbm model from disk.
#'
#' @param path A string specifying the directory path where the model is saved. Default is './'.
#' @param filename A string specifying the name of the saved model file. Default is 'automl'.
#' @param verbose Should the function print log messages? Default is TRUE.
#'
#' @return The loaded lightgbm Booster object with its "backend" attribute correctly set.
#' @keywords internal
nm_load_lgb <- function(path = "./", filename = "automl", verbose = TRUE) {
  log <- nm_get_logger("model.load.lgb")

  model_path <- file.path(path, filename)
  if (!file.exists(model_path)) stop("File not found at path: '", model_path, "'", call. = FALSE)

  if (verbose) log$info("Loading lightgbm model from: %s", model_path)

  model <- readRDS(model_path)
  attr(model, "backend") <- "lightgbm"

  if (verbose) log$info("lightgbm model loaded successfully and 'backend' attribute attached.")

  model
}
