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
#' @param n_cores Integer. Parallel workers. If NULL, uses one fewer than the
#'        cores this process is actually allowed to use (which respects a batch
#'        scheduler's allocation or a container's CPU quota, not just the
#'        machine's size). Never exceeds the number of sites either way.
#' @param site_kwarg Character. If set, the site value is passed to \code{func}
#'        under this keyword argument.
#' @param ... Additional arguments passed to \code{func}.
#'
#' @return A data.frame with \code{site_col} appended, combining all sites.
#' @export
nm_multisite_apply <- function(df, site_col, func, n_cores = NULL,
                               site_kwarg = NULL, ...) {
  runs <- .nm_multisite_run(df, site_col, func, n_cores = n_cores,
    site_kwarg = site_kwarg, ...)
  .nm_multisite_bind(runs, site_col)
}

# Run `func` once per site in PSOCK workers; a list named by site, each element
# the function's value or an `nm_site_error` carrying the worker's message.
#
# Everything a worker needs is evaluated here first. Called from the console or a
# script, an argument such as `covariates = covs` is a promise on the global
# environment, and a promise travels to a PSOCK worker unevaluated; the worker,
# whose global environment is empty, then fails with "object 'covs' not found".
# Every site failed that way, and the error was replaced by NULL, so the only
# message was "All per-site runs failed." (2026-11-13). testthat never saw it:
# a test's environment is serialised with the closure, the global one is not.
.nm_multisite_run <- function(df, site_col, func, n_cores = NULL,
                              site_kwarg = NULL, ...) {
  if (!site_col %in% colnames(df)) stop("`site_col` '", site_col, "' not in df.")
  force(func)
  force(site_kwarg)
  dots <- list(...)
  sites <- unique(df[[site_col]])
  if (length(sites) == 0) return(list())

  # One site per worker, so the site count is the cap.
  n_cores <- .nm_resolve_cores(n_cores, n_tasks = length(sites))

  cl <- parallel::makeCluster(n_cores)
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
        args <- c(list(df = sub), dots)
        if (!is.null(site_kwarg)) args[[site_kwarg]] <- site_val
        do.call(func, args)
      },
      error = function(e) structure(list(message = conditionMessage(e)),
                                    class = "nm_site_error"))
  }
  results <- stats::setNames(results, as.character(sites))
  attr(results, "sites") <- sites  # the values as given, not their names
  results
}

# One table from per-site results: each site's rows with `site_col` added. A site
# that failed is named in a warning with its error; when every site failed, the
# error says why instead of only that they did.
.nm_multisite_bind <- function(runs, site_col) {
  if (length(runs) == 0) return(data.frame())
  failed <- vapply(runs, inherits, logical(1), what = "nm_site_error")
  if (any(failed)) {
    why <- vapply(runs[failed], `[[`, character(1), "message")
    msg <- paste0("  ", names(why), ": ", why, collapse = "\n")
    if (all(failed)) stop("All per-site runs failed:\n", msg, call. = FALSE)
    warning(sum(failed), " of ", length(runs), " sites failed and are left out:\n",
      msg, call. = FALSE)
  }
  sites <- attr(runs, "sites") %||% names(runs)
  tables <- list()
  for (i in which(!failed)) {
    res <- runs[[i]]
    if (is.list(res) && !is.data.frame(res) && "res" %in% names(res)) res <- res$res
    if (is.null(res) || nrow(res) == 0) next
    res[[site_col]] <- sites[[i]]
    tables[[length(tables) + 1]] <- res
  }
  if (length(tables) == 0) stop("No site returned any rows.", call. = FALSE)
  do.call(rbind, tables)
}

#' Run \code{nm_do_all} Per Site
#'
#' @inheritParams nm_do_all
#' @param site_col Character. Site identifier column.
#' @param return_models Logical. If TRUE, also return each site's model.
#' @param ... Additional arguments passed to \code{nm_do_all}.
#'
#' @return A data.frame of normalised results (or a list with \code{res}
#'         and \code{models}, a list named by site, if \code{return_models = TRUE}).
#'         A site whose run fails is left out with a warning that gives its error;
#'         if every site fails, the error lists each one.
#' @export
nm_do_all_multisite <- function(df, site_col, target = "value",
                                covariates = NULL, backend = "lightgbm",
                                n_cores = NULL, return_models = FALSE,
                                ...) {
  # Evaluated here, not in a worker: see .nm_multisite_run.
  force(target); force(covariates); force(backend); force(return_models)

  # A worker cannot write into this frame (`<<-` there changes the worker's copy),
  # so a site's model comes back in its return value or not at all.
  per_site <- function(df, ...) {
    res <- nm_do_all(df = df, target = target, covariates = covariates,
      backend = backend, ...)
    if (return_models) res[c("res", "model")] else res$res
  }

  runs <- .nm_multisite_run(df, site_col, per_site, n_cores = n_cores, ...)
  result <- .nm_multisite_bind(runs, site_col)
  if (!return_models) return(result)
  ok <- !vapply(runs, inherits, logical(1), what = "nm_site_error")
  list(res = result, models = lapply(runs[ok], `[[`, "model"))
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
                                   target = "value", covariates = NULL,
                                   backend = "lightgbm", n_cores = NULL, ...) {
  # Evaluated here, not in a worker: see .nm_multisite_run.
  force(method); force(target); force(covariates); force(backend)
  per_site <- function(df, ...) {
    nm_decompose(method = method, df = df, target = target,
      covariates = covariates, backend = backend, ...)
  }
  nm_multisite_apply(df, site_col, per_site, n_cores = n_cores, ...)
}
