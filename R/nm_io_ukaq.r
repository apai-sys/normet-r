# UK Air-Quality Network Adapter (AURN, AQE, SAQN, WAQN, NI, LMAM)
#
# Fetches hourly measurements and station metadata from two complementary
# backends behind one interface (source = on both nm_list_ukaq_stations and
# nm_fetch_ukaq_measurements):
#
#   source="aurn"/"aqe"/"saqn"/"waqn"/"ni"/"local"   openair .RData archives,
#     whole calendar years, all six networks, published with a lag once a
#     year is complete.
#   source="aurn_live"   DEFRA's UK-AIR Sensor Observation Service (SOS REST
#     API), AURN only, near-real-time rolling window. No site_type or
#     start_date/end_date -- the SOS API has no station classification or
#     period metadata.
#
# These used to be two separate files (this one for the archives,
# nm_io_defra.r for the live API), briefly with nm_io_defra.r marked
# deprecated on the theory that its backend had gone permanently offline.
# That theory was wrong: checked again 2026-08-05, sos-ukair answers
# normally. The two were merged instead, once it was clear they are
# genuinely complementary rather than one superseding the other.
#
# The archives are the same files openair's importUKAQ() reads, so results
# are directly comparable. No extra package dependency for them: base R
# load() reads the gzip-compressed serialisations natively. aurn_live needs
# httr2, already a dependency for nm_io_eea.r/nm_io_gdas.r/nm_io_openaq.r.
#
# This mirrors normet-py's normet.io.ukaq module argument for argument, so
# the two packages stay in parity.

NULL

.safe <- function(x, default = NULL) if (is.null(x)) default else x

#' UK Air-Quality Network Endpoints
#'
#' Named list of per-network base URLs: \code{data} (the directory holding
#' \code{{CODE}_{year}.RData}) and \code{meta} (the metadata archive).
#'
#' \code{local} (LMAM) is DEFRA's locally-managed automatic monitoring
#' collection; included for completeness, but its coverage is patchier than
#' the five statutory networks.
#'
#' @export
nm_ukaq_sources <- list(
  aurn = list(
    data = "https://uk-air.defra.gov.uk/openair/R_data/",
    meta = "https://uk-air.defra.gov.uk/openair/R_data/AURN_metadata.RData"
  ),
  aqe = list(
    data = "https://airqualityengland.co.uk/assets/openair/R_data/",
    meta = "https://airqualityengland.co.uk/assets/openair/R_data/AQE_metadata.RData"
  ),
  saqn = list(
    data = "https://www.scottishairquality.scot/openair/R_data/",
    meta = "https://www.scottishairquality.scot/openair/R_data/SCOT_metadata.RData"
  ),
  waqn = list(
    data = "https://airquality.gov.wales/sites/default/files/openair/R_data/",
    meta = paste0(
      "https://airquality.gov.wales/sites/default/files/openair/R_data/",
      "WAQ_metadata.RData"
    )
  ),
  ni = list(
    data = "https://www.airqualityni.co.uk/openair/R_data/",
    meta = "https://www.airqualityni.co.uk/openair/R_data/NI_metadata.RData"
  ),
  local = list(
    data = "https://uk-air.defra.gov.uk/openair/LMAM/R_data/",
    meta = "https://uk-air.defra.gov.uk/openair/LMAM/R_data/LMAM_metadata.RData"
  )
)

# openair's metadata column names, so a caller can move between the R and
# Python workflows without relearning the schema.
.NM_UKAQ_META_RENAME <- c(
  site_id       = "code",
  site_name     = "site",
  location_type = "site_type",
  parameter     = "variable"
)

# Metadata is small, static over a session, and needed by every fetch with
# meta = TRUE. Cached per source for the session rather than refetched per
# site-year.
.nm_ukaq_meta_cache <- new.env(parent = emptyenv())

#: Sources handled by the live SOS API instead of an .RData archive. Kept
#: separate from nm_ukaq_sources because that list's values are
#: archive/metadata URL pairs, a shape aurn_live does not have.
.NM_UKAQ_LIVE_SOURCES <- "aurn_live"

.ukaq_check_source <- function(source) {
  src <- tolower(trimws(as.character(source)[1]))
  if (!src %in% names(nm_ukaq_sources) && !src %in% .NM_UKAQ_LIVE_SOURCES) {
    stop("Unknown source '", source, "'. Valid sources: ",
         paste(c(names(nm_ukaq_sources), .NM_UKAQ_LIVE_SOURCES), collapse = ", "),
         call. = FALSE)
  }
  src
}

# ---------------------------------------------------------------------------
# aurn_live: DEFRA UK-AIR Sensor Observation Service (folded in from the
# former R/nm_io_defra.r). See the module header for why this backend exists
# alongside the archives above rather than being redundant with them.
# ---------------------------------------------------------------------------

.NM_AURN_LIVE_API <- "https://uk-air.defra.gov.uk/sos-ukair/api/v1"
# The SOS API has no short site codes (only a numeric internal id and a long
# descriptive label); the official AURN codes (e.g. "MAN3" for Manchester
# Piccadilly) live in the <select id="site_id"> on this page instead.
.NM_AURN_NETWORK_INFO_URL <- "https://uk-air.defra.gov.uk/networks/network-info"

# EIONET pollutant vocabulary codes the SOS API keys phenomena on. Named to
# match the archive sources' own column names (e.g. "NOXasNO2", not DEFRA's
# "NOX") so a pollutant= filter means the same string on both sources.
.NM_AURN_LIVE_POLLUTANT_CODES <- c(
  "PM2.5"    = 6001L,
  "PM10"     = 5L,
  "NO2"      = 8L,
  "NOXasNO2" = 9L,
  "NO"       = 20L,
  "O3"       = 7L,
  "SO2"      = 1L,
  "CO"       = 10L,
  "BENZENE"  = 24L
)
# Case-insensitive lookup keyed on a lower-cased copy of the names, not
# toupper()/tolower() applied at call time: "NOXasNO2" is mixed case, so it
# does not equal its own upper- or lower-cased form and a naive
# `vec[toupper(x)]` lookup would never match it against itself.
.NM_AURN_LIVE_POLLUTANT_CODES_LOWER <- stats::setNames(
  .NM_AURN_LIVE_POLLUTANT_CODES, tolower(names(.NM_AURN_LIVE_POLLUTANT_CODES))
)

.aurn_live_resolve_code <- function(pollutant) {
  if (is.numeric(pollutant) || is.integer(pollutant)) return(as.integer(pollutant))
  code <- .NM_AURN_LIVE_POLLUTANT_CODES_LOWER[tolower(as.character(pollutant))]
  if (is.na(code)) {
    stop("Unknown pollutant '", pollutant, "'. Known: ",
         paste(names(.NM_AURN_LIVE_POLLUTANT_CODES), collapse = ", "), call. = FALSE)
  }
  as.integer(code)
}

.aurn_live_get_json <- function(url, params = list(), retries = 3L) {
  nm_require("httr2", hint = "install.packages('httr2')")
  last_err <- NULL
  for (attempt in seq_len(retries)) {
    result <- tryCatch({
      req <- httr2::request(url)
      if (length(params) > 0) req <- do.call(httr2::req_url_query, c(list(req), params))
      resp <- httr2::req_perform(req)
      httr2::resp_body_json(resp, simplifyVector = FALSE)
    }, error = function(e) {
      last_err <<- e
      if (attempt < retries) Sys.sleep(attempt)
      NULL
    })
    if (!is.null(result)) return(result)
  }
  stop("aurn_live API request failed after ", retries, " attempts: ",
       if (!is.null(last_err)) conditionMessage(last_err) else "unknown error", call. = FALSE)
}

# Official AURN short site codes, keyed by site name, e.g.
# c("Manchester Piccadilly" = "MAN3", "London Marylebone Road" = "MY1") --
# the codes used throughout UK-AIR/openair/saqgetr and by the archive
# sources' own `code` column, distinct from the SOS API's internal numeric
# station id. Scraped from the <select id="site_id"> on UK-AIR's public AURN
# network-info page (no JSON endpoint for this exists). Cached for the
# session -- the list is static enough that one re-fetch per session is
# plenty. Empty (with a warning) if the page layout changes and the codes
# can't be parsed, so callers should treat a missing/blank code as "unknown"
# rather than fail outright.
.nm_aurn_live_codes_cache <- new.env(parent = emptyenv())

#: Minimal HTML entity decoder -- covers what a UK-AIR site-name option text
#: realistically contains (apostrophes, ampersands, the odd accented
#: letter), without pulling in xml2 for the one page this package scrapes.
#: Numeric entities (decimal and hex) via intToUtf8, then the five named
#: ones HTML defines without needing a DTD lookup.
.html_unescape <- function(x) {
  decode_numeric <- function(s) {
    repeat {
      m <- regexpr("&#x?[0-9a-fA-F]+;", s, perl = TRUE)
      if (m[1] == -1) break
      ent <- regmatches(s, m)[[1]]
      is_hex <- grepl("&#x", ent, fixed = TRUE)
      digits <- sub("&#x?", "", sub(";$", "", ent))
      cp <- strtoi(digits, base = if (is_hex) 16L else 10L)
      ch <- tryCatch(intToUtf8(cp), error = function(e) ent)
      regmatches(s, m) <- ch
    }
    s
  }
  x <- vapply(x, decode_numeric, character(1), USE.NAMES = FALSE)
  named <- c("&amp;" = "&", "&lt;" = "<", "&gt;" = ">", "&quot;" = "\"", "&apos;" = "'")
  for (ent in names(named)) x <- gsub(ent, named[[ent]], x, fixed = TRUE)
  x
}

.aurn_live_site_codes <- function() {
  if (!is.null(.nm_aurn_live_codes_cache$codes)) return(.nm_aurn_live_codes_cache$codes)
  log <- nm_get_logger("io.ukaq")
  codes <- tryCatch({
    nm_require("httr2", hint = "install.packages('httr2')")
    req  <- httr2::req_url_query(httr2::request(.NM_AURN_NETWORK_INFO_URL), view = "aurn")
    resp <- httr2::req_perform(req)
    html <- httr2::resp_body_string(resp)
    m <- regmatches(html, regexpr('(?s)<select id="site_id"[^>]*>.*?</select>', html, perl = TRUE))
    if (length(m) == 0 || !nzchar(m)) {
      stop("could not find the #site_id <select> on the network-info page")
    }
    opts <- regmatches(m, gregexpr('<option value="([^"]*)"[^>]*>([^<]*)</option>', m, perl = TRUE))[[1]]
    vals  <- sub('.*value="([^"]*)".*', "\\1", opts)
    names_ <- trimws(.html_unescape(sub('.*>([^<]*)</option>$', "\\1", opts)))
    keep <- nzchar(vals)
    out <- stats::setNames(vals[keep], names_[keep])
    log$info("Fetched %d AURN site codes from UK-AIR.", length(out))
    out
  }, error = function(e) {
    log$warn("Could not fetch AURN site codes (%s) -- the 'code' column will be blank.",
             conditionMessage(e))
    character(0)
  })
  .nm_aurn_live_codes_cache$codes <- codes
  codes
}

# 'Manchester Piccadilly-Nitrogen dioxide (air)' -> 'Manchester Piccadilly'.
# The SOS API's station label is always "{site name}-{pollutant
# description}"; every aurn_live row resolves its site name through this one
# function.
.aurn_live_split_label <- function(label) {
  trimws(sub("-[^-]*$", "", as.character(label)))
}

# stats::setNames(character(0), character(0)) errors ("attempt to set an
# attribute on NULL") because names(character(0)) is NULL, not a
# zero-length character vector -- setNames() cannot tell those apart. Guard
# the empty case explicitly rather than relying on setNames() itself,
# since .aurn_live_site_codes() legitimately returns character(0) whenever
# the network-info page couldn't be scraped.
.lower_key_lookup <- function(named_vec) {
  if (length(named_vec) == 0) return(character(0))
  stats::setNames(unname(named_vec), tolower(names(named_vec)))
}

.aurn_live_list_stations <- function(pollutant, site_type, all_variables) {
  if (!is.null(site_type)) {
    stop("site_type filtering is not supported for source='aurn_live': the SOS ",
         "API has no station classification. Use an archive source instead.", call. = FALSE)
  }

  name_to_code <- .aurn_live_site_codes()
  lower_lookup <- .lower_key_lookup(name_to_code)

  if (!is.null(pollutant) || isTRUE(all_variables)) {
    wanted <- if (is.null(pollutant)) names(.NM_AURN_LIVE_POLLUTANT_CODES) else pollutant
    rows <- list()
    for (pol in wanted) {
      code <- .aurn_live_resolve_code(pol)
      ts_list <- .aurn_live_get_json(
        paste0(.NM_AURN_LIVE_API, "/timeseries"),
        list(phenomenon = as.character(code), limit = 5000L)
      )
      for (ts in ts_list) {
        props  <- .safe(ts$station$properties, list())
        coords <- .safe(.safe(ts$station$geometry, list())$coordinates, list(NULL, NULL))
        site   <- .aurn_live_split_label(.safe(props$label, .safe(ts$label, "")))
        rows[[length(rows) + 1L]] <- data.frame(
          code        = unname(lower_lookup[tolower(site)]),
          site        = site,
          site_type   = NA_character_,
          latitude    = .safe(coords[[1]], NA_real_),
          longitude   = .safe(coords[[2]], NA_real_),
          start_date  = as.Date(NA),
          end_date    = as.Date(NA),
          network     = "aurn_live",
          variable    = pol,
          stringsAsFactors = FALSE
        )
      }
    }
    out <- if (length(rows) == 0) data.frame() else do.call(rbind, rows)
    if (!isTRUE(all_variables) && nrow(out) > 0) {
      out <- out[, setdiff(names(out), "variable"), drop = FALSE]
      out <- out[!duplicated(out$site), , drop = FALSE]
    }
    rownames(out) <- NULL
    return(out)
  }

  raw  <- .aurn_live_get_json(paste0(.NM_AURN_LIVE_API, "/stations"), list(limit = 5000L))
  rows <- list()
  seen <- character(0)
  for (s in raw) {
    props  <- .safe(s$properties, list())
    coords <- .safe(.safe(s$geometry, list())$coordinates, list(NULL, NULL))
    site   <- .aurn_live_split_label(.safe(props$label, ""))
    if (site %in% seen) next
    seen <- c(seen, site)
    rows[[length(rows) + 1L]] <- data.frame(
      code       = unname(lower_lookup[tolower(site)]),
      site       = site,
      site_type  = NA_character_,
      latitude   = .safe(coords[[1]], NA_real_),
      longitude  = .safe(coords[[2]], NA_real_),
      start_date = as.Date(NA),
      end_date   = as.Date(NA),
      network    = "aurn_live",
      stringsAsFactors = FALSE
    )
  }
  out <- if (length(rows) == 0) data.frame() else do.call(rbind, rows)
  rownames(out) <- NULL
  out
}

.aurn_live_fetch_measurements <- function(codes, years, pollutant, meta, on_missing) {
  log <- nm_get_logger("io.ukaq")
  name_to_code <- .aurn_live_site_codes()
  # Inverted and lower-cased on the code side: {code: name} rather than
  # .lower_key_lookup's {lower(name): value} shape. Same empty-vector
  # footgun as that helper guards against, so guarded the same way here.
  code_to_name <- if (length(name_to_code) == 0) {
    character(0)
  } else {
    stats::setNames(names(name_to_code), tolower(unname(name_to_code)))
  }

  wanted_sites <- character(0)  # requested code -> site name
  for (code in codes) {
    # `[` not `[[`: code_to_name is a plain named atomic vector, and `[[`
    # on one of those errors (not NULL) for a missing name -- unlike a list.
    name <- unname(code_to_name[tolower(code)])
    if (is.na(name)) {
      msg <- paste0("aurn_live: unknown AURN code '", code,
                     "' (not in the network-info site list)")
      if (on_missing == "raise") stop(msg, call. = FALSE)
      if (on_missing == "warn") log$warn(msg)
      next
    }
    wanted_sites[[code]] <- name
  }

  if (length(wanted_sites) == 0) {
    log$warn("aurn_live: no requested codes could be resolved to a site name.")
    return(data.frame())
  }

  pollutants <- if (is.null(pollutant)) names(.NM_AURN_LIVE_POLLUTANT_CODES) else pollutant
  if (is.null(pollutant)) {
    log$info(paste0("aurn_live: pollutant=NULL -- fetching all %d known species sequentially ",
                     "from the live API; this is slower than an archive fetch."),
             length(pollutants))
  }

  long_rows <- list()
  for (pol in pollutants) {
    pcode <- .aurn_live_resolve_code(pol)
    ts_list <- .aurn_live_get_json(
      paste0(.NM_AURN_LIVE_API, "/timeseries"),
      list(phenomenon = as.character(pcode), limit = 5000L)
    )
    ts_by_site <- new.env(parent = emptyenv())
    for (ts in ts_list) {
      props <- .safe(ts$station$properties, list())
      label <- .safe(props$label, .safe(ts$label, ""))
      ts_by_site[[tolower(.aurn_live_split_label(label))]] <- ts$id
    }

    for (code in names(wanted_sites)) {
      name  <- wanted_sites[[code]]
      ts_id <- ts_by_site[[tolower(name)]]
      if (is.null(ts_id)) {
        msg <- paste0("aurn_live: no '", pol, "' timeseries found for ", code, " (", name, ")")
        if (on_missing == "raise") stop(msg, call. = FALSE)
        if (on_missing == "warn") log$warn(msg)
        next
      }

      for (yr in years) {
        timespan <- paste0(yr, "-01-01T00:00:00Z/", yr, "-12-31T23:59:59Z")
        data <- tryCatch(
          .aurn_live_get_json(
            paste0(.NM_AURN_LIVE_API, "/timeseries/", ts_id, "/getData"),
            list(timespan = timespan)
          ),
          error = function(e) {
            msg <- paste0("aurn_live: fetching ", pol, " for ", code, " in ", yr,
                          " failed (", conditionMessage(e), ")")
            if (on_missing == "raise") stop(msg, call. = FALSE)
            if (on_missing == "warn") log$warn(msg)
            NULL
          }
        )
        if (is.null(data)) next
        for (v in .safe(data$values, list())) {
          ts_ms <- v$timestamp
          val   <- v$value
          if (is.null(ts_ms) || is.null(val)) next
          long_rows[[length(long_rows) + 1L]] <- data.frame(
            date     = as.POSIXct(ts_ms / 1000, origin = "1970-01-01", tz = "UTC"),
            code     = code,
            site     = name,
            variable = pol,
            value    = as.numeric(val),
            stringsAsFactors = FALSE
          )
        }
      }
    }
  }

  if (length(long_rows) == 0) {
    log$warn("aurn_live: no data fetched for any of: %s",
             paste(names(wanted_sites), collapse = ", "))
    return(data.frame())
  }

  long_df <- do.call(rbind, long_rows)
  # reshape() errors on a duplicate (date, code, site, variable) combination
  # rather than picking one, unlike pandas' pivot_table(aggfunc="first") on
  # the Python side -- keep the first to match that, and because a live feed
  # occasionally does repeat a timestamp.
  long_df <- long_df[!duplicated(long_df[c("date", "code", "site", "variable")]), , drop = FALSE]
  out <- stats::reshape(
    long_df, idvar = c("date", "code", "site"), timevar = "variable",
    direction = "wide", v.names = "value"
  )
  names(out) <- sub("^value\\.", "", names(out))
  out$network <- "aurn_live"
  rownames(out) <- NULL

  if (isTRUE(meta)) {
    stations <- .aurn_live_list_stations(pollutant = NULL, site_type = NULL, all_variables = FALSE)
    cols     <- intersect(c("code", "site_type", "latitude", "longitude"), names(stations))
    out      <- dplyr::left_join(out, stations[, cols, drop = FALSE], by = "code")
  }

  out[do.call(order, out[intersect(c("code", "date"), names(out))]), ]
}

#' Read one .RData archive from a URL into a named list
#'
#' Base R \code{load()} handles the gzip-compressed serialisation directly,
#' so nothing is written to disk and no extra package is needed.
#'
#' @param url Character. Archive URL.
#' @param retries Integer. Attempts before giving up.
#' @return Named list of the objects the archive contained.
#' @noRd
.ukaq_read_rdata <- function(url, retries = 3L) {
  last_err <- NULL
  for (attempt in seq_len(retries)) {
    result <- tryCatch({
      e <- new.env(parent = emptyenv())
      con <- url(url, open = "rb")
      on.exit(try(close(con), silent = TRUE), add = TRUE)
      load(con, envir = e)
      mget(ls(e, all.names = TRUE), envir = e)
    }, error = function(err) {
      last_err <<- err
      # Only a transient failure is worth another attempt; a 404 for a
      # station-year that does not exist will fail identically every time,
      # and the caller (on_missing) decides what to do about it.
      if (attempt < retries) Sys.sleep(attempt)
      NULL
    })
    if (!is.null(result)) return(result)
  }
  stop("failed to read ", url, ": ",
       if (!is.null(last_err)) conditionMessage(last_err) else "unknown error",
       call. = FALSE)
}

#' List UK Network Monitoring Stations
#'
#' Station metadata for any of the six UK air-quality networks.
#'
#' @param source Character. One of \code{"aurn"}, \code{"aqe"},
#'   \code{"saqn"}, \code{"waqn"}, \code{"ni"}, \code{"local"} (archives,
#'   whole years) or \code{"aurn_live"} (SOS API, rolling recent window --
#'   see the module header). \code{site_type} is not supported for
#'   \code{"aurn_live"}, and its \code{site_type}/\code{start_date}/
#'   \code{end_date} are always \code{NA}: the SOS API does not carry them.
#'   Default \code{"aurn"}.
#' @param pollutant Character vector. Keep only stations measuring these
#'   species, matched case-insensitively against the metadata
#'   \code{variable} column (e.g. \code{"NOx"}, \code{c("NO2", "PM2.5")}).
#'   \code{NULL} keeps all.
#' @param site_type Character vector. Keep only these classifications, e.g.
#'   \code{"Urban Traffic"}, \code{c("Rural Background", "Suburban Background")}.
#'   Matched case-insensitively. \code{NULL} keeps all. Not supported for
#'   \code{source = "aurn_live"}.
#' @param all_variables Logical. \code{FALSE} (default) returns one row per
#'   station, dropping the per-species columns. \code{TRUE} returns the raw
#'   one-row-per-station-species metadata, which is what tells you which
#'   species a station reports and over what period.
#'
#' @return \code{data.frame} with \code{code}, \code{site}, \code{site_type},
#'   \code{latitude}, \code{longitude}, \code{start_date}, \code{end_date},
#'   a \code{network} column, and \code{variable} when
#'   \code{all_variables = TRUE}.
#'
#' @section Station codes are not globally unique:
#' Codes are unique within a network but not across networks, and several
#' AURN stations are mirrored into the devolved networks under the same code
#' and coordinates (\code{BUSH}, \code{ESK}, \code{AH}, \code{PEMB}).
#' Deduplicate on coordinates, not codes, when combining sources.
#'
#' @examples
#' \dontrun{
#' rural  <- nm_list_ukaq_stations("aurn", site_type = "Rural Background")
#' scot   <- nm_list_ukaq_stations("saqn", pollutant = "NOx")
#' recent <- nm_list_ukaq_stations("aurn_live", pollutant = "NO2")
#' }
#' @export
nm_list_ukaq_stations <- function(source = "aurn",
                                  pollutant = NULL,
                                  site_type = NULL,
                                  all_variables = FALSE) {
  src <- .ukaq_check_source(source)
  if (src %in% .NM_UKAQ_LIVE_SOURCES) {
    return(.aurn_live_list_stations(pollutant, site_type, all_variables))
  }

  if (is.null(.nm_ukaq_meta_cache[[src]])) {
    objs   <- .ukaq_read_rdata(nm_ukaq_sources[[src]]$meta)
    frames <- Filter(is.data.frame, objs)
    if (length(frames) == 0) {
      stop("no data frame found in ", src, " metadata archive", call. = FALSE)
    }
    # Every network ships a single object named "metadata"; take the largest
    # frame rather than the name, in case one is ever renamed.
    meta <- frames[[which.max(vapply(frames, nrow, integer(1)))]]
    hit  <- names(.NM_UKAQ_META_RENAME) %in% names(meta)
    names(meta)[match(names(.NM_UKAQ_META_RENAME)[hit], names(meta))] <-
      unname(.NM_UKAQ_META_RENAME[hit])
    meta$network <- src
    .nm_ukaq_meta_cache[[src]] <- meta
  }
  out <- .nm_ukaq_meta_cache[[src]]

  if (!is.null(pollutant) && "variable" %in% names(out)) {
    out <- out[tolower(as.character(out$variable)) %in% tolower(pollutant), , drop = FALSE]
  }
  if (!is.null(site_type) && "site_type" %in% names(out)) {
    out <- out[tolower(as.character(out$site_type)) %in% tolower(site_type), , drop = FALSE]
  }

  if (!isTRUE(all_variables)) {
    drop <- intersect(c("variable", "Parameter_name", "ratified_to"), names(out))
    if (length(drop)) out <- out[, setdiff(names(out), drop), drop = FALSE]
    out <- out[!duplicated(out$code), , drop = FALSE]
  }

  rownames(out) <- NULL
  out
}

#' Fetch UK Network Hourly Measurements
#'
#' Hourly measurements for one or more stations from any of the six UK
#' air-quality networks.
#'
#' @param site Character vector. Station code(s), e.g. \code{"MAN3"} or
#'   \code{c("MAN3", "GLAZ")}. Case-insensitive.
#' @param year Integer vector. Calendar year(s). The archives are one file
#'   per station-year, so this cannot be a partial range -- subset the
#'   result if you need one.
#' @param source Character. One of \code{"aurn"}, \code{"aqe"},
#'   \code{"saqn"}, \code{"waqn"}, \code{"ni"}, \code{"local"} (archives) or
#'   \code{"aurn_live"} (SOS API -- see the module header). For
#'   \code{"aurn_live"}, \code{year} still selects whole calendar year(s)
#'   (Jan 1 00:00 UTC to Dec 31 23:59:59 UTC), even though the live API
#'   itself can serve an arbitrary range; this keeps the two sources'
#'   contract identical. \code{meta = TRUE} on \code{"aurn_live"} rows only
#'   ever fills in \code{latitude}/\code{longitude} -- \code{site_type}
#'   stays \code{NA}. Default \code{"aurn"}.
#' @param pollutant Character vector. Keep only these measurement columns,
#'   alongside \code{date}, \code{code}, \code{site} and \code{network},
#'   which are always retained. Names are matched in full but
#'   case-insensitively, so NOx is \code{"NOXasNO2"}, not \code{"nox"}.
#'   \code{NULL} returns every reported species -- for \code{"aurn_live"}
#'   this means one live discovery + fetch per known pollutant,
#'   sequentially, so it is markedly slower than an archive fetch.
#' @param meta Logical. Join \code{site_type}, \code{latitude} and
#'   \code{longitude} from the network's metadata archive. Default
#'   \code{FALSE}.
#' @param on_missing Character. What to do when a station-year archive does
#'   not exist (a station that had not opened yet, or reported nothing that
#'   year), or -- for \code{"aurn_live"} -- when a requested code has no
#'   matching site name or a site/pollutant/year has no live timeseries:
#'   \code{"warn"} (default, logs and skips), \code{"raise"}, or
#'   \code{"ignore"}. The default means one gap does not abort a long fetch.
#'
#' @return \code{data.frame} in wide format, one row per hour per station:
#'   \code{date} (UTC POSIXct), \code{code}, \code{site}, one column per
#'   measured species, \code{network}, and with \code{meta = TRUE} also
#'   \code{site_type}, \code{latitude}, \code{longitude}. Sorted by
#'   \code{(code, date)}. Empty \code{data.frame} if nothing was fetched.
#'
#' @details
#' Concentrations are mass units (ug m-3), as published. NOx is reported as
#' \code{NOXasNO2}, matching openair and the AURN archive.
#'
#' \code{source = "aurn_live"} passes the SOS API's values through raw: its
#' most recent few hours are typically \code{-99} (DEFRA's own sentinel for
#' a reading not yet ratified/QC'd), not a fetch failure -- expect it at the
#' tail of almost every \code{aurn_live} pull and filter it out downstream
#' if needed. The archive sources do not have this because by the time a
#' year's \code{.RData} is published, ratification is already done.
#'
#' @examples
#' \dontrun{
#' man1 <- nm_fetch_ukaq_measurements("MAN1", 2018:2022, source = "aqe")
#' gm <- nm_fetch_ukaq_measurements(
#'   c("GLAZ", "LB"), 2020, source = "aurn",
#'   pollutant = "NOXasNO2", meta = TRUE
#' )
#' recent <- nm_fetch_ukaq_measurements(
#'   "MAN3", 2026, source = "aurn_live", pollutant = "NO2"
#' )
#' }
#' @export
nm_fetch_ukaq_measurements <- function(site,
                                       year,
                                       source = "aurn",
                                       pollutant = NULL,
                                       meta = FALSE,
                                       on_missing = c("warn", "raise", "ignore")) {
  log        <- nm_get_logger("io.ukaq")
  src        <- .ukaq_check_source(source)
  on_missing <- match.arg(on_missing)

  codes <- toupper(trimws(as.character(site)))
  years <- as.integer(year)
  if (length(codes) == 0 || length(years) == 0 || anyNA(years)) {
    stop("both `site` and `year` must be non-empty (and `year` numeric)", call. = FALSE)
  }

  if (src %in% .NM_UKAQ_LIVE_SOURCES) {
    return(.aurn_live_fetch_measurements(codes, years, pollutant, meta, on_missing))
  }

  base    <- nm_ukaq_sources[[src]]$data
  frames  <- list()
  missing <- character(0)

  for (code in codes) {
    for (yr in years) {
      key <- paste0(code, "_", yr)
      url <- paste0(base, key, ".RData")
      objs <- tryCatch(.ukaq_read_rdata(url), error = function(e) {
        missing <<- c(missing, key)
        if (on_missing == "raise") {
          stop("could not fetch ", url, ": ", conditionMessage(e), call. = FALSE)
        }
        if (on_missing == "warn") {
          log$warn("No %s data for %s in %d.", toupper(src), code, yr)
        }
        NULL
      })
      if (is.null(objs)) next

      # Each archive holds the hourly frame under "{CODE}_{year}" plus
      # pre-aggregated "_24hour_mean"/"_daily_mean" companions. Select the
      # hourly one by exact name; a "largest frame" fallback would silently
      # pick an aggregate if the naming ever changed.
      df <- objs[[key]]
      if (!is.data.frame(df)) {
        cand <- objs[!grepl("_mean$", names(objs))]
        cand <- Filter(is.data.frame, cand)
        if (length(cand) == 0) {
          missing <- c(missing, key)
          next
        }
        df <- cand[[which.max(vapply(cand, nrow, integer(1)))]]
      }
      if ("date" %in% names(df)) attr(df$date, "tzone") <- "UTC"
      frames[[length(frames) + 1L]] <- df
    }
  }

  if (length(frames) == 0) {
    log$warn("No %s data fetched for any of: %s", toupper(src), paste(codes, collapse = ", "))
    return(data.frame())
  }

  out <- dplyr::bind_rows(frames)
  out$network <- src

  if (!is.null(pollutant)) {
    keep_always <- c("date", "code", "site", "network")
    wanted      <- tolower(pollutant)
    cols        <- names(out)[names(out) %in% keep_always | tolower(names(out)) %in% wanted]
    unmatched   <- setdiff(wanted, tolower(names(out)))
    if (length(unmatched)) {
      log$warn("Requested pollutant(s) not present in %s data: %s. Available: %s",
               toupper(src), paste(unmatched, collapse = ", "),
               paste(setdiff(names(out), keep_always), collapse = ", "))
    }
    out <- out[, cols, drop = FALSE]
  }

  if (isTRUE(meta)) {
    stations <- nm_list_ukaq_stations(src)
    cols     <- intersect(c("code", "site_type", "latitude", "longitude"), names(stations))
    out      <- dplyr::left_join(out, stations[, cols, drop = FALSE], by = "code")
  }

  sort_cols <- intersect(c("code", "date"), names(out))
  if (length(sort_cols)) out <- out[do.call(order, out[sort_cols]), , drop = FALSE]

  if (length(missing)) {
    log$info("%d station-year archive(s) unavailable: %s",
             length(missing), paste(missing, collapse = ", "))
  }
  rownames(out) <- NULL
  out
}
