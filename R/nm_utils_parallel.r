#' Propagate the Master's Library Paths to Cluster Workers (Internal Helper)
#'
#' @description
#' PSOCK workers created by \code{parallel::makeCluster()} start with their own
#' default \code{.libPaths()}, which does not include any non-standard library
#' the master process is using (e.g. a temporary library used while \code{R CMD
#' check} builds vignettes, or an \code{renv}/\code{pak} project library). When
#' that happens, workers cannot find or load 'normet' itself, and functions
#' exported to them via \code{foreach(.export = ...)} fail with
#' "could not find function" even though the function was exported, because the
#' function's own lexical scope (the 'normet' namespace) cannot be reconstructed
#' on the worker. Call this right after creating the cluster and before
#' registering it with \code{doSNOW}/\code{doParallel}.
#'
#' @param cl A cluster object as returned by \code{parallel::makeCluster()}.
#'
#' @return Invisibly, the cluster object.
#'
#' @noRd
.nm_propagate_libpaths <- function(cl) {
  lib_paths <- .libPaths()
  parallel::clusterCall(cl, function(lp) .libPaths(lp), lib_paths)
  invisible(cl)
}
