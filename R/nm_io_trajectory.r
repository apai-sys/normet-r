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
#'   `MIXDEPTH`, `rh` from `RELHUMID`, `temp` from `AIR_TEMP`).
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
  if ("air_temp" %in% colnames(df)) colnames(df)[colnames(df) == "air_temp"] <- "temp"

  data.table::as.data.table(df)
}

#' Point-in-region test
#'
#' Tests points against a c(lon_min, lat_min, lon_max, lat_max) bbox, or an
#' sf/sfc polygon geometry (loaded via nm_load_source_regions()).
#' @noRd
.region_mask <- function(region, lon, lat) {
  if (is.numeric(region) && length(region) == 4) {
    return(lon >= region[1] & lon <= region[3] & lat >= region[2] & lat <= region[4])
  }
  nm_require("sf", hint = "install.packages('sf')")
  geom <- sf::st_geometry(region)
  if (length(geom) > 1) geom <- sf::st_union(geom)
  # GeoJSON/Shapefiles without an explicit CRS default to WGS84 (lon/lat).
  # Unpacking an sfc into a list (as nm_load_source_regions does, one
  # geometry per named region) strips the CRS from each element, so it
  # needs restoring here as well as defaulting when genuinely absent.
  if (is.na(sf::st_crs(geom))) sf::st_crs(geom) <- 4326
  pts <- sf::st_as_sf(
    data.frame(lon = lon, lat = lat), coords = c("lon", "lat"), crs = sf::st_crs(geom)
  )
  suppressMessages(lengths(sf::st_intersects(pts, geom)) > 0)
}

# Pairs of source regions that share area ("a & b"); regions that only touch do
# not. Boxes are compared directly; sf geometries need sf.
.overlapping_regions <- function(source_regions) {
  n <- length(source_regions)
  if (n < 2) return(character(0))
  is_box <- function(r) is.numeric(r) && length(r) == 4
  as_geom <- function(r) {
    if (is_box(r)) {
      return(sf::st_as_sfc(sf::st_bbox(
        c(xmin = r[1], ymin = r[2], xmax = r[3], ymax = r[4]), crs = sf::st_crs(4326)
      )))
    }
    g <- sf::st_geometry(r)
    if (is.na(sf::st_crs(g))) sf::st_crs(g) <- 4326
    g
  }
  nms <- names(source_regions)
  pairs <- character(0)
  for (i in seq_len(n - 1)) {
    for (j in (i + 1):n) {
      a <- source_regions[[i]]
      b <- source_regions[[j]]
      shared <- if (is_box(a) && is_box(b)) {
        a[1] < b[3] && b[1] < a[3] && a[2] < b[4] && b[2] < a[4]
      } else {
        nm_require("sf", hint = "install.packages('sf')")
        inter <- suppressMessages(sf::st_intersection(as_geom(a), as_geom(b)))
        length(inter) > 0 && any(as.numeric(sf::st_area(inter)) > 0)
      }
      if (isTRUE(shared)) pairs <- c(pairs, paste(nms[i], "&", nms[j]))
    }
  }
  pairs
}

#' Load named region polygons from a GeoJSON, Shapefile, or any vector
#' format \pkg{sf} can read
#'
#' Reads a vector file via \code{\link[sf]{st_read}} — GeoJSON, ESRI
#' Shapefile (\code{.shp}, with its sibling \code{.dbf}/\code{.shx}),
#' GeoPackage, or anything else GDAL/OGR supports — and returns one polygon
#' geometry per feature, named from its \code{name} (or \code{id},
#' \code{NAME}) attribute. Pass the result (alone, or mixed with
#' bounding-box vectors) as \code{\link{nm_trajectory_features}}'s
#' \code{source_regions} for exact point-in-polygon residence time — unlike
#' a bounding box, it respects concave and multi-part boundaries, so this is
#' the natural way to use real administrative or airshed boundaries (many of
#' which ship as Shapefiles, not GeoJSON).
#'
#' @param path Character. Path to a vector file (\code{.geojson}, \code{.shp}, …).
#'
#' @return A named list of \code{sfc} geometries.
#' @note Needs the \pkg{sf} package (\code{install.packages("sf")}).
#' @export
nm_load_source_regions <- function(path) {
  nm_require("sf", hint = "install.packages('sf')")
  gj <- sf::st_read(path, quiet = TRUE)
  props <- as.data.frame(gj)
  name_col <- intersect(c("name", "id", "NAME"), names(props))
  names_out <- if (length(name_col) > 0) {
    as.character(props[[name_col[1]]])
  } else {
    paste0("region_", seq_len(nrow(gj)) - 1L)
  }
  geoms <- sf::st_geometry(gj)
  out <- stats::setNames(as.list(geoms), names_out)
  out
}

#' Collapse a single back-trajectory into a fixed-length named list of
#' transport descriptors.
#'
#' @param traj A single trajectory (e.g. one `traj` group from
#'   \code{\link{nm_read_trajectory_tdump}}). Needs `age_h`, `lat`, `lon`,
#'   `height`; uses `rainfall` / `blh` if present.
#' @param source_regions Optional named list where each element is either a
#'   bounding box `c(lon_min, lat_min, lon_max, lat_max)`, or an sf/sfc
#'   polygon geometry (e.g. from \code{\link{nm_load_source_regions}})
#'   for exact point-in-polygon residence time. For each, the fraction of
#'   trajectory time spent inside is returned as `<prefix>resid_<name>`. An
#'   endpoint inside several overlapping regions counts towards each, so the
#'   fractions are only shares of the trajectory when the regions do not
#'   overlap; \code{\link{nm_build_trajectory_features}} warns when they do.
#' @param prefix Character. Prefix for every feature name. Default `"traj_"`.
#' @param min_hours Optional numeric. Minimum backward reach (hours) a
#'   trajectory must have to be trusted. A trajectory whose span is shorter --
#'   HYSPLIT stopped early because the met files ran out, or it left the model
#'   domain -- has every feature except the two quality columns set to `NA`,
#'   rather than passing off a truncated path as a short-range one. `NULL`
#'   (default) keeps every trajectory, leaving detection to `<prefix>age_max_h`.
#'
#' @return A named list of transport descriptors: quality columns
#'   `<prefix>n_endpoints` and `<prefix>age_max_h` (hours the trajectory
#'   actually reached back), straight-line reach, path
#'   length, mean transport speed, inflow bearing, mean/min height,
#'   per-region residence fractions, and — only if the `tdump` run wrote
#'   them — along-path rainfall sum, mean boundary-layer height, mean
#'   relative humidity, mean pressure, and mean air temperature.
#' @export
nm_trajectory_features <- function(traj, source_regions = NULL, prefix = "traj_",
                                   min_hours = NULL) {
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
  f[[paste0(prefix, "n_endpoints")]] <- as.numeric(n)
  f[[paste0(prefix, "age_max_h")]] <- span_h
  f[[paste0(prefix, "dist_km")]] <- .haversine_km(lat0, lon0, latn, lonn)
  f[[paste0(prefix, "pathlen_km")]] <- path_len
  f[[paste0(prefix, "speed_kmh")]] <- if (span_h > 0) path_len / span_h else NA_real_
  f[[paste0(prefix, "inflow_deg")]] <- .bearing_deg(lat0, lon0, latn, lonn)
  f[[paste0(prefix, "height_mean")]] <- mean(t$height)
  f[[paste0(prefix, "height_min")]] <- min(t$height)

  if (!is.null(source_regions)) {
    for (name in names(source_regions)) {
      region <- source_regions[[name]]
      inside <- .region_mask(region, t$lon, t$lat)
      f[[paste0(prefix, "resid_", name)]] <- mean(inside)
    }
  }
  if ("rainfall" %in% colnames(t)) f[[paste0(prefix, "rain_sum")]] <- sum(t$rainfall)
  if ("blh" %in% colnames(t)) f[[paste0(prefix, "blh_mean")]] <- mean(t$blh)
  if ("rh" %in% colnames(t)) f[[paste0(prefix, "rh_mean")]] <- mean(t$rh)
  if ("pressure" %in% colnames(t)) f[[paste0(prefix, "pressure_mean")]] <- mean(t$pressure)
  if ("temp" %in% colnames(t)) f[[paste0(prefix, "temp_mean")]] <- mean(t$temp)
  if (!is.null(min_hours) && span_h < min_hours - 1e-6) {
    quality <- paste0(prefix, c("n_endpoints", "age_max_h"))
    f[setdiff(names(f), quality)] <- NA_real_
  }
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
#' @param source_regions,prefix,min_hours Forwarded to
#'   \code{\link{nm_trajectory_features}}. With `min_hours` set, the number of
#'   trajectories nulled for being truncated is logged.
#' @param date_col Character. Name of the receptor-timestamp column in the
#'   output, so it joins straight onto a date-keyed panel. Default `"date"`.
#'
#' @return A data.frame with a `date_col` column (receptor timestamp) and one
#'   `<prefix>*` column per feature, sorted by time and deduplicated on the
#'   receptor timestamp (last wins). Trajectories started at several heights --
#'   a run with a column of starting points, or runs at different heights mixed
#'   -- each get their own columns, suffixed with the start height:
#'   `traj_dist_km_500m`, `traj_dist_km_1500m`.
#'
#'   Stops when the trajectories start from more than one place: a feature
#'   table is one receptor's. Build each site's on its own (and tag it with a
#'   `site` column to join several, see \code{\link{nm_join_trajectory_features}}).
#' @export
nm_build_trajectory_features <- function(tdumps, source_regions = NULL,
                                         prefix = "traj_", date_col = "date",
                                         min_hours = NULL) {
  paths <- if (is.character(tdumps) && length(tdumps) == 1) {
    Sys.glob(tdumps)
  } else {
    as.character(tdumps)
  }
  if (length(paths) == 0) {
    stop("No tdump files matched: ", tdumps)
  }
  log <- nm_get_logger("io.trajectory")
  overlaps <- if (!is.null(source_regions)) .overlapping_regions(source_regions) else character(0)
  if (length(overlaps) > 0) {
    log$warn(paste0(
      "Source regions overlap (%s): an endpoint in a shared area counts towards each of ",
      "them, so their residence fractions can add up to more than 1 and are not shares of ",
      "the trajectory."
    ), paste(overlaps, collapse = ", "))
  }

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
      # The endpoint at age 0 is where (and when) the trajectory starts.
      start <- g[which.min(abs(g$age_h)), ]
      feats <- nm_trajectory_features(g,
        source_regions = source_regions, prefix = prefix, min_hours = min_hours
      )
      rows[[length(rows) + 1L]] <- c(
        stats::setNames(list(start$datetime), date_col),
        stats::setNames(
          list(start$lat, start$lon, round(start$height, 1)), .START_COLS
        ),
        feats
      )
    }
  }
  if (length(rows) == 0) {
    return(data.frame())
  }

  frame <- data.table::rbindlist(lapply(rows, as.data.frame), fill = TRUE)
  .check_one_receptor(frame)
  frame[, c(.START_COLS[1:2]) := NULL]
  frame <- unique(frame, by = c(date_col, .START_COLS[3]), fromLast = TRUE)
  age_col <- paste0(prefix, "age_max_h")
  if (!is.null(min_hours) && age_col %in% colnames(frame)) {
    n_short <- sum(frame[[age_col]] < min_hours - 1e-6, na.rm = TRUE)
    if (n_short > 0) {
      log$warn(
        "%d of %d trajectories reach back < %g h (truncated); their features are NA.",
        n_short, nrow(frame), min_hours
      )
    }
  }
  heights <- sort(unique(frame[[.START_COLS[3]]]))
  if (length(heights) > 1) {
    # Keyed on time alone, the heights would overwrite one another: one column
    # set per height instead.
    parts <- lapply(heights, function(h) {
      part <- frame[frame[[.START_COLS[3]]] == h]
      part[, c(.START_COLS[3]) := NULL]
      feat_cols <- setdiff(names(part), date_col)
      data.table::setnames(part, feat_cols, paste0(feat_cols, sprintf("_%gm", h)))
      part
    })
    out <- Reduce(function(a, b) merge(a, b, by = date_col, all = TRUE), parts)
    log$info(
      "Trajectories start at %d heights (%s m): each height's features are suffixed with it.",
      length(heights), paste(sprintf("%g", heights), collapse = ", ")
    )
  } else {
    out <- frame
    out[, c(.START_COLS[3]) := NULL]
  }
  data.table::setorderv(out, date_col)
  data.table::setDF(out)
  rownames(out) <- NULL
  log$info("Built trajectory features: %d receptors x %d columns", nrow(out), ncol(out) - 1L)
  out
}

# Where a trajectory starts, carried alongside its features while the table is built.
.START_COLS <- c(".start_lat", ".start_lon", ".start_height")
# Starting points this close (degrees) are one receptor: tdumps print 3 decimals.
.SAME_PLACE_DEG <- 0.01

# Stop if the trajectories in `frame` start from more than one place.
.check_one_receptor <- function(frame) {
  lat <- frame[[.START_COLS[1]]]
  lon <- frame[[.START_COLS[2]]]
  if (diff(range(lat)) <= .SAME_PLACE_DEG && diff(range(lon)) <= .SAME_PLACE_DEG) {
    return(invisible(NULL))
  }
  places <- unique(data.frame(lat = round(lat, 2), lon = round(lon, 2)))
  shown <- paste(sprintf("(%g, %g)", utils::head(places$lat, 4), utils::head(places$lon, 4)),
                 collapse = ", ")
  stop(sprintf(paste0(
    "The trajectories start from %d different places (%s%s): build each receptor's ",
    "features on its own, tagged with a 'site' column if they are to be joined together."
  ), nrow(places), shown, if (nrow(places) > 4) ", ..." else ""), call. = FALSE)
}

# Times on HYSPLIT's clock, UTC, as seconds: a POSIXct is an instant already; text
# with an offset is converted by it, and text without one is taken as UTC.
.utc_seconds <- function(values) {
  if (inherits(values, "POSIXct")) return(as.numeric(values))
  as.numeric(.to_datetime_coerced(values))
}

# A duration (seconds) from a difftime, a number of hours, or text: "6h", "30 min",
# "2 hours", "1 day".
.as_seconds <- function(x) {
  if (inherits(x, "difftime")) return(as.numeric(x, units = "secs"))
  if (is.numeric(x)) return(x * 3600)
  m <- regmatches(x, regexec("^\\s*([0-9.]+)\\s*([A-Za-z]*)\\s*$", x))[[1]]
  if (length(m) == 0) stop(sprintf("Cannot read %s as a duration", deparse(x)), call. = FALSE)
  unit <- tolower(m[3])
  mult <- if (unit %in% c("s", "sec", "secs", "second", "seconds")) {
    1
  } else if (unit %in% c("m", "min", "mins", "minute", "minutes", "t")) {
    60
  } else if (unit %in% c("", "h", "hr", "hrs", "hour", "hours")) {
    3600
  } else if (unit %in% c("d", "day", "days")) {
    86400
  } else {
    stop(sprintf("Unknown unit '%s' in %s", m[3], deparse(x)), call. = FALSE)
  }
  as.numeric(m[2]) * mult
}

# The commonest step (seconds) between one site's successive trajectories (the
# smaller on a tie), or NULL when no site has two.
.release_interval <- function(times, sites) {
  steps <- unlist(lapply(split(times, sites), function(t) diff(sort(t))), use.names = FALSE)
  steps <- steps[steps > 0]
  if (length(steps) == 0) return(NULL)
  tab <- table(steps)
  min(as.numeric(names(tab)[tab == max(tab)]))
}

.hours_text <- function(seconds) sprintf("%g h", seconds / 3600)

#' Join trajectory features onto a panel, each row taking the latest
#' trajectory to have arrived
#'
#' A row at time \emph{t} takes the trajectory that arrived last at or before
#' \emph{t}, and only if it arrived less than `tolerance` before. A
#' nearest-time join instead hands a row the trajectory arriving after it --
#' air that has not reached the receptor yet -- and, with no tolerance, carries
#' the first and last trajectories over every row before and after them.
#'
#' @param df The panel: a data.frame with times in a `date_col` column.
#' @param features Receptor-time features, e.g. from
#'   \code{\link{nm_build_trajectory_features}} or
#'   \code{\link{nm_run_back_trajectories}}: times in a `date_col` column, one
#'   row per time (per site, with a `site_col` column).
#' @param date_col Name of the time column. Default `"date"`.
#' @param site_col When both frames have it, each row takes only its own site's
#'   trajectories (sites are matched as text), and rows of sites `features`
#'   does not hold are left as they were -- so the features of several sites
#'   can be joined one batch at a time. Default `"site"`.
#' @param tolerance How long a trajectory stands for after it arrives (a row
#'   strictly less than this after it takes it): a difftime, a number of hours,
#'   or text such as `"6h"`. Default: the release interval, the commonest step
#'   between one site's successive trajectories -- every hour of a 6-hourly
#'   release window takes that window's trajectory, and a window whose
#'   trajectory is missing stays empty. With a single trajectory, only a row at
#'   its exact time takes it.
#'
#' @return A copy of `df`, rows in their order, with the feature columns added;
#'   a row no trajectory matches (or with no time) has them `NA`. A feature
#'   column `df` already had is replaced; its other columns are untouched.
#'   Stops if `features` holds several sites but `df` has no `site_col`, or
#'   several rows for one receptor time (and site).
#'
#' @section Time zones: Times are compared as UTC, HYSPLIT's clock: POSIXct
#'   values are instants whatever their time zone, text with an offset is
#'   converted by it, and text without one is taken to be UTC.
#'
#' @examples
#' panel <- data.frame(date = seq(as.POSIXct("2020-01-02 00:00", tz = "UTC"),
#'                                by = "hour", length.out = 12))
#' feats <- data.frame(date = as.POSIXct(c("2020-01-02 00:00", "2020-01-02 06:00"),
#'                                       tz = "UTC"), traj_x = c(0, 6))
#' nm_join_trajectory_features(panel, feats)
#' @export
nm_join_trajectory_features <- function(df, features, date_col = "date", site_col = "site",
                                        tolerance = NULL) {
  log <- nm_get_logger("io.trajectory")
  if (!date_col %in% names(df)) stop(sprintf("df has no '%s' column", date_col), call. = FALSE)
  if (!date_col %in% names(features)) {
    stop(sprintf("features have no '%s' column", date_col), call. = FALSE)
  }
  is_dt <- data.table::is.data.table(df)
  df <- as.data.frame(df, stringsAsFactors = FALSE)
  features <- as.data.frame(features, stringsAsFactors = FALSE)
  when <- .utc_seconds(df[[date_col]])
  ftimes <- .utc_seconds(features[[date_col]])
  cols <- setdiff(names(features), c(date_col, site_col))
  if (length(cols) == 0) stop("features hold no feature columns", call. = FALSE)

  has_fsite <- site_col %in% names(features)
  fsite <- if (has_fsite) as.character(features[[site_col]]) else rep("", nrow(features))
  by_site <- has_fsite && site_col %in% names(df)
  feature_sites <- sort(unique(fsite))
  if (has_fsite && !by_site && length(feature_sites) > 1) {
    stop(sprintf("features hold %d sites (%s) but df has no '%s' column to match them on",
                 length(feature_sites), paste(feature_sites, collapse = ", "), site_col),
         call. = FALSE)
  }
  known <- !is.na(ftimes)
  dup <- duplicated(data.frame(t = ftimes[known], s = fsite[known]))
  if (any(dup)) {
    first <- .POSIXct(ftimes[known][dup][1], tz = "UTC")
    stop(sprintf(
      "features hold %d more row(s) for a receptor time already given (e.g. %s%s); keep one per time",
      sum(dup), format(first, "%Y-%m-%d %H:%M:%S"), if (by_site) " at one site" else ""
    ), call. = FALSE)
  }

  tol <- if (!is.null(tolerance)) {
    given <- .as_seconds(tolerance)
    if (!(given > 0)) {
      stop(sprintf("tolerance must be positive, got %s", format(tolerance)), call. = FALSE)
    }
    given
  } else {
    .release_interval(ftimes[known], fsite[known])
  }

  # For each row, the position in `features` of the latest trajectory at or
  # before it (within its site), within the tolerance.
  pos <- rep(NA_integer_, nrow(df))
  lsite <- if (by_site) as.character(df[[site_col]]) else rep("", nrow(df))
  for (s in feature_sites) {
    fi <- which(known & fsite == s)
    fi <- fi[order(ftimes[fi])]
    rows <- which(!is.na(when) & (if (by_site) lsite == s else TRUE))
    if (length(fi) == 0 || length(rows) == 0) next
    k <- findInterval(when[rows], ftimes[fi])
    hit <- k > 0
    gap <- rep(NA_real_, length(rows))
    gap[hit] <- when[rows][hit] - ftimes[fi][k[hit]]
    ok <- hit & (if (is.null(tol)) gap == 0 else gap < tol)
    pos[rows[ok]] <- fi[k[ok]]
  }

  in_scope <- if (by_site) lsite %in% feature_sites else rep(TRUE, nrow(df))
  out <- df
  replaced <- intersect(cols, names(df))
  for (c in cols) {
    values <- features[[c]][pos]
    if (!all(in_scope)) {
      prior <- if (c %in% replaced) df[[c]] else rep(NA, nrow(df))
      values[!in_scope] <- prior[!in_scope]
    }
    out[[c]] <- values
  }

  n_hit <- sum(!is.na(pos))
  gap_txt <- if (!is.null(tol)) sprintf("less than %s before", .hours_text(tol)) else "at the same time as"
  log$info(
    "Joined %d trajectory feature column(s): %d of %d rows took a trajectory (%s).",
    length(cols), n_hit, sum(in_scope),
    if (!is.null(tol)) sprintf("the latest to arrive, if %s the row", gap_txt) else "one arriving with it"
  )
  if (length(replaced)) {
    log$info("Replaced column(s) the panel already had: %s", paste(replaced, collapse = ", "))
  }
  if (site_col %in% names(df) && !has_fsite) {
    n_sites <- length(unique(df[[site_col]]))
    if (n_sites > 1) {
      log$warn(paste0(
        "The features have no '%s' column, so the rows of all %d of the panel's sites ",
        "took the same trajectories."
      ), site_col, n_sites)
    }
  }
  if (by_site) {
    absent <- setdiff(feature_sites, unique(lsite))
    if (length(absent)) {
      log$warn("No rows of site(s) %s in the panel's '%s' column; their trajectories were not used.",
               paste(absent, collapse = ", "), site_col)
    }
  }
  if (n_hit == 0) {
    fmt <- function(x) format(.POSIXct(x, tz = "UTC"), "%Y-%m-%d %H:%M:%S")
    log$warn(
      "No row took a trajectory: none arrived %s any of the panel's times (%s -> %s); they arrive %s -> %s.",
      gap_txt, fmt(min(when, na.rm = TRUE)), fmt(max(when, na.rm = TRUE)),
      fmt(min(ftimes, na.rm = TRUE)), fmt(max(ftimes, na.rm = TRUE))
    )
  }
  if (is_dt) data.table::setDT(out)
  out
}

# Parse an ARL met filename to an approximate [start, end] UTC date range.
# Understands GDAS1 naming: gdas1.{mon}{yy}.w{n}
# Returns NULL for unrecognised filenames (caller should keep them).
.parse_arl_date_range <- function(path) {
  bn <- basename(path)
  m  <- regexec("gdas1\\.([a-z]{3})(\\d{2})\\.w(\\d)", bn)[[1]]
  if (m[1] < 0) return(NULL)
  parts <- regmatches(bn, regexec("gdas1\\.([a-z]{3})(\\d{2})\\.w(\\d)", bn))[[1]]
  mon_n <- match(parts[2], tolower(month.abb))
  yr    <- 2000L + as.integer(parts[3])
  wk    <- as.integer(parts[4])
  day_s <- (wk - 1L) * 7L + 1L
  # End of week: clamp to the last second of the current month (handles
  # short months — e.g. feb.w5 day_e=35 would overflow with ISOdatetime).
  # Use the first second of the NEXT month minus 1s as a safe upper bound.
  next_mon  <- if (mon_n == 12L) 1L else mon_n + 1L
  next_yr   <- if (mon_n == 12L) yr + 1L else yr
  month_end <- ISOdatetime(next_yr, next_mon, 1L, 0L, 0L, 0L, tz = "UTC") - 1L
  week_end  <- ISOdatetime(yr, mon_n, 1L, 0L, 0L, 0L, tz = "UTC") +
               (wk * 7L - 1L) * 86400L + 86399L
  list(
    start = ISOdatetime(yr, mon_n, day_s, 0L, 0L, 0L, tz = "UTC"),
    end   = min(week_end, month_end)
  )
}

# GDAS1 is 3-hourly. A receptor time between a weekly file's last record and the
# next file's first one needs *both* to interpolate: probed against hyts_std with
# two adjacent daily ARL files, a start time in that gap (23:30, 23:59) failed
# with only the earlier file and ran with both. A strict "does the file's span
# overlap the window" test drops the next file there, so the window is widened by
# one record interval (hours) on each side.
.MET_RECORD_PAD_H <- 3

# Keep only met files whose date range overlaps [window_start, window_end],
# widened by `pad_h` hours on each side (see .MET_RECORD_PAD_H).
# Files with unrecognised names are always kept (conservative).
.filter_met_files <- function(paths, window_start, window_end, pad_h = .MET_RECORD_PAD_H) {
  lo <- window_start - pad_h * 3600
  hi <- window_end + pad_h * 3600
  keep <- vapply(paths, function(p) {
    r <- .parse_arl_date_range(p)
    if (is.null(r)) return(TRUE)
    r$end >= lo && r$start <= hi
  }, logical(1), USE.NAMES = FALSE)
  paths[keep]
}

# The GDAS1 weekly files [window_start, window_end] needs that `paths` lack;
# NULL when a file's name does not say what it covers, so the coverage cannot be
# judged. The window is widened as in .filter_met_files().
.missing_gdas1_files <- function(paths, window_start, window_end, pad_h = .MET_RECORD_PAD_H) {
  if (any(vapply(paths, function(p) is.null(.parse_arl_date_range(p)), logical(1)))) {
    return(NULL)
  }
  pad <- pad_h * 3600
  have <- basename(paths)
  need <- nm_gdas1_filenames(
    as.Date(as.POSIXct(window_start, tz = "UTC") - pad, tz = "UTC"),
    as.Date(as.POSIXct(window_end, tz = "UTC") + pad, tz = "UTC")
  )
  need[!need %in% have]
}

# Render a HYSPLIT CONTROL file (character vector of lines) for one backward
# trajectory. Internal helper -- bare function, no man page.
.traj_control_text <- function(time, lat, lon, height_m, hours_back, met_files,
                               tdump_name, top_of_model, vert_motion) {
  ts <- as.POSIXct(time, tz = "UTC")
  # start: YY MM DD HH (2-digit year), and MM only when it is not on the hour
  on_hour <- as.POSIXlt(ts, tz = "UTC")$min == 0
  lines <- c(
    format(ts, if (on_hour) "%y %m %d %H" else "%y %m %d %H %M", tz = "UTC"),
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

# normet-friendly diagnostic name -> HYSPLIT SETUP.CFG namelist flag. These
# control which along-trajectory meteorological variables hyts_std writes
# into tdump (see nm_trajectory_features()'s optional traj_rain_sum/
# blh_mean/rh_mean/pressure_mean/temp_mean columns).
.DIAG_SETUP_FLAGS <- c(
  pressure = "tm_pres",
  rainfall = "tm_rain",
  blh = "tm_mixd",
  rh = "tm_relh",
  temp = "tm_tamb"
)
.ALL_DIAGNOSTICS <- names(.DIAG_SETUP_FLAGS)

# Render a HYSPLIT SETUP.CFG &SETUP namelist toggling tdump diagnostics.
# Without this file, hyts_std falls back to its own built-in defaults
# (typically just PRESSURE) -- every diagnostic is written explicitly here
# (0 or 1) so the run is reproducible regardless of what those defaults are.
.setup_cfg_text <- function(diagnostics) {
  unknown <- setdiff(diagnostics, .ALL_DIAGNOSTICS)
  if (length(unknown) > 0) {
    stop(sprintf(
      "Unknown diagnostic(s) %s; choose from %s",
      paste(unknown, collapse = ", "), paste(.ALL_DIAGNOSTICS, collapse = ", ")
    ))
  }
  lines <- "&SETUP"
  for (name in names(.DIAG_SETUP_FLAGS)) {
    flag <- .DIAG_SETUP_FLAGS[[name]]
    lines <- c(lines, sprintf("%s = %d,", flag, as.integer(name %in% diagnostics)))
  }
  c(lines, "/")
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
#' @param times Vector of receptor (arrival) timestamps: POSIXct, or text that
#'   \code{\link{nm_parse_dates}} reads. HYSPLIT runs on UTC: a POSIXct is an
#'   instant whatever its time zone, and text without an offset is taken as UTC.
#'   A time off the hour runs at its minutes. Repeats are run once, and `NA` is
#'   skipped.
#' @param lat,lon Numeric receptor location (degrees).
#' @param met_files Character vector of ARL met file(s). They must collectively
#'   cover the whole backward window (`hours_back` before each receptor time),
#'   else the trajectory truncates where the data runs out. Each run is handed
#'   only the files that can touch its window: GDAS1 weekly files
#'   (`gdas1.<mmm><yy>.w<N>`) are selected by the dates in their name, widened by
#'   one 3-hourly record either side; any file with another name is always
#'   passed. A receptor time no file can touch is skipped, with a warning,
#'   rather than run.
#' @param hysplit_exec Path to the `hyts_std` executable
#'   (e.g. `"~/hysplit-5.4.2/exec/hyts_std"`).
#' @param height_m Numeric receptor start height (m AGL). Default 500.
#' @param hours_back Integer backward duration in hours (sign ignored). Default 72.
#' @param work_dir Directory for `CONTROL`/`tdump_*`. A temp dir is created if
#'   `NULL`; tdumps are left there for inspection/reuse. A tdump an earlier call
#'   left under the same name is removed before its run, so a failed run cannot
#'   pass the old file off as its own.
#' @param top_of_model,vert_motion HYSPLIT `CONTROL` settings (model top in m;
#'   `0` = use met vertical velocity).
#' @param diagnostics Character vector of along-trajectory meteorological
#'   variables `hyts_std` should write into `tdump` — subset of `"pressure"`,
#'   `"rainfall"`, `"blh"`, `"rh"`, `"temp"` — written into a `SETUP.CFG`
#'   alongside `CONTROL`. Default is all of them. These feed
#'   \code{\link{nm_trajectory_features}}'s optional `traj_rain_sum`/
#'   `traj_blh_mean`/`traj_rh_mean`/`traj_pressure_mean`/`traj_temp_mean`
#'   columns; pass fewer to skip the ones you don't need.
#' @param source_regions,prefix Forwarded to
#'   \code{\link{nm_build_trajectory_features}}.
#' @param timeout Per-run timeout (seconds) for `hyts_std`. Default 600.
#' @param min_hours Forwarded to \code{\link{nm_build_trajectory_features}}.
#'   Pass `min_hours = hours_back` to null trajectories that HYSPLIT ended
#'   early; either way, truncated runs are counted in a warning.
#' @param stop Optional function of no arguments, called before each run: when it
#'   returns `TRUE` no further run starts (the one in progress, if any, has
#'   finished), and the features of the runs already done are returned (an empty
#'   data.frame if none was).
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
                                     vert_motion = 0, diagnostics = .ALL_DIAGNOSTICS,
                                     source_regions = NULL,
                                     prefix = "traj_", timeout = 600,
                                     min_hours = NULL, stop = NULL) {
  # `stop` is an argument here, so errors are raised with base::stop().
  log <- nm_get_logger("io.trajectory")
  if (!is.null(stop) && !is.function(stop)) {
    base::stop("`stop` must be NULL or a function returning TRUE to stop")
  }

  exe <- normalizePath(path.expand(hysplit_exec), mustWork = FALSE)
  if (!file.exists(exe) || file.access(exe, 1L) != 0) {
    base::stop("hyts_std not found or not executable: ", exe)
  }

  if (length(met_files) == 0) base::stop("No met files given")
  mets <- vapply(met_files, function(m) normalizePath(path.expand(m), mustWork = FALSE),
                 character(1), USE.NAMES = FALSE)
  miss <- mets[!file.exists(mets)]
  if (length(miss) > 0) base::stop("Met file(s) not found: ", paste(miss, collapse = ", "))

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

  # Without SETUP.CFG, hyts_std falls back to its own built-in diagnostic
  # defaults (typically just PRESSURE); write it explicitly so the requested
  # tdump columns (rainfall/blh/rh/temp) are reproducible.
  writeLines(.setup_cfg_text(diagnostics), file.path(work, "SETUP.CFG"))

  old_wd <- setwd(work)
  on.exit(setwd(old_wd), add = TRUE)

  stamps <- .utc_seconds(times)
  stamps <- unique(stamps[!is.na(stamps)])
  stamps <- .POSIXct(stamps, tz = "UTC")
  window <- abs(hours_back) * 3600
  tdumps <- character(0)
  uncovered <- stamps[0]
  stopped <- FALSE
  every <- max(1L, length(stamps) %/% 10L)
  for (i in seq_along(stamps)) {
    if (!is.null(stop) && isTRUE(stop())) {
      stopped <- TRUE
      break
    }
    .nm_progress_report(i - 1, length(stamps))
    ts <- stamps[i]
    # Minutes in the name only off the hour, so on-the-hour names stay as they were.
    on_hour <- as.POSIXlt(ts, tz = "UTC")$min == 0
    name <- paste0("tdump_", format(ts, if (on_hour) "%Y%m%d%H" else "%Y%m%d%H%M", tz = "UTC"))
    # Hand hyts_std only the files this run can touch: a multi-year archive is
    # hundreds of weekly files, and every one would otherwise be opened by each run.
    run_mets <- .filter_met_files(mets, ts - window, ts)
    if (length(run_mets) == 0) {
      uncovered <- c(uncovered, ts)
      next
    }
    if (file.exists(name)) unlink(name) # else a run that fails would leave the last one's
    writeLines(
      .traj_control_text(ts, lat, lon, height_m, hours_back, run_mets, name,
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
      base::stop("hyts_std was killed (exit 137) - likely macOS Gatekeeper quarantine. ",
           "Clear it once with:\n  xattr -dr com.apple.quarantine ", dirname(dirname(exe)))
    }
    if (!file.exists(name)) {
      log$warn("No tdump for %s (status=%s)", format(ts),
               if (is.null(status)) "0" else as.character(status))
      next
    }
    tdumps <- c(tdumps, normalizePath(name))
    if (i %% every == 0 && i < length(stamps)) {
      log$info("hyts_std: %d of %d receptor times run", i, length(stamps))
    }
  }

  if (length(uncovered) > 0) {
    spans <- Filter(Negate(is.null), lapply(mets, .parse_arl_date_range))
    span_txt <- if (length(spans)) {
      sprintf("; the met files span %s -> %s",
              format(min(do.call(c, lapply(spans, `[[`, "start"))), "%Y-%m-%d %H:%M", tz = "UTC"),
              format(max(do.call(c, lapply(spans, `[[`, "end"))), "%Y-%m-%d %H:%M", tz = "UTC"))
    } else {
      ""
    }
    log$warn(
      "%d of %d receptor times skipped: no met file covers any of their %d-h window (e.g. %s)%s.",
      length(uncovered), length(stamps), as.integer(abs(hours_back)),
      format(uncovered[1], "%Y-%m-%d %H:%M", tz = "UTC"), span_txt
    )
  }
  if (stopped) {
    log$warn("Stopped after %d of %d receptor times.", length(tdumps), length(stamps))
    if (length(tdumps) == 0) return(data.frame())
  }
  if (length(tdumps) == 0) {
    base::stop(
      "No trajectories produced. ",
      if (length(uncovered) > 0 && length(uncovered) == length(stamps)) {
        "No met file covers the receptor times' backward windows."
      } else {
        "Check met coverage of the backward window, the CONTROL settings, and the hyts_std path."
      }
    )
  }
  log$info("Ran %d back-trajectories -> %s", length(tdumps), work)
  feats <- nm_build_trajectory_features(
    tdumps,
    source_regions = source_regions, prefix = prefix, min_hours = min_hours
  )
  age_col <- paste0(prefix, "age_max_h")
  if (is.null(min_hours) && age_col %in% colnames(feats)) {
    n_short <- sum(feats[[age_col]] < abs(hours_back) - 1e-6, na.rm = TRUE)
    if (n_short > 0) {
      log$warn(
        paste0(
          "%d of %d trajectories stopped short of hours_back=%d (met coverage or ",
          "domain edge); see %s, or pass min_hours to null them."
        ),
        n_short, nrow(feats), as.integer(abs(hours_back)), age_col
      )
    }
  }
  feats
}
