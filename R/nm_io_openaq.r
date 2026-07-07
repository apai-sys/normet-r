# OpenAQ Air-Quality Data Adapter
#
# Pulls measurements from the OpenAQ v3 API into long-format data.frames
# ready for normet pipelines. Requires a free API key from
# https://explore.openaq.org/register, supplied via OPENAQ_API_KEY env var
# or the api_key= argument.
#
# API docs: https://docs.openaq.org/

NULL

.NM_OPENAQ_BASE <- "https://api.openaq.org/v3"

.openaq_resolve_key <- function(api_key) {
  key <- if (!is.null(api_key)) api_key else Sys.getenv("OPENAQ_API_KEY")
  if (nchar(key) == 0) {
    stop(
      "OpenAQ requires an API key. Pass `api_key=` or set OPENAQ_API_KEY. ",
      "Register a free key at https://explore.openaq.org/register."
    )
  }
  key
}

.openaq_get <- function(url, params = list(), headers_extra = list(),
                        retries = 3L) {
  nm_require("httr2", hint = "install.packages('httr2')")
  last_err <- NULL
  for (attempt in seq_len(retries)) {
    result <- tryCatch({
      req <- httr2::request(url)
      if (length(params) > 0) req <- do.call(httr2::req_url_query, c(list(req), params))
      for (nm in names(headers_extra)) {
        req <- httr2::req_headers(req, !!nm := headers_extra[[nm]])
      }
      resp <- httr2::req_perform(req)
      httr2::resp_body_json(resp, simplifyVector = FALSE)
    }, error = function(e) {
      last_err <<- e
      NULL
    })
    if (!is.null(result)) return(result)
    wait <- 2^(attempt - 1)
    Sys.sleep(wait)
  }
  stop("OpenAQ request failed after ", retries, " attempts: ",
       if (!is.null(last_err)) conditionMessage(last_err) else "unknown error")
}

.safe_val <- function(x, default = NULL) if (is.null(x)) default else x

#' List OpenAQ Monitoring Locations
#'
#' Returns monitoring locations matching the given filters.
#'
#' @param country Character. ISO-3166 alpha-2 code (e.g. \code{"GB"}, \code{"US"}).
#' @param city Character. City name; case-insensitive substring match.
#' @param bbox Numeric vector \code{c(min_lon, min_lat, max_lon, max_lat)}.
#'   Geographic bounding box.
#' @param parameter Character. Pollutant slug (e.g. \code{"pm25"}, \code{"no2"}).
#' @param limit Integer. Maximum locations returned. Default 1000.
#' @param api_key Character. Overrides \code{OPENAQ_API_KEY} env var.
#'
#' @return \code{data.frame} with columns \code{id}, \code{name}, \code{city},
#'   \code{country}, \code{lat}, \code{lon}, \code{parameters},
#'   \code{sensors}, \code{last_updated}. \code{sensors} is a list-column;
#'   each element is a \code{data.frame} with columns \code{id}, \code{name},
#'   \code{parameter_id}, \code{parameter_name}, \code{parameter_units} for
#'   the sensors at that location.
#' @export
nm_openaq_locations <- function(country   = NULL,
                                city      = NULL,
                                bbox      = NULL,
                                parameter = NULL,
                                limit     = 1000L,
                                api_key   = NULL) {
  key     <- .openaq_resolve_key(api_key)
  headers <- list("X-API-Key" = key)
  params  <- list(limit = as.integer(limit))
  if (!is.null(country))   params[["iso"]]           <- country
  if (!is.null(city))      params[["city"]]           <- city
  if (!is.null(parameter)) params[["parameters_id"]] <- parameter
  if (!is.null(bbox))      params[["bbox"]]           <- paste(sprintf("%.4f", bbox), collapse = ",")

  data <- .openaq_get(paste0(.NM_OPENAQ_BASE, "/locations"), params, headers)
  results <- .safe_val(data$results, list())
  if (length(results) == 0) return(data.frame())

  rows <- lapply(results, function(r) {
    coords  <- .safe_val(r$coordinates, list())
    sensors <- .safe_val(r$sensors, list())
    params_names <- vapply(sensors, function(s) {
      .safe_val(.safe_val(s$parameter, list())$name, NA_character_)
    }, character(1))
    sensors_parsed <- lapply(sensors, function(s) {
      param_info <- .safe_val(s$parameter, list())
      data.frame(
        id              = .safe_val(s$id, NA_integer_),
        name            = .safe_val(s$name, NA_character_),
        parameter_id    = .safe_val(param_info$id, NA_integer_),
        parameter_name  = .safe_val(param_info$name, NA_character_),
        parameter_units = .safe_val(param_info$units, NA_character_),
        stringsAsFactors = FALSE
      )
    })
    sensors_df <- if (length(sensors_parsed) > 0) {
      do.call(rbind, sensors_parsed)
    } else {
      data.frame(id = integer(0), name = character(0), parameter_id = integer(0),
        parameter_name = character(0), parameter_units = character(0),
        stringsAsFactors = FALSE)
    }
    data.frame(
      id           = .safe_val(r$id, NA_integer_),
      name         = .safe_val(r$name, NA_character_),
      city         = if (is.list(r$locality)) NA_character_ else .safe_val(r$locality, NA_character_),
      country      = .safe_val(.safe_val(r$country, list())$code, NA_character_),
      lat          = .safe_val(coords$latitude,  NA_real_),
      lon          = .safe_val(coords$longitude, NA_real_),
      parameters   = I(list(params_names[!is.na(params_names)])),
      sensors      = I(list(sensors_df)),
      last_updated = .safe_val(.safe_val(r$datetimeLast, list())$utc, NA_character_),
      stringsAsFactors = FALSE
    )
  })
  do.call(rbind, rows)
}

#' Fetch Measurements from OpenAQ v3
#'
#' Downloads hourly measurements for one or more location IDs and a given
#' pollutant. Paginates automatically.
#'
#' @param location_id Integer or integer vector. OpenAQ location identifier(s).
#'   Use \code{\link{nm_openaq_locations}} to discover IDs.
#' @param parameter Character. Pollutant slug (e.g. \code{"pm25"}, \code{"no2"},
#'   \code{"o3"}).
#' @param date_from,date_to Character or POSIXct. Inclusive UTC date range.
#' @param page_limit Integer. Server page size; function paginates automatically.
#'   Default 1000.
#' @param api_key Character. Overrides \code{OPENAQ_API_KEY} env var.
#'
#' @return \code{data.frame} with columns \code{date} (UTC POSIXct), \code{site}
#'   (location id), \code{parameter}, \code{value}, \code{unit}, \code{lat},
#'   \code{lon}. Sorted by \code{(site, date)}.
#' @export
nm_fetch_openaq_measurements <- function(location_id,
                                         parameter,
                                         date_from,
                                         date_to,
                                         page_limit = 1000L,
                                         api_key    = NULL) {
  log     <- nm_get_logger("io.openaq")
  key     <- .openaq_resolve_key(api_key)
  headers <- list("X-API-Key" = key)
  locs    <- as.integer(unlist(location_id))

  df_from <- format(as.POSIXct(date_from, tz = "UTC"), "%Y-%m-%dT%H:%M:%SZ")
  df_to   <- format(as.POSIXct(date_to,   tz = "UTC"), "%Y-%m-%dT%H:%M:%SZ")

  all_rows <- list()

  for (loc in locs) {
    page <- 1L
    repeat {
      params <- list(
        datetime_from  = df_from,
        datetime_to    = df_to,
        parameters_id  = parameter,
        limit          = as.integer(page_limit),
        page           = page
      )
      data  <- .openaq_get(
        paste0(.NM_OPENAQ_BASE, "/locations/", loc, "/measurements"),
        params, headers
      )
      chunk <- .safe_val(data$results, list())
      if (length(chunk) == 0) break

      for (r in chunk) {
        period <- .safe_val(r$period, list())
        start  <- .safe_val(.safe_val(period$datetimeFrom, list())$utc, NA_character_)
        coords <- .safe_val(r$coordinates, list())
        param_info <- .safe_val(r$parameter, list())
        all_rows[[length(all_rows) + 1]] <- list(
          date      = start,
          site      = loc,
          parameter = .safe_val(param_info$name, parameter),
          value     = .safe_val(r$value, NA_real_),
          unit      = .safe_val(param_info$units, NA_character_),
          lat       = .safe_val(coords$latitude,  NA_real_),
          lon       = .safe_val(coords$longitude, NA_real_)
        )
      }

      if (length(chunk) < page_limit) break
      page <- page + 1L
    }
  }

  if (length(all_rows) == 0) return(data.frame())

  out <- do.call(rbind, lapply(all_rows, as.data.frame, stringsAsFactors = FALSE))
  out$date <- as.POSIXct(out$date, tz = "UTC", format = "%Y-%m-%dT%H:%M:%SZ")
  out[order(out$site, out$date), ]
}

#' List Sensors at an OpenAQ Location
#'
#' @param location_id Integer. OpenAQ location identifier.
#' @param limit Integer. Maximum sensors returned. Default 100.
#' @param api_key Character. Overrides \code{OPENAQ_API_KEY} env var.
#'
#' @return \code{data.frame} with columns \code{id}, \code{name},
#'   \code{parameter_id}, \code{parameter_name}, \code{parameter_units},
#'   \code{parameter_display_name}, \code{datetime_first}, \code{datetime_last}.
#' @export
nm_openaq_sensors <- function(location_id, limit = 100L, api_key = NULL) {
  key     <- .openaq_resolve_key(api_key)
  headers <- list("X-API-Key" = key)
  params  <- list(limit = as.integer(limit))

  data    <- .openaq_get(
    paste0(.NM_OPENAQ_BASE, "/locations/", as.integer(location_id), "/sensors"),
    params, headers
  )
  results <- .safe_val(data$results, list())
  if (length(results) == 0) return(data.frame())

  rows <- lapply(results, function(r) {
    param <- .safe_val(r$parameter, list())
    data.frame(
      id                    = .safe_val(r$id, NA_integer_),
      name                  = .safe_val(r$name, NA_character_),
      parameter_id          = .safe_val(param$id, NA_integer_),
      parameter_name        = .safe_val(param$name, NA_character_),
      parameter_units       = .safe_val(param$units, NA_character_),
      parameter_display_name = .safe_val(param$displayName, NA_character_),
      datetime_first        = .safe_val(.safe_val(r$datetimeFirst, list())$utc, NA_character_),
      datetime_last         = .safe_val(.safe_val(r$datetimeLast,  list())$utc, NA_character_),
      stringsAsFactors = FALSE
    )
  })
  do.call(rbind, rows)
}
