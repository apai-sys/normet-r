# Time Series Cross-Validation Utilities
#
# Ported from Python normet utils/cv.py
# Provides walk-forward (forward-chaining) CV splits
# and an automated cv_score function.

NULL

#' Walk-Forward Time Series Cross-Validation Splits
#'
#' Generate train/test index pairs for walk-forward (forward-chaining)
#' cross-validation that respects temporal ordering.
#'
#' @param df A data frame with a datetime \code{date_col} column.
#' @param n_splits Integer. Number of folds. Default 5.
#' @param gap Integer. Rows to skip between train and test. Default 0.
#' @param test_size Integer. Test segment size in rows.
#'        If NULL (default), splits the tail evenly into \code{n_splits}.
#' @param max_train_size Integer. If given, train is a sliding window of this
#'        many rows; otherwise train is expanding (anchored at start).
#' @param date_col Character. Date column name. Default \code{"date"}.
#'
#' @return A list of lists, each with elements \code{train} and \code{test}
#'         containing integer index vectors into the date-sorted data frame.
#' @export
nm_time_series_cv <- function(df, n_splits = 5, gap = 0, test_size = NULL,
                              max_train_size = NULL, date_col = "date") {
  if (n_splits < 1) stop("`n_splits` must be >= 1.")
  if (gap < 0) stop("`gap` must be >= 0.")

  if (!date_col %in% colnames(df)) stop("`", date_col, "` column not found.")
  n <- nrow(df)
  if (n < n_splits + 1) stop("Need at least n_splits+1 rows.")

  sort_pos <- order(df[[date_col]])
  if (is.null(test_size)) test_size <- max(1, n %/% (n_splits + 1))
  total_test <- n_splits * test_size + gap * n_splits
  if (total_test >= n) stop("Not enough rows: reduce n_splits or test_size.")

  end_indices <- rev(seq(from = n, by = -test_size, length.out = n_splits))
  folds <- vector("list", n_splits)

  for (i in seq_len(n_splits)) {
    test_end <- end_indices[i]
    test_start <- test_end - test_size + 1
    train_end <- test_start - gap - 1
    if (max_train_size > 0 && !is.null(max_train_size)) {
      train_start <- max(1, train_end - max_train_size + 1)
    } else {
      train_start <- 1
    }
    if (train_end < train_start) next
    folds[[i]] <- list(
      train = sort_pos[train_start:train_end],
      test = sort_pos[test_start:test_end]
    )
  }
  folds[!sapply(folds, is.null)]
}

#' Cross-Validate a Model with Walk-Forward Splits
#'
#' Train and evaluate the configured backend across walk-forward CV folds.
#'
#' @param df A data frame containing a date column, target \code{value}, and predictors.
#' @param target Character. Target column name. Default \code{"value"}.
#' @param covariates Character vector. Predictor column names.
#' @param backend Character. Model backend. Default \code{"lightgbm"} (or \code{"h2o"}).
#' @param n_splits Integer. Number of CV folds. Default 5.
#' @param gap Integer. Gap between train/test. Default 0.
#' @param test_size Integer. Test size per fold. NULL auto-calculates.
#' @param max_train_size Integer. Max train rows per fold.
#' @param statistic Character vector. Metrics to compute (see \code{nm_modStats}).
#' @param model_config List. Backend training configuration.
#' @param seed Integer. Random seed. Default 7654321.
#' @param verbose Logical. Print progress.
#' @param date_col Character. Date column name. Default \code{"date"}.
#'
#' @return A data frame with one row per fold, containing metrics and metadata.
#' @export
nm_cv_score <- function(df, target = "value", covariates = NULL, backend = "lightgbm",
                        n_splits = 5, gap = 0, test_size = NULL,
                        max_train_size = NULL, statistic = NULL,
                        model_config = NULL, seed = 7654321,
                        verbose = FALSE, date_col = "date") {
  if (is.null(covariates) || length(covariates) == 0) stop("`covariates` must be non-empty.")
  if (!target %in% colnames(df)) stop("Target column '", target, "' not found.")

  work <- df[order(df[[date_col]]), , drop = FALSE]
  folds <- nm_time_series_cv(
    work, n_splits = n_splits, gap = gap,
    test_size = test_size, max_train_size = max_train_size,
    date_col = date_col
  )

  results <- vector("list", length(folds))
  for (i in seq_along(folds)) {
    tr_idx <- folds[[i]]$train
    te_idx <- folds[[i]]$test
    df_tr <- work[tr_idx, , drop = FALSE]
    df_te <- work[te_idx, , drop = FALSE]

    if (verbose) cat(sprintf("Fold %d/%d: train=%d, test=%d\n", i, length(folds), nrow(df_tr), nrow(df_te)))

    model <- tryCatch(
      {
        nm_train_model(
          df = df_tr, target = target, backend = backend,
          covariates = covariates, model_config = model_config,
          seed = seed, verbose = FALSE
        )
      },
      error = function(e) {
        if (verbose) warning("Fold ", i, " training failed: ", e$message)
        NULL
      })
    if (is.null(model)) next

    y_pred <- nm_predict(model, df_te, verbose = FALSE)
    df_te$.predict <- y_pred
    row <- nm_Stats(df_te, mod = ".predict", obs = target, statistic = statistic)
    row$fold <- i
    row$train_start <- as.character(work[[date_col]][tr_idx[1]])
    row$train_end <- as.character(work[[date_col]][tr_idx[length(tr_idx)]])
    row$test_start <- as.character(work[[date_col]][te_idx[1]])
    row$test_end <- as.character(work[[date_col]][te_idx[length(te_idx)]])
    row$n_train <- length(tr_idx)
    row$n_test <- length(te_idx)
    results[[i]] <- row
  }

  results <- Filter(Negate(is.null), results)
  if (length(results) == 0) return(data.frame())
  out <- do.call(rbind, results)
  meta_cols <- c("fold", "train_start", "train_end", "test_start", "test_end", "n_train", "n_test")
  out[, c(meta_cols, setdiff(colnames(out), meta_cols)), drop = FALSE]
}
