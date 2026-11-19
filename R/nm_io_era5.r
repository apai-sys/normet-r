# ERA5 Reanalysis Meteorological Adapter via Climate Data Store (CDS)
#
# Ported from Python normet io/era5.py
# Wraps ecmwfr (CDS API R wrapper) to download pre-interpolated single-point
# ERA5 time-series CSVs from the reanalysis-era5-single-levels-timeseries dataset.

NULL

#' Default Surface variables for Air-Quality Modelling (CDS names)
#' @export
nm_era5_aq_variables_default <- c(
  "10m_u_component_of_wind",
  "10m_v_component_of_wind",
  "2m_temperature",
  "2m_dewpoint_temperature",
  "surface_pressure",
  "boundary_layer_height",
  "total_cloud_cover",
  "total_precipitation",
  "surface_solar_radiation_downwards"
)

#' Coerce Site Coordinates Input
#'
#' Internal helper to standardise site inputs to data.frame.
#' @noRd
.era5_coerce_sites <- function(sites, site_col = "site", lat_col = "lat", lon_col = "lon") {
  if (is.data.frame(sites)) {
    missing_cols <- setdiff(c(site_col, lat_col, lon_col), colnames(sites))
    if (length(missing_cols) > 0) {
      stop("sites data.frame missing columns: ", paste(missing_cols, collapse = ", "))
    }
    df <- data.frame(
      site = as.character(sites[[site_col]]),
      lat = as.numeric(sites[[lat_col]]),
      lon = as.numeric(sites[[lon_col]]),
      stringsAsFactors = FALSE
    )
    return(df)
  } else if (is.list(sites) || is.vector(sites)) {
    # Named list/vector: c("siteA" = c(lat, lon)) or list("siteA" = c(lat, lon))
    rows <- lapply(names(sites), function(name) {
      coords <- sites[[name]]
      data.frame(site = name, lat = coords[1], lon = coords[2], stringsAsFactors = FALSE)
    })
    return(do.call(rbind, rows))
  } else {
    stop("Unsupported sites type: must be a data.frame or a named list/vector.")
  }
}

#' Direct point ERA5 timeseries fetching via CDS (CSV Endpoint)
#'
#' Directly query the Copernicus CDS API for single-point meteorological timeseries,
#' bypassing gridded NetCDF dependencies by downloading pre-interpolated CSVs directly.
#'
#' Uses the \code{reanalysis-era5-single-levels-timeseries} dataset on the
#' Climate Data Store (\url{https://cds.climate.copernicus.eu}). The request
#' schema for this dataset differs from the classic gridded ERA5 request: the
#' point location is a \code{location} object (not top-level
#' \code{latitude}/\code{longitude}), the date range is a single
#' \code{"from/to"} string, and the output format key is \code{data_format}
#' (not \code{format}). The CDS API wraps the result CSV in a zip archive;
#' this function extracts it transparently. The response already uses short
#' variable names (\code{t2m}, \code{u10}, \code{v10}, ...) — no renaming
#' needed.
#'
#' @param sites Data.frame or Named list/vector. Coordinates of sites.
#' @param date_from Character or Date. Start date.
#' @param date_to Character or Date. End date.
#' @param variables Character vector. CDS API variable names. Defaults to \code{nm_era5_aq_variables_default}.
#' @param cache_dir Character. Directory to cache point CSV files. If provided, reuses existing CSVs.
#' @param site_col Character. Site identifier column name. Default `"site"`.
#' @param lat_col Character. Latitude column name. Default `"lat"`.
#' @param lon_col Character. Longitude column name. Default `"lon"`.
#' @param date_col Character. Output date column name. Default `"date"`.
#' @param user Character. ECMWF/CDS keyring profile name set via
#'   \code{\link[ecmwfr]{wf_set_key}} (default \code{"ecmwfr"}). Use a
#'   different profile if you have separate Atmosphere Data Store (ADS) and
#'   Climate Data Store (CDS) credentials stored — ADS does not serve ERA5.
#'
#' @return A data.frame with columns \code{[site, date, lat, lon, <variables...>]}.
#' @export
nm_fetch_era5_timeseries <- function(sites,
                                     date_from,
                                     date_to,
                                     variables = NULL,
                                     cache_dir = NULL,
                                     site_col = "site",
                                     lat_col = "lat",
                                     lon_col = "lon",
                                     date_col = "date",
                                     user = "ecmwfr") {
  nm_require("ecmwfr", hint = "install.packages('ecmwfr')")
  log <- nm_get_logger("io.era5")

  sites_df <- .era5_coerce_sites(sites, site_col = site_col, lat_col = lat_col, lon_col = lon_col)

  d_from <- format(as.Date(date_from), "%Y-%m-%d")
  d_to <- format(as.Date(date_to), "%Y-%m-%d")
  date_range <- paste0(d_from, "/", d_to)

  cds_vars <- if (is.null(variables)) nm_era5_aq_variables_default else variables

  results <- list()

  if (!is.null(cache_dir)) {
    dir.create(cache_dir, recursive = TRUE, showWarnings = FALSE)
  }

  for (i in seq_len(nrow(sites_df))) {
    s_name <- sites_df$site[i]
    s_lat <- sites_df$lat[i]
    s_lon <- sites_df$lon[i]

    site_target <- NULL
    if (!is.null(cache_dir)) {
      filename <- sprintf("era5_timeseries_%s_%s_%s.csv", s_name, d_from, d_to)
      site_target <- file.path(cache_dir, filename)
    }

    if (!is.null(site_target) && file.exists(site_target)) {
      log$info("Reusing cached ERA5 timeseries CSV for site %s: %s", s_name, site_target)
      df_site <- data.table::fread(site_target)
    } else {
      request <- list(
        dataset_short_name = "reanalysis-era5-single-levels-timeseries",
        variable = as.list(cds_vars),
        location = list(longitude = s_lon, latitude = s_lat),
        date = list(date_range),
        data_format = "csv",
        target = "era5.zip"
      )

      log$info("Submitting CDS point timeseries request for site %s (lat=%f, lon=%f)", s_name, s_lat, s_lon)

      tmp_dir <- tempfile("era5_")
      dir.create(tmp_dir)
      on.exit(unlink(tmp_dir, recursive = TRUE), add = TRUE)

      result_path <- ecmwfr::wf_request(
        request = request, user = user, transfer = TRUE, path = tmp_dir, verbose = FALSE
      )

      # The CDS API wraps the timeseries CSV in a zip archive.
      if (grepl("\\.zip$", result_path, ignore.case = TRUE) || any(grepl("PK", readBin(result_path, "raw", 2)))) {
        extracted <- utils::unzip(result_path, exdir = tmp_dir)
        csv_member <- extracted[grepl("\\.csv$", extracted, ignore.case = TRUE)][1]
        if (is.na(csv_member)) stop("CDS response zip has no CSV member.")
        df_site <- data.table::fread(csv_member)
      } else {
        df_site <- data.table::fread(result_path)
      }

      if (!is.null(site_target)) {
        data.table::fwrite(df_site, site_target)
      }
    }

    # Standardise time/coordinate column names; variable columns already use
    # short names (t2m, u10, v10, ...) straight from the API.
    colnames(df_site) <- tolower(colnames(df_site))
    if ("valid_time" %in% colnames(df_site)) {
      data.table::setnames(df_site, "valid_time", date_col)
    } else if ("time" %in% colnames(df_site)) {
      data.table::setnames(df_site, "time", date_col)
    } else if ("timestamp" %in% colnames(df_site)) {
      data.table::setnames(df_site, "timestamp", date_col)
    }

    if ("latitude" %in% colnames(df_site)) {
      data.table::setnames(df_site, "latitude", lat_col)
    }
    if ("longitude" %in% colnames(df_site)) {
      data.table::setnames(df_site, "longitude", lon_col)
    }

    df_site[[site_col]] <- s_name
    if (!lat_col %in% colnames(df_site)) df_site[[lat_col]] <- s_lat
    if (!lon_col %in% colnames(df_site)) df_site[[lon_col]] <- s_lon

    df_site[[date_col]] <- as.POSIXct(df_site[[date_col]], tz = "UTC")

    meta_cols <- c(site_col, date_col, lat_col, lon_col)
    cols_to_keep <- c(meta_cols, setdiff(colnames(df_site), meta_cols))
    df_site <- df_site[, cols_to_keep, with = FALSE]
    results[[length(results) + 1]] <- df_site
  }

  if (length(results) == 0) {
    return(data.frame())
  }

  df_all <- data.table::rbindlist(results, fill = TRUE)
  sort_cols <- intersect(c(site_col, date_col), colnames(df_all))
  if (length(sort_cols) > 0) {
    data.table::setorderv(df_all, sort_cols)
  }

  data.table::setDF(df_all)
  return(df_all)
}
