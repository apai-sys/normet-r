# Multi-Site (Multi-Station) Parallel Drivers
#
# Ported from Python normet pipeline/multisite.py
# Loops a per-site callable across unique values of a site column.

NULL

#' Apply a Function Per Site
#'
#' Run \code{func(df = site_df, ...)} for each unique site and concatenate
#' results.
#'
#' @param df Long-format data frame with a site column.
#' @param site_col Character. Site/station identifier column.
#' @param func Function. Per-site function. Must return a data.frame.
#'        Signature: \code{function(df, ...)}.
#' @param n_cores Integer. Parallel workers. If NULL, uses \code{detectCores() - 1}.
#' @param site_kwarg Character. If set, the site value is passed to \code{func}
#'        under this keyword argument.
#' @param ... Additional arguments passed to \code{func}.
#'
#' @return A data.frame with \code{site_col} appended, combining all sites.
#' @export
nm_multisite_apply <- function(df, site_col, func, n_cores = NULL,
                               site_kwarg = NULL, ...) {
  if (!site_col %in% colnames(df)) stop("`site_col` '", site_col, "' not in df.")
  sites <- unique(df[[site_col]])
  if (length(sites) == 0) return(data.frame())

  if (is.null(n_cores)) {
    if (Sys.getenv("_R_CHECK_LIMIT_CORES_", "") != "") {
      n_cores <- 2
    } else {
      n_cores <- max(1, parallel::detectCores(logical = FALSE) - 1)
      if (is.na(n_cores)) n_cores <- 2
    }
  }
  if (Sys.getenv("_R_CHECK_LIMIT_CORES_", "") != "") {
    n_cores <- min(n_cores, 2)
  }

  cl <- parallel::makeCluster(min(n_cores, length(sites)))
  .nm_propagate_libpaths(cl)
  on.exit(parallel::stopCluster(cl), add = TRUE)
  doSNOW::registerDoSNOW(cl)

  opts <- list()
  if (requireNamespace("progress", quietly = TRUE)) {
    pb <- progress::progress_bar$new(total = length(sites),
      format = "  Multi-site [:bar] :percent :eta", width = 60)
    opts <- list(progress = function(n) pb$tick())
  }
  site_val <- NULL  # suppress R CMD check NOTE re: foreach global
  results <- foreach::foreach(site_val = sites, .packages = c("normet")) %dopar% {
    tryCatch(
      {
        sub <- df[df[[site_col]] == site_val, , drop = FALSE]
        if (nrow(sub) == 0) return(NULL)
        args <- list(df = sub, ...)
        if (!is.null(site_kwarg)) args[[site_kwarg]] <- site_val
        res <- do.call(func, args)
        if (is.list(res) && "res" %in% names(res)) res <- res$res  # handle do_all output
        if (is.null(res) || nrow(res) == 0) return(NULL)
        res[[site_col]] <- site_val
        res
      },
      error = function(e) NULL)
  }

  results <- Filter(Negate(is.null), results)
  if (length(results) == 0) stop("All per-site runs failed.")
  do.call(rbind, results)
}

#' Run \code{nm_do_all} Per Site
#'
#' @inheritParams nm_do_all
#' @param site_col Character. Site identifier column.
#' @param return_models Logical. If TRUE, also return a list of models per site.
#' @param ... Additional arguments passed to \code{nm_do_all}.
#'
#' @return A data.frame of normalised results (or a list with \code{res}
#'         and \code{models} if \code{return_models = TRUE}).
#' @export
nm_do_all_multisite <- function(df, site_col, value = "value",
                                predictors = NULL, backend = "lightgbm",
                                n_cores = NULL, return_models = FALSE,
                                ...) {
  models <- list()

  per_site <- function(df, ...) {
    res <- nm_do_all(df = df, value = value, predictors = predictors,
      backend = backend, ...)
    if (return_models) models[[length(models) + 1]] <<- res$model
    res$res
  }

  result <- nm_multisite_apply(df, site_col, per_site, n_cores = n_cores, ...)
  if (return_models) list(res = result, models = models) else result
}

#' Run \code{nm_decompose} Per Site
#'
#' @inheritParams nm_decompose
#' @param site_col Character. Site identifier column.
#' @param ... Additional arguments passed to \code{nm_decompose}.
#'
#' @return A data.frame of decomposition results with \code{site_col} appended.
#' @export
nm_decompose_multisite <- function(df, site_col, method = "emission",
                                   value = "value", predictors = NULL,
                                   backend = "lightgbm", n_cores = NULL, ...) {
  per_site <- function(df, ...) {
    nm_decompose(method = method, df = df, value = value,
      predictors = predictors, backend = backend, ...)
  }
  nm_multisite_apply(df, site_col, per_site, n_cores = n_cores, ...)
}
