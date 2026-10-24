# Spatial Diagnostics for a Donor Pool
#
# Ported from Python normet causal/spatial.py.
# A synthetic control borrows its counterfactual from a weighted pool of
# donor units, and the weights say nothing about *where* those donors sit
# relative to the treated unit. This module is that reading: each donor's
# distance and compass bearing from the treated unit, and the pool's centroid
# offset and sector coverage.
#
# It is a diagnostic, not a fitter: nothing here changes the weights, and no
# distance or bearing is fed back into the fit.

NULL

# Compass labels for the 8-sector default, in bearing order (N at 0 degrees).
.NM_SECTOR_LABELS_8 <- c("N", "NE", "E", "SE", "S", "SW", "W", "NW")

#' Great-Circle Distance (Haversine)
#'
#' Distance in km between two sets of coordinates on the sphere of radius
#' 6371 km. Elementwise and vectorised; the operation broadcasts like the
#' Python original.
#'
#' @param lat1,lon1,lat2,lon2 Numeric vectors of coordinates in degrees.
#' @return A numeric vector of distances in km.
#' @export
nm_haversine <- function(lat1, lon1, lat2, lon2) {
  r1 <- as.numeric(lat1); r2 <- as.numeric(lat2)
  l1 <- as.numeric(lon1); l2 <- as.numeric(lon2)
  R <- 6371.0
  phi1 <- pi / 180 * r1; phi2 <- pi / 180 * r2
  dphi <- pi / 180 * (r2 - r1)
  dlambda <- pi / 180 * (l2 - l1)
  a <- sin(dphi / 2)^2 + cos(phi1) * cos(phi2) * sin(dlambda / 2)^2
  c <- 2 * atan2(sqrt(a), sqrt(1 - a))
  R * c
}

#' Initial Great-Circle Bearing
#'
#' Compass bearing in degrees from (lat1, lon1) to (lat2, lon2): 0 is true
#' north, 90 east, 180 south, 270 west, always in [0, 360). The forward
#' (initial) azimuth -- over long arcs the great circle curves away from it.
#' Elementwise and vectorised, like the Python original.
#'
#' @param lat1,lon1,lat2,lon2 Numeric vectors of coordinates in degrees.
#' @return A numeric vector of bearings in degrees, in [0, 360).
#' @export
nm_bearing <- function(lat1, lon1, lat2, lon2) {
  r1 <- pi / 180 * as.numeric(lat1); r2 <- pi / 180 * as.numeric(lat2)
  l1 <- pi / 180 * as.numeric(lon1); l2 <- pi / 180 * as.numeric(lon2)
  dlambda <- l2 - l1
  y <- sin(dlambda) * cos(r2)
  x <- cos(r1) * sin(r2) - sin(r1) * cos(r2) * cos(dlambda)
  theta <- atan2(y, x)
  ((theta + 2 * pi) %% (2 * pi)) * 180 / pi
}

.nm_sector_label <- function(bearing_deg, n_sectors) {
  if (n_sectors == 8) {
    idx <- max(1, min(as.integer(bearing_deg / (360.0 / 8.0)) + 1L, 8L))
    return(.NM_SECTOR_LABELS_8[idx])
  }
  step <- 360.0 / n_sectors
  as.character(max(0L, min(as.integer(bearing_deg / step), n_sectors - 1L)))
}

.nm_unit_coordinates <- function(df, unit_col, lat_col, lon_col) {
  if (!(lat_col %in% colnames(df)) || !(lon_col %in% colnames(df))) {
    stop(sprintf("`df` must contain the coordinate columns '%s' and '%s'.", lat_col, lon_col),
      call. = FALSE)
  }
  coords <- df[, c(unit_col, lat_col, lon_col), drop = FALSE]
  coords[[lat_col]] <- suppressWarnings(as.numeric(coords[[lat_col]]))
  coords[[lon_col]] <- suppressWarnings(as.numeric(coords[[lon_col]]))
  keep <- is.finite(coords[[lat_col]]) & is.finite(coords[[lon_col]])
  coords <- coords[keep, , drop = FALSE]
  if (nrow(coords) == 0) {
    stop(sprintf("No unit in `df` has finite '%s'/'%s' values.", lat_col, lon_col), call. = FALSE)
  }
  coords <- as.data.frame(coords, stringsAsFactors = FALSE)
  units <- coords[[unit_col]]
  lat_med <- tapply(coords[[lat_col]], units, median, na.rm = TRUE)
  lon_med <- tapply(coords[[lon_col]], units, median, na.rm = TRUE)
  out <- data.frame(
    .unit = names(lat_med),
    .lat = as.numeric(lat_med[names(lat_med)]),
    .lon = as.numeric(lon_med[names(lon_med)]),
    stringsAsFactors = FALSE
  )
  out
}

#' Donor Spatial Summary
#'
#' Each donor's distance and compass bearing from the treated unit. A donor's
#' coordinates are read as the median of its rows, so a station whose log
#' repeats the same fix (or drifts a metre) is read once.
#'
#' @param df A data.frame with \code{unit_col}, \code{lat_col} and
#'   \code{lon_col} columns (a long-format panel).
#' @param donors Character vector of donor units to place.
#' @param treated_unit The treated unit the bearings and distances are taken from.
#' @param unit_col,lat_col,lon_col Column names in \code{df}.
#' @param n_sectors Compass sectors the bearing is divided into (8 = N/NE/E/...).
#' @param weights Optional named numeric vector of donor weights; when given a
#'   \code{weight} column is added to the table.
#' @return A data.frame indexed by \code{donor} with columns \code{donor},
#'   \code{distance_km}, \code{bearing_deg}, \code{sector} (and \code{weight}
#'   when given). A donor with no coordinate gets a row of \code{NA}s and
#'   sector \code{"?"}.
#' @export
nm_donor_spatial_summary <- function(df, donors, treated_unit,
                                     unit_col = "unit", lat_col = "lat", lon_col = "lon",
                                     n_sectors = 8L, weights = NULL) {
  coords <- .nm_unit_coordinates(df, unit_col, lat_col, lon_col)
  if (!treated_unit %in% coords$.unit) {
    stop(sprintf("`treated_unit` '%s' has no coordinate in `df`.", treated_unit), call. = FALSE)
  }
  tlat <- as.numeric(coords$.lat[coords$.unit == treated_unit])
  tlon <- as.numeric(coords$.lon[coords$.unit == treated_unit])

  idx <- match(donors, coords$.unit)
  dist <- rep(NA_real_, length(donors))
  brg <- rep(NA_real_, length(donors))
  hit <- !is.na(idx)
  if (any(hit)) {
    dlat <- coords$.lat[idx[hit]]
    dlon <- coords$.lon[idx[hit]]
    dist[hit] <- as.numeric(nm_haversine(tlat, tlon, dlat, dlon))
    brg[hit] <- as.numeric(nm_bearing(tlat, tlon, dlat, dlon))
  }
  sector <- ifelse(hit, vapply(brg, .nm_sector_label, character(1), n_sectors = n_sectors), "?")

  out <- data.frame(
    donor = donors,
    distance_km = dist,
    bearing_deg = brg,
    sector = sector,
    stringsAsFactors = FALSE
  )
  if (!is.null(weights)) {
    w <- as.numeric(weights)
    names(w) <- names(weights)  # the coercion drops them; the donor names are the point
    if (is.null(names(w))) {
      out$weight <- rep(NA_real_, length(donors))
    } else {
      out$weight <- ifelse(
        out$donor %in% names(w),
        as.numeric(w[match(out$donor, names(w))]),
        NA_real_
      )
    }
  }
  rownames(out) <- out$donor
  out
}

#' Pool-Level Spatial Summary
#'
#' The pool-level reading behind a \code{nm_donor_spatial_summary} table: the
#' centroid offset and bearing from the treated unit, and the sector coverage.
#'
#' @param donor_df The output of \code{nm_donor_spatial_summary}.
#' @param n_donors The pool's intended size (\code{length(donors)}). When it
#'   exceeds the number of placed donors, the gap is reported as missing fixes.
#' @param n_sectors The sector count the table was built with.
#' @return A list with \code{centroid_offset_km}, \code{centroid_bearing_deg},
#'   \code{sector_coverage} (a named integer vector, bearing order),
#'   \code{sector_fraction}, \code{n_donors_placed} and \code{n_donors_missing}.
#' @export
nm_spatial_summary <- function(donor_df, n_donors = NULL, n_sectors = 8L) {
  placed <- donor_df[is.finite(donor_df$distance_km), , drop = FALSE]
  n_placed <- nrow(placed)
  n_missing <- if (is.null(n_donors)) 0L else max(as.integer(n_donors) - n_placed, 0L)

  if (n_placed == 0L) {
    return(list(
      centroid_offset_km = NA_real_,
      centroid_bearing_deg = NA_real_,
      sector_coverage = integer(0),
      sector_fraction = 0.0,
      n_donors_placed = 0L,
      n_donors_missing = n_missing
    ))
  }

  rad <- placed$bearing_deg * pi / 180
  d <- placed$distance_km
  east <- mean(d * sin(rad))
  north <- mean(d * cos(rad))
  centroid_km <- sqrt(east^2 + north^2)
  centroid_brg <- ((atan2(east, north) + 2 * pi) %% (2 * pi)) * 180 / pi

  counts <- table(placed$sector)
  # Sort sectors by their smallest member's bearing (the table's order), not
  # alphabetically: N must come before S, not after.
  sector_min <- tapply(placed$bearing_deg, placed$sector, min)
  sectors <- names(sector_min)[order(as.numeric(sector_min))]
  sector_fraction <- if (n_sectors > 0) length(sectors) / n_sectors else NA_real_

  list(
    centroid_offset_km = centroid_km,
    centroid_bearing_deg = centroid_brg,
    sector_coverage = setNames(as.integer(counts[sectors]), sectors),
    sector_fraction = sector_fraction,
    n_donors_placed = n_placed,
    n_donors_missing = n_missing
  )
}
