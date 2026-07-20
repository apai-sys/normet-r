# On-Disk Caching Utilities
#
# Ported from Python normet utils/cache.py
# Provides content-hashing and joblib-style memoisation helpers.

NULL

#' Create a Cache Directory
#'
#' Create a directory for caching expensive computations. Optionally uses the
#' \pkg{memoise} package for function-level memoisation.
#'
#' @param location Character. Directory path. Default \code{".normet_cache"}.
#' @param verbose Logical. Print info messages.
#'
#' @return A list with elements:
#'   \item{path}{Character, the cache directory path.}
#'   \item{memoise}{If \pkg{memoise} is installed, a function to memoise
#'         callables; otherwise NULL.}
#' @export
nm_make_cache <- function(location = ".normet_cache", verbose = TRUE) {
  dir.create(location, showWarnings = FALSE, recursive = TRUE)
  if (verbose) message("normet cache directory: ", normalizePath(location))

  memo <- NULL
  if (requireNamespace("memoise", quietly = TRUE)) {
    memo <- memoise::memoise
  }
  list(path = location, memoise = memo)
}

#' Compute a Content Hash for a Data Frame
#'
#' Compute a SHA-1 hash of a data frame's contents, suitable for cache keys.
#'
#' @param df A data frame.
#' @param cols Character vector. Optional subset of columns to hash.
#' @param include_index Logical. If TRUE, include row names in the hash.
#'
#' @return A character string (hex digest).
#' @export
nm_dataframe_hash <- function(df, cols = NULL, include_index = TRUE) {
  sub <- if (!is.null(cols)) df[, cols, drop = FALSE] else df
  digest_input <- if (include_index) {
    list(rownames(sub), as.list(sub))
  } else {
    as.list(sub)
  }
  digest::digest(digest_input, algo = "sha1", serialize = TRUE)
}

#' Compute a Configuration Hash
#'
#' Compute a SHA-1 hash of configuration objects (lists, vectors, etc.)
#' for use as cache keys.
#'
#' @param ... One or more R objects to hash.
#'
#' @return A character string (hex digest).
#' @export
nm_config_hash <- function(...) {
  objs <- list(...)
  parts <- vapply(objs, function(o) {
    paste0(capture.output(utils::str(o, give.attr = FALSE)), collapse = "")
  }, character(1))
  blob <- paste(parts, collapse = "||")
  digest::digest(blob, algo = "sha1", serialize = FALSE)
}

#' Compute a Content Hash for a Model Object
#'
#' Compute a SHA-1 hash of an arbitrary (typically trained-model) object, for
#' use as a cache key.
#'
#' Unlike \code{\link{nm_config_hash}}, which stringifies via
#' \code{utils::str()} (lossy/truncated for large objects), this hashes a
#' full content representation. Mirrors normet-py's \code{model_hash}
#' (\code{joblib.hash}). Intended for cache keys that must invalidate when
#' the model itself changes -- e.g. re-running \code{\link{nm_normalise}}
#' with a re-fit model on otherwise identical data and config should not
#' silently reuse a stale cached result.
#'
#' \strong{Known pitfall (fixed here):} a raw \code{digest::digest(model)}
#' on an \code{lgb.Booster} is \emph{not} stable across calls on the exact
#' same object -- lightgbm's R6 wrapper lazily mutates internal state
#' (e.g. an internal predictor handle) the first time \code{predict()} runs
#' on it, so hashing before vs. after a prediction call yields two different
#' digests for what is semantically the same trained model. Confirmed via
#' direct test: \code{digest(model)} differs before/after a
#' \code{nm_predict_lgb()} call, while \code{digest(model$save_model_to_string())}
#' (a serialization of only the persisted tree structure, not the lazy
#' runtime cache) stays identical. Left unfixed, this silently defeats
#' \code{\link{nm_normalise}}/\code{\link{nm_decompose}} caching: every call
#' after the first `predict()` on a given model object hashes differently
#' and always misses.
#'
#' @param model Any object, typically a trained model. \code{lgb.Booster}
#'   and \code{H2OModel} objects are hashed via a stable model-specific
#'   representation (see Details); anything else falls back to
#'   \code{digest::digest(model)}.
#'
#' @return A character string (hex digest).
#' @export
nm_model_hash <- function(model) {
  if (inherits(model, "lgb.Booster") && is.function(model$save_model_to_string)) {
    return(digest::digest(model$save_model_to_string(), algo = "sha1"))
  }
  if (inherits(model, "H2OModel")) {
    return(digest::digest(model@model_id, algo = "sha1"))
  }
  digest::digest(model, algo = "sha1")
}

#' Load a Cached Result
#'
#' @param cache_dir Character. Cache directory path.
#' @param key Character. Cache key (hex digest).
#'
#' @return The cached R object, or NULL on a cache miss.
#' @keywords internal
nm_cache_load <- function(cache_dir, key) {
  path <- file.path(cache_dir, paste0(key, ".rds"))
  if (file.exists(path)) readRDS(path) else NULL
}

#' Save a Result to Cache
#'
#' @param cache_dir Character. Cache directory path.
#' @param key Character. Cache key (hex digest).
#' @param result R object to cache.
#'
#' @return Invisibly returns the file path.
#' @keywords internal
nm_cache_save <- function(cache_dir, key, result) {
  dir.create(cache_dir, showWarnings = FALSE, recursive = TRUE)
  path <- file.path(cache_dir, paste0(key, ".rds"))
  saveRDS(result, path)
  invisible(path)
}
