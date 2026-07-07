# Enhanced Normalisation Features
#
# Ported from Python normet analysis/normalise.py
# Adds:
#   - conditional_on  : filter resample_df before sampling
#   - return_quantiles: emit quantile columns in aggregate mode

NULL

#' Apply conditional filter to resample pool
#' @keywords internal
nm_apply_conditional_filter <- function(resample_df, conditional_on) {
  if (is.null(conditional_on) || length(conditional_on) == 0) return(resample_df)

  log <- nm_get_logger("analysis.normalise")
  before <- nrow(resample_df)
  dt <- as.data.frame(resample_df)

  for (col in names(conditional_on)) {
    if (!col %in% colnames(dt)) stop("`conditional_on` key '", col, "' not in resample_df.")
    cond <- conditional_on[[col]]
    if (is.function(cond)) {
      mask <- cond(dt[[col]])
    } else if (length(cond) > 1) {
      mask <- dt[[col]] %in% cond
    } else {
      mask <- dt[[col]] == cond
    }
    mask[is.na(mask)] <- FALSE
    dt <- dt[mask, , drop = FALSE]
  }

  if (nrow(dt) == 0) {
    stop("`conditional_on` left no rows in resample pool (was ", before, ").")
  }
  log$info("conditional_on filter: %d -> %d rows in resample pool.", before, nrow(dt))
  dt
}

#' Normalise with conditional filtering and quantile returns
#'
#' Enhanced wrapper around \code{nm_normalise} that supports:
#' \itemize{
#'   \item \code{conditional_on} — restrict resample pool with a named list
#'         of conditions (scalar, vector, or function per column).
#'   \item \code{return_quantiles} — compute quantile columns from the
#'         per-date resample distribution (e.g., \code{q025}, \code{q975}).
#' }
#'
#' @inheritParams nm_normalise
#' @param conditional_on Named list. Each element is a scalar, vector, or
#'        function used to filter the resample pool column.
#' @param return_quantiles Numeric vector of probabilities, e.g.
#'        \code{c(0.025, 0.5, 0.975)}. Only used when \code{aggregate = TRUE}.
#'
#' @return A data.frame with additional quantile columns (when
#'         \code{return_quantiles} is given and \code{aggregate = TRUE}).
#' @export
nm_normalise_ext <- function(df, model, verbose = TRUE,
                             conditional_on = NULL,
                             return_quantiles = NULL,
                             ...) {
  dots <- list(...)

  if (!is.null(conditional_on) || !is.null(return_quantiles)) {
    # Handle conditional_on by filtering resample_df pre-emptively
    if (!is.null(conditional_on)) {
      resample_df <- dots[["resample_df"]] %||% df
      resample_df <- nm_apply_conditional_filter(resample_df, conditional_on)
      dots[["resample_df"]] <- resample_df
    }

    # Handle return_quantiles in aggregate mode
    if (!is.null(return_quantiles)) {
      aggregate <- dots[["aggregate"]] %||% TRUE
      if (!aggregate) {
        if (verbose) {
          nm_get_logger("analysis.normalise")$debug(
            "return_quantiles ignored when aggregate=FALSE."
          )
        }
      } else {
        # Ensure aggregate mode but also return full seed data for quantile calc
        dots[["aggregate"]] <- TRUE
      }
    }

    result <- do.call(nm_normalise, c(list(df = df, model = model, verbose = verbose), dots))

    # Post-process quantiles from the underlying raw data
    if (!is.null(return_quantiles) && (dots[["aggregate"]] %||% TRUE)) {
      result <- .add_quantile_columns(df, model, result, return_quantiles, dots, verbose)
    }

    return(result)
  }

  do.call(nm_normalise, c(list(df = df, model = model, verbose = verbose), dots))
}

#' Add quantile columns to aggregated normalisation result
#' @noRd
.add_quantile_columns <- function(df, model, result, return_quantiles, dots, verbose) {
  log <- nm_get_logger("analysis.normalise")
  n_samples <- dots[["n_samples"]] %||% 300
  seed <- dots[["seed"]] %||% 7654321
  resample_vars <- dots[["resample_vars"]]
  replace <- dots[["replace"]] %||% TRUE
  resample_df <- dots[["resample_df"]] %||% df

  set.seed(seed)
  random_seeds <- sample(1:1000000, n_samples, replace = FALSE)

  # Run one shot with multiple seeds to get per-date distribution
  preds_by_seed <- list()
  for (s in random_seeds) {
    resampled <- tryCatch(
      {
        nm_generate_resampled(df, resample_vars, replace, s, resample_df)
      },
      error = function(e) NULL)
    if (is.null(resampled)) next
    pred <- tryCatch(nm_predict(model, resampled, verbose = FALSE), error = function(e) NULL)
    if (is.null(pred)) next
    preds_by_seed[[as.character(s)]] <- pred
  }

  if (length(preds_by_seed) == 0) {
    log$warn("No successful predictions for quantile computation.")
    return(result)
  }

  # Build per-date matrix: dates x seeds
  M <- do.call(cbind, preds_by_seed)
  M <- M[match(result$date, df$date), , drop = FALSE]

  q_names <- sprintf("q%03d", as.integer(round(return_quantiles * 1000)))
  for (i in seq_along(return_quantiles)) {
    result[[q_names[i]]] <- apply(M, 1, quantile, probs = return_quantiles[i], na.rm = TRUE)
  }

  log$info("Added %d quantile column(s) to aggregated result.", length(q_names))
  result
}
