# HYSPLIT Back-Trajectory Adapter
#
# Ported from Python normet io/trajectory.py
# Turns HYSPLIT back-trajectory output (`tdump` files) into per-receptor
# transport features that can be joined onto an air-quality panel and used as
# transport-aware predictors in normet pipelines.
#
# The parsing/feature functions CONSUME trajectory output. If you have a built
# HYSPLIT `hyts_std` executable and ARL met files, nm_run_back_trajectories()
# can also drive the runs end-to-end. Trajectory generation otherwise happens
# outside normet (e.g. with splitr, pysplit, or `hyts_std` directly).

NULL

.TDUMP_BASE_COLS <- c(
  "traj", "grid", "year", "month", "day", "hour", "minute",
  "fcast", "age", "lat", "lon", "height"
)

.haversine_km <- function(lat1, lon1, lat2, lon2) {
  r <- 6371.0
  p1 <- lat1 * pi / 180
  p2 <- lat2 * pi / 180
  dphi <- (lat2 - lat1) * pi / 180
  dl <- (lon2 - lon1) * pi / 180
  a <- sin(dphi / 2)^2 + cos(p1) * cos(p2) * sin(dl / 2)^2
  2 * r * asin(pmin(1, sqrt(a)))
}

.bearing_deg <- function(lat0, lon0, lat1, lon1) {
  dl <- (lon1 - lon0) * pi / 180
  y <- sin(dl) * cos(lat1 * pi / 180)
  x <- cos(lat0 * pi / 180) * sin(lat1 * pi / 180) -
    sin(lat0 * pi / 180) * cos(lat1 * pi / 180) * cos(dl)
  (atan2(y, x) * 180 / pi + 360) %% 360
}

#' Parse a HYSPLIT tdump trajectory file
#'
#' Parse a single HYSPLIT endpoints (`tdump`) file into a tidy data.table.
#'
#' @param path Character. Path to a HYSPLIT `tdump` file.
#'
#' @return A data.table with one row per trajectory endpoint and columns
#'   `traj` (trajectory index, in case the file holds several), `datetime`
#'   (endpoint time), `age_h` (hours from the receptor; 0 at the receptor,
#'   negative going back), `lat`, `lon`, `height`, plus any diagnostic
#'   variables written by the run (e.g. `pressure`, `rainfall`, `blh` from
#'   `MIXDEPTH`, `rh` from `RELHUMID`).
#' @export
nm_read_trajectory_tdump <- function(path) {
  lines <- readLines(path, warn = FALSE)
  i <- 1L

  # 1) number of meteorological grids, then one info line each.
  n_met <- as.integer(strsplit(trimws(lines[i]), "\\s+")[[1]][1])
  i <- i + 1L + n_met

  # 2) "<n_traj> <direction> <vert-motion>", then one starting-location each.
  n_traj <- as.integer(strsplit(trimws(lines[i]), "\\s+")[[1]][1])
  i <- i + 1L + n_traj

  # 3) "<n_var> <NAME1> <NAME2> ...": diagnostic output variables.
  parts <- strsplit(trimws(lines[i]), "\\s+")[[1]]
  n_var <- as.integer(parts[1])
  var_names <- tolower(parts[seq_len(n_var) + 1L])
  i <- i + 1L

  cols <- c(.TDUMP_BASE_COLS, var_names)
  data_lines <- lines[i:length(lines)]
  data_lines <- data_lines[nzchar(trimws(data_lines))]
  split_rows <- lapply(data_lines, function(ln) strsplit(trimws(ln), "\\s+")[[1]])
  split_rows <- Filter(function(r) length(r) >= length(cols), split_rows)
  if (length(split_rows) == 0) {
    stop("No trajectory data rows parsed from ", path)
  }

  mat <- do.call(rbind, lapply(split_rows, function(r) r[seq_along(cols)]))
  df <- as.data.frame(mat, stringsAsFactors = FALSE)
  colnames(df) <- cols
  df[] <- lapply(df, as.numeric)

  yr <- as.integer(df$year)
  yr <- ifelse(yr < 50, 2000L + yr, ifelse(yr < 100, 1900L + yr, yr))
  df$datetime <- ISOdatetime(
    yr, as.integer(df$month), as.integer(df$day),
    as.integer(df$hour), as.integer(df$minute), 0, tz = "UTC"
  )
  df$age_h <- as.numeric(df$age)

  # Standardise common diagnostic names to normet-friendly short forms.
  if ("mixdepth" %in% colnames(df)) colnames(df)[colnames(df) == "mixdepth"] <- "blh"
  if ("relhumid" %in% colnames(df)) colnames(df)[colnames(df) == "relhumid"] <- "rh"

  data.table::as.data.table(df)
}

#' Reduce one back-trajectory to a feature vector
#'
#' Collapse a single back-trajectory into a fixed-length named list of
#' transport descriptors.
#'
#' @param traj A single trajectory (e.g. one `traj` group from
#'   \code{\link{nm_read_trajectory_tdump}}). Needs `age_h`, `lat`, `lon`,
#'   `height`; uses `rainfall` / `blh` if present.
#' @param source_regions Optional named list of bounding boxes
#'   `list(name = c(lon_min, lat_min, lon_max, lat_max))`. For each, the
#'   fraction of trajectory time spent inside is returned as
#'   `<prefix>resid_<name>` (a residence-time proxy).
#' @param prefix Character. Prefix for every feature name. Default `"traj_"`.
#'
#' @return A named list of transport descriptors: straight-line reach, path
#'   length, mean transport speed, inflow bearing, mean/min height, optional
#'   rainfall sum / mean boundary-layer height, and per-region residence
#'   fractions.
#' @export
nm_trajectory_features <- function(traj, source_regions = NULL, prefix = "traj_") {
  if (is.null(traj) || nrow(traj) == 0) {
    return(list())
  }
  # age_h is 0 at the receptor and negative going back, so order descending to
  # put the receptor first and the oldest endpoint (air origin) last.
  t <- as.data.frame(traj)
  t <- t[order(-t$age_h), ]
  n <- nrow(t)
  lat0 <- t$lat[1]
  lon0 <- t$lon[1]
  latn <- t$lat[n]
  lonn <- t$lon[n]

  step <- .haversine_km(t$lat[-n], t$lon[-n], t$lat[-1], t$lon[-1])
  path_len <- sum(step, na.rm = TRUE)
  span_h <- abs(t$age_h[n] - t$age_h[1])

  f <- list()
  f[[paste0(prefix, "dist_km")]] <- .haversine_km(lat0, lon0, latn, lonn)
  f[[paste0(prefix, "pathlen_km")]] <- path_len
  f[[paste0(prefix, "speed_kmh")]] <- if (span_h > 0) path_len / span_h else NA_real_
  f[[paste0(prefix, "inflow_deg")]] <- .bearing_deg(lat0, lon0, latn, lonn)
  f[[paste0(prefix, "height_mean")]] <- mean(t$height)
  f[[paste0(prefix, "height_min")]] <- min(t$height)

  if (!is.null(source_regions)) {
    for (name in names(source_regions)) {
      bb <- source_regions[[name]] # c(lon_min, lat_min, lon_max, lat_max)
      inside <- t$lon >= bb[1] & t$lon <= bb[3] & t$lat >= bb[2] & t$lat <= bb[4]
      f[[paste0(prefix, "resid_", name)]] <- mean(inside)
    }
  }
  if ("rainfall" %in% colnames(t)) f[[paste0(prefix, "rain_sum")]] <- sum(t$rainfall)
  if ("blh" %in% colnames(t)) f[[paste0(prefix, "blh_mean")]] <- mean(t$blh)
  f
}

#' Build a receptor-time feature table from HYSPLIT tdump files
#'
#' Reduce many HYSPLIT `tdump` files to a transport-feature table, one row per
#' receptor timestamp, ready to merge onto a date-keyed air-quality panel.
#'
#' @param tdumps Character. A glob pattern (e.g. `"traj/tdump_*"`) or a vector
#'   of `tdump` file paths. One back-trajectory run per receptor time is the
#'   typical layout; files holding several trajectories are split per `traj`.
#' @param source_regions,prefix Forwarded to \code{\link{nm_trajectory_features}}.
#' @param date_col Character. Name of the receptor-timestamp column in the
#'   output, so it joins straight onto a date-keyed panel. Default `"date"`.
#'
#' @return A data.frame with a `date_col` column (receptor timestamp) and one
#'   `<prefix>*` column per feature, sorted by time and deduplicated on the
#'   receptor timestamp (last wins).
#' @export
nm_build_trajectory_features <- function(tdumps, source_regions = NULL,
                                         prefix = "traj_", date_col = "date") {
  paths <- if (is.character(tdumps) && length(tdumps) == 1) {
    Sys.glob(tdumps)
  } else {
    as.character(tdumps)
  }
  if (length(paths) == 0) {
    stop("No tdump files matched: ", tdumps)
  }
  log <- nm_get_logger("io.trajectory")

  rows <- list()
  for (p in paths) {
    traj <- tryCatch(
      nm_read_trajectory_tdump(p),
      error = function(e) {
        log$warn("Skipping trajectory file %s: %s", p, conditionMessage(e))
        NULL
      }
    )
    if (is.null(traj)) next
    tdf <- as.data.frame(traj)
    for (tid in unique(tdf$traj)) {
      g <- tdf[tdf$traj == tid, ]
      receptor <- g$datetime[which.min(abs(g$age_h))]
      feats <- nm_trajectory_features(g, source_regions = source_regions, prefix = prefix)
      rows[[length(rows) + 1L]] <- c(stats::setNames(list(receptor), date_col), feats)
    }
  }
  if (length(rows) == 0) {
    return(data.frame())
  }

  out <- data.table::rbindlist(lapply(rows, as.data.frame), fill = TRUE)
  out <- unique(out, by = date_col, fromLast = TRUE)
  data.table::setorderv(out, date_col)
  data.table::setDF(out)
  rownames(out) <- NULL
  log$info("Built trajectory features: %d receptors x %d columns", nrow(out), ncol(out) - 1L)
  out
}

# Render a HYSPLIT CONTROL file (character vector of lines) for one backward
# trajectory. Internal helper -- bare function, no man page.
.traj_control_text <- function(time, lat, lon, height_m, hours_back, met_files,
                               tdump_name, top_of_model, vert_motion) {
  ts <- as.POSIXct(time, tz = "UTC")
  lines <- c(
    format(ts, "%y %m %d %H", tz = "UTC"),               # start: YY MM DD HH
    "1",                                                  # one starting location
    sprintf("%.4f %.4f %.1f", lat, lon, height_m),
    as.character(-abs(as.integer(hours_back))),           # negative hours = BACKWARD
    as.character(as.integer(vert_motion)),                # 0 = use met vertical velocity
    sprintf("%.1f", top_of_model),
    as.character(length(met_files))                       # number of met files
  )
  for (mf in met_files) {                                 # each met -> (dir/, file)
    ab <- normalizePath(path.expand(mf), mustWork = FALSE)
    lines <- c(lines, paste0(dirname(ab), .Platform$file.sep), basename(ab))
  }
  c(lines, "./", tdump_name)                              # output dir (cwd), tdump name
}

#' Run HYSPLIT back-trajectories and reduce them to features
#'
#' For each receptor timestamp, write a HYSPLIT `CONTROL` file, run the
#' `hyts_std` executable (one backward trajectory ending at `(lat, lon,
#' height_m)`), then pass all resulting `tdump` files to
#' \code{\link{nm_build_trajectory_features}}.
#'
#' You must supply a built `hyts_std` and ARL-format met files; this helper
#' only orchestrates the runs and parses the output.
#'
#' @param times Vector of receptor (arrival) timestamps (POSIXct or anything
#'   `as.POSIXct` accepts).
#' @param lat,lon Numeric receptor location (degrees).
#' @param met_files Character vector of ARL met file(s). They must collectively
#'   cover the whole backward window (`hours_back` before each receptor time),
#'   else the trajectory truncates where the data runs out.
#' @param hysplit_exec Path to the `hyts_std` executable
#'   (e.g. `"~/hysplit-5.4.2/exec/hyts_std"`).
#' @param height_m Numeric receptor start height (m AGL). Default 500.
#' @param hours_back Integer backward duration in hours (sign ignored). Default 72.
#' @param work_dir Directory for `CONTROL`/`tdump_*`. A temp dir is created if
#'   `NULL`; tdumps are left there for inspection/reuse.
#' @param top_of_model,vert_motion HYSPLIT `CONTROL` settings (model top in m;
#'   `0` = use met vertical velocity).
#' @param source_regions,prefix Forwarded to
#'   \code{\link{nm_build_trajectory_features}}.
#' @param timeout Per-run timeout (seconds) for `hyts_std`. Default 600.
#'
#' @return The \code{\link{nm_build_trajectory_features}} table (one row per
#'   receptor time).
#'
#' @section macOS note:
#' HYSPLIT ships `x86_64` binaries (run under Rosetta on Apple Silicon)
#' downloaded via a disk image, so they carry a Gatekeeper quarantine flag. If
#' `hyts_std` is killed (exit 137) clear it once:
#' \preformatted{xattr -dr com.apple.quarantine /path/to/hysplit}
#'
#' @export
nm_run_back_trajectories <- function(times, lat, lon, met_files, hysplit_exec,
                                     height_m = 500, hours_back = 72,
                                     work_dir = NULL, top_of_model = 10000,
                                     vert_motion = 0, source_regions = NULL,
                                     prefix = "traj_", timeout = 600) {
  log <- nm_get_logger("io.trajectory")

  exe <- normalizePath(path.expand(hysplit_exec), mustWork = FALSE)
  if (!file.exists(exe) || file.access(exe, 1L) != 0) {
    stop("hyts_std not found or not executable: ", exe)
  }

  mets <- vapply(met_files, function(m) normalizePath(path.expand(m), mustWork = FALSE),
                 character(1), USE.NAMES = FALSE)
  miss <- mets[!file.exists(mets)]
  if (length(miss) > 0) stop("Met file(s) not found: ", paste(miss, collapse = ", "))

  work <- if (is.null(work_dir)) tempfile("nm_traj_") else path.expand(work_dir)
  dir.create(work, recursive = TRUE, showWarnings = FALSE)

  # hyts_std requires ASCDATA.CFG (surface land-use/roughness config) in the run
  # dir, else it aborts to a header-only tdump. Stage it from the install's
  # bdyfiles/ (trajectories fall back to default surface fields if the land-use
  # data isn't co-located -- adequate for trajectory work).
  if (!file.exists(file.path(work, "ASCDATA.CFG"))) {
    ascdata <- file.path(dirname(dirname(exe)), "bdyfiles", "ASCDATA.CFG")
    if (file.exists(ascdata)) {
      file.copy(ascdata, file.path(work, "ASCDATA.CFG"))
    } else {
      log$warn("ASCDATA.CFG not found at %s; hyts_std may abort (sfcinp).", ascdata)
    }
  }

  old_wd <- setwd(work)
  on.exit(setwd(old_wd), add = TRUE)

  times <- as.POSIXct(times, tz = "UTC")
  tdumps <- character(0)
  for (i in seq_along(times)) {
    ts <- times[i]
    name <- paste0("tdump_", format(ts, "%Y%m%d%H", tz = "UTC"))
    writeLines(
      .traj_control_text(ts, lat, lon, height_m, hours_back, mets, name,
                         top_of_model, vert_motion),
      "CONTROL"
    )
    res <- tryCatch(
      system2(exe, stdout = TRUE, stderr = TRUE, stdin = "/dev/null", timeout = timeout),
      error = function(e) {
        log$warn("hyts_std failed for %s: %s", format(ts), conditionMessage(e))
        NULL
      }
    )
    status <- attr(res, "status")
    if (!is.null(status) && status == 137) {
      stop("hyts_std was killed (exit 137) - likely macOS Gatekeeper quarantine. ",
           "Clear it once with:\n  xattr -dr com.apple.quarantine ", dirname(dirname(exe)))
    }
    if (!file.exists(name)) {
      log$warn("No tdump for %s (status=%s)", format(ts),
               if (is.null(status)) "0" else as.character(status))
      next
    }
    tdumps <- c(tdumps, normalizePath(name))
  }

  if (length(tdumps) == 0) {
    stop("No trajectories produced. Check met coverage of the backward window, ",
         "the CONTROL settings, and the hyts_std path.")
  }
  log$info("Ran %d back-trajectories -> %s", length(tdumps), work)
  nm_build_trajectory_features(tdumps, source_regions = source_regions, prefix = prefix)
}
