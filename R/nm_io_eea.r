# European Environment Agency (EEA) Air-Quality Download Adapter
#
# Uses the EEA Discomap download-by-URL service. Given a country, pollutant
# and year range, emits a tidy long-format data.frame ready for normet.
#
# Discovery endpoint:
#   https://fme.discomap.eea.europa.eu/fmedatastreaming/AirQualityDownload/AQData_Extract.fmw

NULL

.NM_EEA_DISCOVERY <- paste0(
  "https://fme.discomap.eea.europa.eu/fmedatastreaming/",
  "AirQualityDownload/AQData_Extract.fmw"
)

#' EEA Pollutant Codes
#'
#' Named integer vector mapping pollutant names to EEA/EIONET codes.
#' @export
nm_eea_pollutant_codes <- c(
  "PM2.5" = 6001L,
  "PM10"  = 5L,
  "NO2"   = 8L,
  "O3"    = 7L,
  "SO2"   = 1L,
  "CO"    = 10L
)

.eea_resolve_code <- function(pollutant) {
  if (is.numeric(pollutant) || is.integer(pollutant)) return(as.integer(pollutant))
  code <- nm_eea_pollutant_codes[toupper(as.character(pollutant))]
  if (is.na(code)) {
    stop("Unknown pollutant '", pollutant, "'. Known: ",
         paste(names(nm_eea_pollutant_codes), collapse = ", "))
  }
  as.integer(code)
}

#' Download Air-Quality Data from the EEA
#'
#' Queries the EEA Discomap discovery service to obtain a list of CSV URLs for
#' the requested country/pollutant/year range, downloads each CSV, and
#' concatenates them into a single tidy \code{data.frame}.
#'
#' @param country Character. ISO-2 country code (e.g. \code{"GB"}, \code{"DE"}).
#' @param pollutant Character or integer. Pollutant name (\code{"PM2.5"},
#'   \code{"PM10"}, \code{"NO2"}, \code{"O3"}, \code{"SO2"}, \code{"CO"}) or
#'   integer EIONET code.
#' @param year_from,year_to Integer. Inclusive year range.
#' @param station Character. Specific station code (e.g. \code{"GB0001A"}).
#'   If \code{NULL}, all stations in \code{country} are returned.
#' @param source Character. EEA dataflow source. One of \code{"All"},
#'   \code{"E1a"}, \code{"E2a"}. Default \code{"All"}.
#' @param output Character. Format requested from the EEA service. Default
#'   \code{"TEXT"}.
#' @param keep_columns Character vector. Restrict returned columns to this
#'   subset. Defaults to a standard tidy set.
#'
#' @return \code{data.frame} with at least columns \code{date}, \code{site},
#'   \code{country}, \code{pollutant}, \code{value}, \code{unit},
#'   \code{lat}, \code{lon}. Sorted by \code{(site, date)}.
#' @export
nm_fetch_eea_data <- function(country,
                              pollutant,
                              year_from,
                              year_to,
                              station   = NULL,
                              source    = "All",
                              output    = "TEXT",
                              keep_columns = NULL) {
  nm_require("httr2",     hint = "install.packages('httr2')")
  nm_require("data.table", hint = "install.packages('data.table')")
  log  <- nm_get_logger("io.eea")
  code <- .eea_resolve_code(pollutant)

  params <- list(
    CountryCode  = toupper(country),
    CityName     = "",
    Pollutant    = as.character(code),
    Year_from    = as.character(as.integer(year_from)),
    Year_to      = as.character(as.integer(year_to)),
    Station      = if (!is.null(station)) station else "",
    Samplingpoint = "",
    Source       = source,
    Output       = output,
    UpdateDate   = "",
    TimeCoverage = "Year",
    TimeZone     = "Europe/Brussels"
  )

  log$info("Querying EEA discovery for %s %s %d-%d", country, pollutant, year_from, year_to)

  resp <- tryCatch({
    req <- do.call(httr2::req_url_query, c(list(httr2::request(.NM_EEA_DISCOVERY)), params))
    httr2::req_perform(req)
  }, error = function(e) stop("EEA discovery request failed: ", conditionMessage(e)))

  body_text <- httr2::resp_body_string(resp)
  csv_urls  <- trimws(strsplit(body_text, "\n")[[1]])
  csv_urls  <- csv_urls[startsWith(csv_urls, "http")]

  if (length(csv_urls) == 0) {
    log$warn("EEA returned no CSV URLs for the given query.")
    return(data.frame())
  }

  pieces <- list()
  for (i in seq_along(csv_urls)) {
    url <- csv_urls[i]
    tryCatch({
      r   <- httr2::req_perform(httr2::request(url))
      raw <- httr2::resp_body_raw(r)
      df  <- data.table::fread(raw, showProgress = FALSE)
      pieces[[length(pieces) + 1]] <- df
      if ((i %% 25) == 0) log$info("EEA: %d/%d CSVs", i, length(csv_urls))
    }, error = function(e) {
      log$warn("EEA CSV fetch failed (%s): %s", url, conditionMessage(e))
    })
  }

  if (length(pieces) == 0) return(data.frame())

  raw_dt <- data.table::rbindlist(pieces, fill = TRUE)

  # Canonical column renames (EEA uses verbose headers)
  rename_map <- c(
    DatetimeBegin      = "date",
    AirQualityStation  = "site",
    Concentration      = "value",
    UnitOfMeasurement  = "unit",
    Latitude           = "lat",
    Longitude          = "lon",
    Pollutant          = "pollutant",
    CountryCode        = "country"
  )
  for (old in names(rename_map)) {
    new <- rename_map[old]
    if (old %in% colnames(raw_dt)) data.table::setnames(raw_dt, old, new)
  }

  if ("date" %in% colnames(raw_dt)) {
    raw_dt[, date := as.POSIXct(date, tz = "UTC", format = "%Y-%m-%d %H:%M:%S")]
  }

  default_keep <- c("date", "site", "country", "pollutant", "value", "unit", "lat", "lon")
  cols <- if (!is.null(keep_columns)) keep_columns else intersect(default_keep, colnames(raw_dt))
  if (length(cols) == 0) {
    data.table::setDF(raw_dt)
    return(as.data.frame(raw_dt))
  }

  out <- raw_dt[, cols, with = FALSE]
  if ("site" %in% colnames(out) && "date" %in% colnames(out)) {
    data.table::setorder(out, site, date)
  }
  data.table::setDF(out)
  as.data.frame(out)
}
