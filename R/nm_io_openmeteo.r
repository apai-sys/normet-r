# nm_io_openmeteo.r
# Open-Meteo historical-weather adapter (keyless ERA5-derived meteorology).
#
# Port of normet-py's `fetch_openmeteo_timeseries`: the Open-Meteo archive API
# serves hourly reanalysis data (ERA5 / ERA5-Land blend) for any coordinate
# without registration or an API key, which makes it the friction-free
# alternative to the Copernicus CDS for assembling deweathering predictors.
# Data by Open-Meteo.com (CC BY 4.0), based on Copernicus ERA5.

.NM_OPENMETEO_ARCHIVE <- "https://archive-api.open-meteo.com/v1/archive"

# Open-Meteo hourly fields fetched by default -> normet/ERA5 column mapping.
# `boundary_layer_height` was historically excluded on the assumption that
# the archive API did not backfill it (all-NaN). Verified 2026-07-19
# (normet-py side): spot checks across 2018-01, 2019-06, 2020-01, 2021-01,
# and 2022-12 all returned complete, physically plausible hourly values via
# the archive endpoint (no NaNs), so Open-Meteo has since added historical
# backfill for this field. Included here as `blh` (metres) since it is a
# well-established control on urban pollutant dilution and a useful
# deweathering predictor.
.NM_OPENMETEO_HOURLY_DEFAULT <- c(
  temperature_2m       = "t2m",
  dew_point_2m         = "d2m",
  relative_humidity_2m = "rh2m",
  surface_pressure     = "sp",
  cloud_cover          = "tcc",
  precipitation        = "tp",
  shortwave_radiation  = "ssrd",
  wind_speed_10m       = "ws",
  wind_direction_10m   = "wd",
  boundary_layer_height = "blh"
)

# Convert Open-Meteo native units to ERA5 conventions.
.om_to_era5_units <- function(df) {
  if ("t2m" %in% names(df)) df$t2m <- df$t2m + 273.15       # deg C -> K
  if ("d2m" %in% names(df)) df$d2m <- df$d2m + 273.15       # deg C -> K
  if ("sp" %in% names(df)) df$sp <- df$sp * 100             # hPa -> Pa
  if ("tcc" %in% names(df)) df$tcc <- df$tcc / 100          # % -> fraction
  if ("tp" %in% names(df)) df$tp <- df$tp / 1000            # mm -> m
  if ("ssrd" %in% names(df)) df$ssrd <- df$ssrd * 3600      # W m-2 -> J m-2 per hour
  if (all(c("ws", "wd") %in% names(df))) {
    uv <- nm_wind_to_uv(df$ws, df$wd)
    df$u10 <- uv$u
    df$v10 <- uv$v
  }
  df
}

#' Fetch Hourly ERA5-Derived Meteorology from Open-Meteo (No API Key)
#'
#' Downloads hourly reanalysis meteorology from the
#' \href{https://open-meteo.com/en/docs/historical-weather-api}{Open-Meteo
#' archive API} for one or more sites and returns a long-format data frame
#' with ERA5-style column names and units, ready to merge with AURN / OpenAQ
#' measurements (mirrors normet-py's \code{fetch_openmeteo_timeseries}).
#'
#' @param sites A \code{data.frame} with \code{site_col}, \code{lat_col} and
#'   \code{lon_col} columns, or a named list \code{list("site name" = c(lat, lon))}.
#' @param date_from,date_to Character or Date. Inclusive UTC date range.
#' @param variables Character vector of Open-Meteo hourly field names.
#'   Defaults to a standard deweathering set (temperature, dew point,
#'   humidity, pressure, cloud cover, precipitation, radiation, wind).
#'   Unknown names are passed through and keep their Open-Meteo name/units.
#' @param site_col,lat_col,lon_col Character. Column names when \code{sites}
#'   is a data frame.
#'
#' @return \code{data.frame} in long format
#'   \code{[site, date, <met columns...>, lat, lon]} with naive-UTC POSIXct
#'   timestamps, one row per site-hour, ERA5-style names and units
#'   (\code{t2m}/\code{d2m} K, \code{sp} Pa, \code{ssrd} J m-2, \code{tcc}
#'   0-1, \code{tp} m, plus \code{u10}/\code{v10} derived from wind
#'   speed/direction).
#'
#' @note The archive lags real time by a few days; requests inside that lag
#'   return NAs. Data by Open-Meteo.com (CC BY 4.0), based on Copernicus ERA5.
#'
#' @examples
#' \donttest{
#' met <- nm_fetch_openmeteo_timeseries(
#'   sites = list("London Marylebone Road" = c(51.5225, -0.1546)),
#'   date_from = "2024-01-01", date_to = "2024-01-07"
#' )
#' head(met)
#' }
#'
#' @export
nm_fetch_openmeteo_timeseries <- function(sites,
                                          date_from,
                                          date_to,
                                          variables = NULL,
                                          site_col = "site",
                                          lat_col = "lat",
                                          lon_col = "lon") {
  log <- nm_get_logger("io.openmeteo")

  fields <- if (!is.null(variables)) as.character(variables) else names(.NM_OPENMETEO_HOURLY_DEFAULT)
  start <- format(as.Date(date_from), "%Y-%m-%d")
  end <- format(as.Date(date_to), "%Y-%m-%d")

  # Coerce sites to a list of (name, lat, lon).
  if (is.data.frame(sites)) {
    missing_cols <- setdiff(c(site_col, lat_col, lon_col), colnames(sites))
    if (length(missing_cols) > 0) {
      stop("`sites` data.frame is missing columns: ", paste(missing_cols, collapse = ", "))
    }
    sites_df <- sites[!duplicated(sites[[site_col]]), ]
    site_list <- lapply(seq_len(nrow(sites_df)), function(i) {
      list(
        name = as.character(sites_df[[site_col]][i]),
        lat = as.numeric(sites_df[[lat_col]][i]),
        lon = as.numeric(sites_df[[lon_col]][i])
      )
    })
  } else if (is.list(sites)) {
    site_list <- lapply(names(sites), function(n) {
      list(name = n, lat = as.numeric(sites[[n]][1]), lon = as.numeric(sites[[n]][2]))
    })
  } else {
    stop("`sites` must be a data.frame or a named list of c(lat, lon).")
  }

  frames <- list()
  for (s in site_list) {
    log$info("Open-Meteo: fetching %s (%.4f, %.4f) %s -> %s", s$name, s$lat, s$lon, start, end)
    payload <- .aurn_get_json(
      .NM_OPENMETEO_ARCHIVE,
      params = list(
        latitude = s$lat,
        longitude = s$lon,
        start_date = start,
        end_date = end,
        hourly = paste(fields, collapse = ","),
        wind_speed_unit = "ms",
        timezone = "UTC"
      )
    )
    hourly <- payload$hourly
    if (is.null(hourly) || length(hourly$time) == 0) {
      log$warn("Open-Meteo returned no data for site %s", s$name)
      next
    }
    n <- length(hourly$time)
    cols <- list(date = as.POSIXct(unlist(hourly$time), format = "%Y-%m-%dT%H:%M", tz = "UTC"))
    for (f in fields) {
      out_name <- if (f %in% names(.NM_OPENMETEO_HOURLY_DEFAULT)) .NM_OPENMETEO_HOURLY_DEFAULT[[f]] else f
      vals <- hourly[[f]]
      cols[[out_name]] <- if (is.null(vals)) rep(NA_real_, n) else {
        vapply(vals, function(v) if (is.null(v)) NA_real_ else as.numeric(v), numeric(1))
      }
    }
    df <- as.data.frame(cols)
    df <- .om_to_era5_units(df)
    df <- cbind(site = s$name, df)
    df$lat <- s$lat
    df$lon <- s$lon
    frames[[length(frames) + 1]] <- df
  }

  if (length(frames) == 0) stop("Open-Meteo returned no data for any site.")
  out <- do.call(rbind, frames)
  out[order(out$site, out$date), , drop = FALSE]
}
