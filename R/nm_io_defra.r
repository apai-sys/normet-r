# UK AURN (Automatic Urban and Rural Network) Air-Quality Data Adapter
#
# Fetches hourly pollutant measurements from DEFRA's UK-AIR SOS REST API
# (52-North Timeseries API v1).
#
# API: https://uk-air.defra.gov.uk/sos-ukair/api/v1/

NULL

.NM_AURN_API <- "https://uk-air.defra.gov.uk/sos-ukair/api/v1"

#' AURN Pollutant Codes
#'
#' Named integer vector mapping common pollutant names to EIONET codes.
#' @export
nm_aurn_pollutant_codes <- c(
  "PM2.5"   = 6001L,
  "PM10"    = 5L,
  "NO2"     = 8L,
  "NOX"     = 9L,
  "NO"      = 20L,
  "O3"      = 7L,
  "SO2"     = 1L,
  "CO"      = 10L,
  "BENZENE" = 24L
)

.aurn_resolve_code <- function(pollutant) {
  if (is.numeric(pollutant) || is.integer(pollutant)) return(as.integer(pollutant))
  code <- nm_aurn_pollutant_codes[toupper(as.character(pollutant))]
  if (is.na(code)) {
    stop("Unknown pollutant '", pollutant, "'. Known: ",
         paste(names(nm_aurn_pollutant_codes), collapse = ", "))
  }
  as.integer(code)
}

.aurn_get_json <- function(url, params = list(), retries = 3L) {
  nm_require("httr2", hint = "install.packages('httr2')")
  last_err <- NULL
  for (attempt in seq_len(retries)) {
    result <- tryCatch({
      req <- httr2::request(url)
      if (length(params) > 0) {
        req <- do.call(httr2::req_url_query, c(list(req), params))
      }
      resp <- httr2::req_perform(req)
      httr2::resp_body_json(resp, simplifyVector = FALSE)
    }, error = function(e) {
      last_err <<- e
      if (attempt < retries) Sys.sleep(attempt)
      NULL
    })
    if (!is.null(result)) return(result)
  }
  stop("DEFRA API request failed after ", retries, " attempts: ",
       if (!is.null(last_err)) conditionMessage(last_err) else "unknown error")
}

.safe <- function(x, default = NULL) if (is.null(x)) default else x

#' List AURN Monitoring Stations
#'
#' Returns monitoring stations from the DEFRA UK-AIR network, optionally
#' filtered by pollutant.
#'
#' @param pollutant Character or integer. Pollutant name (e.g. \code{"PM2.5"},
#'   \code{"NO2"}) or EIONET code. If \code{NULL}, all stations are returned.
#' @param limit Integer. Maximum stations returned. Default 5000.
#'
#' @return \code{data.frame} with columns \code{id}, \code{label},
#'   \code{lat}, \code{lon} (and \code{timeseries_id} when pollutant is given).
#' @export
nm_list_aurn_stations <- function(pollutant = NULL, limit = 5000L) {
  if (!is.null(pollutant)) {
    code <- .aurn_resolve_code(pollutant)
    ts_list <- .aurn_get_json(
      paste0(.NM_AURN_API, "/timeseries"),
      list(phenomenon = as.character(code), limit = as.integer(limit))
    )
    rows <- lapply(ts_list, function(ts) {
      props  <- .safe(ts$station$properties, list())
      coords <- .safe(.safe(ts$station$geometry, list())$coordinates, list(NULL, NULL))
      data.frame(
        id           = .safe(props$id, NA_character_),
        label        = .safe(props$label, .safe(ts$label, "")),
        timeseries_id = .safe(ts$id, NA_character_),
        lat          = .safe(coords[[1]], NA_real_),
        lon          = .safe(coords[[2]], NA_real_),
        stringsAsFactors = FALSE
      )
    })
  } else {
    raw  <- .aurn_get_json(paste0(.NM_AURN_API, "/stations"), list(limit = as.integer(limit)))
    rows <- lapply(raw, function(s) {
      props  <- .safe(s$properties, list())
      coords <- .safe(.safe(s$geometry, list())$coordinates, list(NULL, NULL))
      data.frame(
        id    = .safe(props$id, NA_character_),
        label = .safe(props$label, ""),
        lat   = .safe(coords[[1]], NA_real_),
        lon   = .safe(coords[[2]], NA_real_),
        stringsAsFactors = FALSE
      )
    })
  }
  if (length(rows) == 0) return(data.frame())
  do.call(rbind, rows)
}

#' Fetch AURN Hourly Measurements
#'
#' Downloads hourly measurements from the DEFRA UK-AIR SOS API and returns
#' a long-format \code{data.frame} compatible with \code{normet} pipelines.
#'
#' @param station Integer, character, or vector. Station ID(s) or label
#'   substring(s). If \code{NULL}, fetches all stations measuring the pollutant
#'   (potentially large).
#' @param pollutant Character. Pollutant name. Default \code{"PM2.5"}.
#' @param date_from,date_to Character or Date. Inclusive UTC date range.
#' @param station_label Character. Optional label substring filter (case-insensitive).
#'   Overrides \code{station} when given.
#'
#' @return \code{data.frame} with columns \code{date} (UTC POSIXct), \code{site},
#'   \code{station_id}, \code{pollutant}, \code{value}, \code{unit},
#'   \code{lat}, \code{lon}. Sorted by \code{(site, date)}.
#' @export
nm_fetch_aurn_measurements <- function(station = NULL,
                                       pollutant = "PM2.5",
                                       date_from,
                                       date_to,
                                       station_label = NULL) {
  log  <- nm_get_logger("io.defra")
  code <- .aurn_resolve_code(pollutant)

  df_from <- as.POSIXct(date_from, tz = "UTC")
  df_to   <- as.POSIXct(date_to,   tz = "UTC")
  timespan <- paste0(
    format(df_from, "%Y-%m-%dT%H:%M:%SZ"), "/",
    format(df_to,   "%Y-%m-%dT%H:%M:%SZ")
  )

  all_ts <- .aurn_get_json(
    paste0(.NM_AURN_API, "/timeseries"),
    list(phenomenon = as.character(code), limit = 5000L)
  )

  # --- Resolve which timeseries IDs to fetch ---
  ids_to_fetch <- character(0)
  if (!is.null(station_label)) {
    pattern <- tolower(station_label)
    for (ts in all_ts) {
      props <- .safe(ts$station$properties, list())
      label <- tolower(.safe(props$label, .safe(ts$label, "")))
      if (grepl(pattern, label, fixed = TRUE)) ids_to_fetch <- c(ids_to_fetch, ts$id)
    }
  } else if (!is.null(station)) {
    station_ids <- as.character(unlist(station))
    for (ts in all_ts) {
      props    <- .safe(ts$station$properties, list())
      ts_id    <- as.character(.safe(props$id, ""))
      ts_label <- .safe(props$label, "")
      if (ts_id %in% station_ids || any(sapply(station_ids, grepl, x = ts_label))) {
        ids_to_fetch <- c(ids_to_fetch, ts$id)
      }
    }
  } else {
    ids_to_fetch <- vapply(all_ts, function(ts) ts$id, character(1))
  }

  if (length(ids_to_fetch) == 0) {
    log$warn("No matching timeseries found for pollutant %s", pollutant)
    return(data.frame())
  }

  # Lookup table: timeseries_id → metadata
  ts_lookup <- list()
  for (ts in all_ts) {
    tid    <- ts$id
    props  <- .safe(ts$station$properties, list())
    coords <- .safe(.safe(ts$station$geometry, list())$coordinates, list(NULL, NULL))
    ts_lookup[[tid]] <- list(
      label      = .safe(props$label, .safe(ts$label, tid)),
      station_id = .safe(props$id, tid),
      lat        = .safe(coords[[1]], NA_real_),
      lon        = .safe(coords[[2]], NA_real_)
    )
  }

  rows <- list()
  for (i in seq_along(ids_to_fetch)) {
    ts_id <- ids_to_fetch[i]
    data  <- tryCatch(
      .aurn_get_json(
        paste0(.NM_AURN_API, "/timeseries/", ts_id, "/getData"),
        list(timespan = timespan)
      ),
      error = function(e) {
        log$warn("Failed to fetch timeseries %s: %s", ts_id, conditionMessage(e))
        NULL
      }
    )
    if (is.null(data)) next

    vals <- .safe(data$values, list())
    meta <- .safe(ts_lookup[[ts_id]], list())

    for (v in vals) {
      ts_ms <- v$timestamp
      val   <- v$value
      if (is.null(ts_ms) || is.null(val)) next
      rows[[length(rows) + 1]] <- list(
        date       = as.POSIXct(ts_ms / 1000, origin = "1970-01-01", tz = "UTC"),
        site       = .safe(meta$label, ts_id),
        station_id = .safe(meta$station_id, ts_id),
        pollutant  = pollutant,
        value      = as.numeric(val),
        unit       = "ug.m-3",
        lat        = .safe(meta$lat, NA_real_),
        lon        = .safe(meta$lon, NA_real_)
      )
    }

    if ((i %% 50) == 0) log$info("Fetched %d/%d timeseries for %s", i, length(ids_to_fetch), pollutant)
  }

  if (length(rows) == 0) return(data.frame())

  out <- do.call(rbind, lapply(rows, as.data.frame, stringsAsFactors = FALSE))
  out[order(out$site, out$date), ]
}
