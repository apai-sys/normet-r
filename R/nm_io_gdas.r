# GDAS1 Meteorology Downloader (ARL format) for HYSPLIT
#
# Ported from Python normet io/gdas.py
# Fetches the weekly GDAS1 (1-degree) ARL files from NOAA ARL's archive so you
# can drive nm_run_back_trajectories() when you don't already have local met.
# Files are ARL-packed and large (~570 MB each), so downloads are streamed to
# disk and cached -- an existing file is never re-fetched.
#
# Archive:   https://www.ready.noaa.gov/data/archives/gdas1/
# Filenames: gdas1.<mmm><yy>.w<N>  (e.g. gdas1.apr20.w1); week index covers
#            days 1-7 (w1), 8-14 (w2), 15-21 (w3), 22-28 (w4), 29-31 (w5).

NULL

#' GDAS1 ARL archive base URL
#' @export
nm_arl_gdas1_base_url <- "https://www.ready.noaa.gov/data/archives/gdas1"

.gdas_months <- c(
  "jan", "feb", "mar", "apr", "may", "jun",
  "jul", "aug", "sep", "oct", "nov", "dec"
)

# ARL week-of-month index: 1-7->1, 8-14->2, 15-21->3, 22-28->4, 29-31->5.
.gdas1_week <- function(day) pmin((as.integer(day) - 1L) %/% 7L + 1L, 5L)

#' Weekly GDAS1 filenames covering a date range
#'
#' @param date_from,date_to Inclusive date range (Date or anything
#'   \code{as.Date} accepts). For HYSPLIT \strong{back}-trajectories this must
#'   reach back to \code{receptor_time - hours_back}, not just the receptor
#'   times.
#'
#' @return Character vector of unique \code{gdas1.<mmm><yy>.w<N>} filenames in
#'   chronological order.
#' @export
nm_gdas1_filenames <- function(date_from, date_to) {
  d0 <- as.Date(date_from)
  d1 <- as.Date(date_to)
  if (d1 < d0) {
    tmp <- d0
    d0 <- d1
    d1 <- tmp
  }
  days <- seq(d0, d1, by = "day")
  mon <- .gdas_months[as.integer(format(days, "%m"))]
  yy <- as.integer(format(days, "%y"))
  wk <- .gdas1_week(as.integer(format(days, "%d")))
  unique(sprintf("gdas1.%s%02d.w%d", mon, yy, wk))
}

#' Download GDAS1 weekly ARL files covering a date range
#'
#' Streams each weekly GDAS1 file (~570 MB) into \code{cache_dir} and returns
#' the local paths, ready to pass as \code{met_files} to
#' \code{\link{nm_run_back_trajectories}}. A file already present is reused.
#'
#' @param date_from,date_to Inclusive range to cover; see
#'   \code{\link{nm_gdas1_filenames}} (include the full backward window for
#'   back-trajectories).
#' @param cache_dir Directory to download into / reuse from.
#' @param base_url Archive base URL. Default \code{nm_arl_gdas1_base_url}.
#' @param overwrite Logical; re-download even if the file exists. Default FALSE.
#' @param on_missing One of \code{"error"} or \code{"warn"} -- what to do if a
#'   weekly file returns HTTP 404 (e.g. a date outside the archive coverage).
#' @param timeout Per-request timeout in seconds. Default 600.
#'
#' @return Character vector of local file paths, in chronological order.
#' @export
nm_fetch_gdas1 <- function(date_from, date_to, cache_dir,
                           base_url = nm_arl_gdas1_base_url,
                           overwrite = FALSE, on_missing = c("error", "warn"),
                           timeout = 600) {
  nm_require("httr2", hint = "install.packages('httr2')")
  on_missing <- match.arg(on_missing)
  log <- nm_get_logger("io.gdas")

  cache <- path.expand(cache_dir)
  dir.create(cache, recursive = TRUE, showWarnings = FALSE)

  paths <- character(0)
  for (name in nm_gdas1_filenames(date_from, date_to)) {
    dest <- file.path(cache, name)
    if (file.exists(dest) && !overwrite) {
      log$info("Reusing cached GDAS1 file: %s", dest)
      paths <- c(paths, dest)
      next
    }

    url <- paste0(sub("/$", "", base_url), "/", name)
    log$info("Downloading GDAS1 %s", url)
    tmp <- paste0(dest, ".part")

    req <- httr2::request(url)
    req <- httr2::req_timeout(req, timeout)
    req <- httr2::req_error(req, is_error = function(resp) FALSE)  # handle status ourselves
    resp <- httr2::req_perform(req, path = tmp)                    # stream body to disk
    status <- httr2::resp_status(resp)

    if (status >= 400) {
      if (file.exists(tmp)) unlink(tmp)
      msg <- sprintf("HTTP %d downloading %s", status, url)
      if (status == 404 && on_missing == "warn") {
        log$warn("GDAS1 file not available in archive: %s", url)
        next
      }
      stop(msg)
    }

    file.rename(tmp, dest)
    log$info("Saved %s (%.0f MB)", dest, file.info(dest)$size / 1e6)
    paths <- c(paths, dest)
  }

  paths
}
