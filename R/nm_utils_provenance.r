# Provenance Tracking
#
# Ported from Python normet utils/provenance.py
# Provides a lightweight container for bundling results with metadata.

NULL

#' Create a Provenance Run Record
#'
#' Bundle a result with metadata describing how it was produced.
#'
#' @param result The primary result (typically a data frame).
#' @param kind Character. Short label (e.g., \code{"do_all"}, \code{"scm"}).
#' @param config List. Configuration that produced the result.
#' @param df Input data frame (optional, for hashing).
#' @param df_prep Prepared data frame (optional).
#' @param model Trained model object (optional).
#' @param seed Integer. Random seed used.
#' @param extra List. Extra metadata.
#'
#' @return A list of class \code{"nm_run"} containing the result and metadata.
#' @export
nm_make_run <- function(result, kind = "run", config = NULL,
                        df = NULL, df_prep = NULL, model = NULL,
                        seed = NULL, extra = NULL) {
  meta <- list(
    kind = kind,
    normet_version = utils::packageVersion("normet"),
    r_version = paste(R.version$major, R.version$minor, sep = "."),
    platform = paste(Sys.info()[c("sysname", "release")], collapse = " "),
    host = Sys.info()["nodename"],
    user = Sys.info()["user"],
    timestamp = format(Sys.time(), tz = "UTC", usetz = TRUE),
    seed = seed
  )

  if (!is.null(df)) {
    tryCatch(
      {
        meta$data_hash <- nm_dataframe_hash(df)
        meta$data_shape <- dim(df)
      },
      error = function(e) NULL)
  }
  if (!is.null(config)) {
    meta$config <- config
    meta$config_hash <- nm_config_hash(config)
  }
  if (!is.null(extra)) meta$extra <- extra

  structure(
    list(
      result = result,
      model = model,
      df_prep = df_prep,
      metadata = meta
    ),
    class = "nm_run"
  )
}

#' @export
print.nm_run <- function(x, ...) {
  kind <- x$metadata$kind %||% "run"
  ts <- x$metadata$timestamp %||% "?"
  pkg_ver <- x$metadata$normet_version %||% "?"
  cat("<nm_run> kind=", kind, " | normet=", pkg_ver, " | at=", ts, "\n", sep = "")
}

#' Save a Provenance Run to Disk
#'
#' Persist an \code{nm_run} object to disk using \code{base::saveRDS}.
#'
#' @param run An object of class \code{"nm_run"}.
#' @param path Character. File path (without extension).
#' @param compress Logical. Compress the RDS file.
#'
#' @return Invisibly, a named vector of saved file paths.
#' @export
nm_save_run <- function(run, path, compress = TRUE) {
  rds_path <- paste0(path, ".rds")
  saveRDS(run, rds_path, compress = compress)

  json_path <- paste0(path, ".meta.json")
  safe_meta <- .coerce_json_safe(run$metadata)
  json_lines <- jsonlite::toJSON(safe_meta, pretty = TRUE, auto_unbox = TRUE)
  writeLines(json_lines, json_path)

  message("Saved nm_run -> ", rds_path, " (+ ", basename(json_path), ")")
  invisible(c(artifact = rds_path, metadata = json_path))
}

#' Load a Provenance Run from Disk
#'
#' Load an \code{nm_run} object previously saved with \code{nm_save_run}.
#'
#' @param path Character. File path to the .rds file, or the base path.
#'
#' @return An object of class \code{"nm_run"}.
#' @export
nm_load_run <- function(path) {
  if (!grepl("\\.rds$", path)) path <- paste0(path, ".rds")
  if (!file.exists(path)) stop("File not found: ", path)
  run <- readRDS(path)
  if (!inherits(run, "nm_run")) stop("Loaded object is not an nm_run.")
  run
}

.coerce_json_safe <- function(obj) {
  if (is.null(obj) || is.logical(obj) || is.numeric(obj) || is.character(obj)) return(obj)
  if (is.list(obj)) return(lapply(obj, .coerce_json_safe))
  if (is.data.frame(obj)) return(paste0(deparse(head(obj, 4)), collapse = "\n"))
  if (is.function(obj) || is.environment(obj)) return(paste0("<", typeof(obj), ">"))
  if (is.call(obj) || is.name(obj) || is.expression(obj)) return(deparse(obj))
  if (is.raw(obj) || is.complex(obj)) return(paste0("<", typeof(obj), ">"))
  tryCatch(as.character(obj), error = function(e) paste0("<", typeof(obj), ">"))
}
