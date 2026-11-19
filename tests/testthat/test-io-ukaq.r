# UK air-quality network adapter -- offline tests.
#
# Every test stubs .ukaq_read_rdata, so nothing here touches the network.
# That is the module's only I/O boundary: everything else is frame assembly,
# filtering and joining, which is what these exercise.

.hourly <- function(code, year, n = 24L) {
  start <- as.POSIXct(paste0(year, "-01-01"), tz = "UTC")
  data.frame(
    date     = start + (seq_len(n) - 1L) * 3600,
    NO       = seq(1, 2, length.out = n),
    NO2      = seq(10, 20, length.out = n),
    NOXasNO2 = seq(11, 22, length.out = n),
    PM10     = seq(5, 6, length.out = n),
    site     = rep(paste("Site", code), n),
    code     = rep(code, n),
    stringsAsFactors = FALSE
  )
}

.meta <- data.frame(
  site_id        = c("AAA", "AAA", "BBB", "CCC"),
  site_name      = c("Site AAA", "Site AAA", "Site BBB", "Site CCC"),
  location_type  = c("Urban Traffic", "Urban Traffic", "Rural Background", "Urban Background"),
  latitude       = c(53, 53, 54, 55),
  longitude      = c(-2, -2, -3, -1),
  parameter      = c("NOx", "PM10", "NOx", "NOx"),
  Parameter_name = c("Nitrogen oxides", "PM10", "Nitrogen oxides", "Nitrogen oxides"),
  start_date     = rep("2010-01-01", 4),
  end_date       = rep(NA_character_, 4),
  ratified_to    = rep("2023-12-31", 4),
  stringsAsFactors = FALSE
)

# Route .ukaq_read_rdata to fixtures; unknown archives error, as a 404 does.
.stub <- function(present = "AAA_2020") {
  function(url, retries = 3L) {
    if (grepl("_metadata\\.RData$", url)) return(list(metadata = .meta))
    key <- sub("\\.RData$", "", basename(url))
    if (!key %in% present) stop("404 for ", key)
    parts <- strsplit(key, "_", fixed = TRUE)[[1]]
    code  <- parts[1]
    year  <- as.integer(parts[2])
    out <- list(.hourly(code, year), .hourly(code, year, 1L), .hourly(code, year, 1L))
    names(out) <- c(key, paste0(key, "_daily_mean"), paste0(key, "_24hour_mean"))
    out
  }
}

# The metadata cache is package-level; stop it leaking between tests.
.clear_cache <- function() {
  rm(list = ls(.nm_ukaq_meta_cache, all.names = TRUE), envir = .nm_ukaq_meta_cache)
}

# ---- constants and helpers ----

test_that("source table is well formed", {
  expect_setequal(names(nm_ukaq_sources), c("aurn", "aqe", "saqn", "waqn", "ni", "local"))
  for (s in names(nm_ukaq_sources)) {
    expect_true(startsWith(nm_ukaq_sources[[s]]$data, "https://"), info = s)
    expect_true(endsWith(nm_ukaq_sources[[s]]$data, "/"), info = s)
    expect_true(endsWith(nm_ukaq_sources[[s]]$meta, "_metadata.RData"), info = s)
  }
})

test_that("source name is normalised and validated", {
  expect_equal(.ukaq_check_source("AURN"), "aurn")
  expect_equal(.ukaq_check_source("  saqn "), "saqn")
  expect_error(.ukaq_check_source("kcl"), "Unknown source")
})

# ---- fetch ----

test_that("a single site-year is fetched and tagged", {
  .clear_cache()
  local_mocked_bindings(.ukaq_read_rdata = .stub())
  d <- nm_fetch_ukaq_measurements("AAA", 2020, source = "aqe")
  expect_equal(nrow(d), 24)
  expect_equal(format(d$date[1], "%Z"), "UTC")
  expect_true(all(d$network == "aqe"))
  expect_true(all(c("NO", "NO2", "NOXasNO2", "PM10", "code", "site") %in% names(d)))
})

test_that("site codes are upper-cased", {
  .clear_cache()
  local_mocked_bindings(.ukaq_read_rdata = .stub())
  expect_equal(nrow(nm_fetch_ukaq_measurements("aaa", 2020)), 24)
})

test_that("aggregate companion frames are not mistaken for the hourly one", {
  .clear_cache()
  local_mocked_bindings(.ukaq_read_rdata = .stub())
  expect_equal(nrow(nm_fetch_ukaq_measurements("AAA", 2020)), 24)
})

test_that("multiple sites and years are concatenated and sorted", {
  .clear_cache()
  local_mocked_bindings(.ukaq_read_rdata = .stub(c("AAA_2020", "AAA_2021", "BBB_2020")))
  d <- nm_fetch_ukaq_measurements(c("AAA", "BBB"), c(2020, 2021), on_missing = "ignore")
  expect_equal(nrow(d), 72)
  expect_setequal(unique(d$code), c("AAA", "BBB"))
  expect_false(is.unsorted(d$code))
})

test_that("pollutant filter keeps the identity columns", {
  .clear_cache()
  local_mocked_bindings(.ukaq_read_rdata = .stub())
  d <- nm_fetch_ukaq_measurements("AAA", 2020, pollutant = "noxasno2")
  expect_setequal(names(d), c("date", "code", "site", "network", "NOXasNO2"))
})

test_that("pollutant filter accepts a vector and drops the rest", {
  .clear_cache()
  local_mocked_bindings(.ukaq_read_rdata = .stub())
  d <- nm_fetch_ukaq_measurements("AAA", 2020, pollutant = c("NO2", "PM10"))
  expect_true(all(c("NO2", "PM10") %in% names(d)))
  expect_false("NOXasNO2" %in% names(d))
})

test_that("an unavailable species is dropped, not fatal", {
  .clear_cache()
  local_mocked_bindings(.ukaq_read_rdata = .stub())
  d <- nm_fetch_ukaq_measurements("AAA", 2020, pollutant = c("NO2", "SO2"))
  expect_true("NO2" %in% names(d))
  expect_false("SO2" %in% names(d))
})

test_that("a missing archive is skipped by default", {
  .clear_cache()
  local_mocked_bindings(.ukaq_read_rdata = .stub("AAA_2020"))
  d <- nm_fetch_ukaq_measurements("AAA", c(2020, 2021))
  expect_equal(nrow(d), 24)
})

test_that("a missing archive can be made fatal", {
  .clear_cache()
  local_mocked_bindings(.ukaq_read_rdata = .stub("AAA_2020"))
  expect_error(
    nm_fetch_ukaq_measurements("AAA", c(2020, 2021), on_missing = "raise"),
    "could not fetch"
  )
})

test_that("an all-missing fetch returns an empty frame, not an error", {
  .clear_cache()
  local_mocked_bindings(.ukaq_read_rdata = .stub(character(0)))
  d <- nm_fetch_ukaq_measurements("AAA", 2020)
  expect_s3_class(d, "data.frame")
  expect_equal(nrow(d), 0)
})

test_that("meta join adds station attributes without duplicating rows", {
  .clear_cache()
  local_mocked_bindings(.ukaq_read_rdata = .stub())
  d <- nm_fetch_ukaq_measurements("AAA", 2020, meta = TRUE)
  expect_true(all(d$site_type == "Urban Traffic"))
  expect_true(all(d$latitude == 53))
  # AAA has two metadata rows (NOx and PM10); the join must not make 48.
  expect_equal(nrow(d), 24)
})

test_that("bad arguments are rejected", {
  .clear_cache()
  local_mocked_bindings(.ukaq_read_rdata = .stub())
  expect_error(nm_fetch_ukaq_measurements("AAA", 2020, on_missing = "explode"))
  expect_error(nm_fetch_ukaq_measurements(character(0), 2020), "non-empty")
  expect_error(nm_fetch_ukaq_measurements("AAA", integer(0)), "non-empty")
  expect_error(nm_fetch_ukaq_measurements("AAA", 2020, source = "nope"), "Unknown source")
})

# ---- station listing ----

test_that("metadata is renamed to the openair schema", {
  .clear_cache()
  local_mocked_bindings(.ukaq_read_rdata = .stub())
  s <- nm_list_ukaq_stations("aqe")
  expect_true(all(c("code", "site", "site_type", "latitude", "longitude", "network") %in% names(s)))
  expect_false("site_id" %in% names(s))
})

test_that("stations are deduplicated to one row each by default", {
  .clear_cache()
  local_mocked_bindings(.ukaq_read_rdata = .stub())
  s <- nm_list_ukaq_stations("aqe")
  expect_equal(nrow(s), 3)
  expect_false(any(duplicated(s$code)))
  expect_false("variable" %in% names(s))
})

test_that("all_variables keeps the per-species rows", {
  .clear_cache()
  local_mocked_bindings(.ukaq_read_rdata = .stub())
  s <- nm_list_ukaq_stations("aqe", all_variables = TRUE)
  expect_equal(nrow(s), 4)
  expect_true("variable" %in% names(s))
})

test_that("site_type and pollutant filters work, case-insensitively", {
  .clear_cache()
  local_mocked_bindings(.ukaq_read_rdata = .stub())
  expect_equal(nm_list_ukaq_stations("aqe", site_type = "Rural Background")$code, "BBB")
  expect_setequal(
    nm_list_ukaq_stations("aqe", site_type = c("rural background", "urban background"))$code,
    c("BBB", "CCC")
  )
  expect_equal(nm_list_ukaq_stations("aqe", pollutant = "PM10")$code, "AAA")
})

test_that("metadata is fetched once per source per session", {
  .clear_cache()
  n <- 0L
  local_mocked_bindings(.ukaq_read_rdata = function(url, retries = 3L) {
    n <<- n + 1L
    list(metadata = .meta)
  })
  nm_list_ukaq_stations("aqe")
  nm_list_ukaq_stations("aqe")
  expect_equal(n, 1L)
})


# ---------------------------------------------------------------------------
# aurn_live (SOS API) -- offline tests
#
# Every test stubs .aurn_live_site_codes directly (a plain function stub,
# not a network mock) except the ones testing that function itself, which
# use httr2::local_mocked_responses. Same split as normet-py's tests.
# ---------------------------------------------------------------------------

.clear_aurn_live_codes_cache <- function() {
  if (!is.null(.nm_aurn_live_codes_cache$codes)) {
    rm(list = "codes", envir = .nm_aurn_live_codes_cache)
  }
}

test_that("aurn_live pollutant code resolution is case-insensitive, including its own key", {
  expect_equal(.aurn_live_resolve_code("PM2.5"), 6001L)
  expect_equal(.aurn_live_resolve_code("no2"), 8L)
  # NOXasNO2 is mixed-case (kept that way to match the archive sources' own
  # column name) -- a naive toupper()-keyed lookup does not match it against
  # itself, which is exactly the bug this test is here to catch.
  expect_equal(.aurn_live_resolve_code("noxasno2"), 9L)
  expect_equal(.aurn_live_resolve_code("NOXasNO2"), 9L)
  expect_equal(.aurn_live_resolve_code(7L), 7L)
  expect_error(.aurn_live_resolve_code("XYZ"), "Unknown pollutant")
})

test_that("aurn_live is a recognised source", {
  expect_equal(.ukaq_check_source("aurn_live"), "aurn_live")
  expect_equal(.ukaq_check_source("AURN_LIVE"), "aurn_live")
})

test_that("station labels split into site name, dropping the pollutant suffix", {
  expect_equal(
    .aurn_live_split_label("Manchester Piccadilly-Nitrogen dioxide (air)"),
    "Manchester Piccadilly"
  )
  # No "-" at all: unchanged, not truncated.
  expect_equal(.aurn_live_split_label("London N. Kensington"), "London N. Kensington")
})

test_that("list_ukaq_stations(aurn_live) lists all stations with codes attached where known", {
  local_mocked_bindings(
    .aurn_live_site_codes = function() c("London N. Kensington" = "MY1")
  )
  station_payload <- list(
    list(properties = list(id = "100", label = "London N. Kensington"),
         geometry = list(coordinates = list(51.521, -0.213))),
    list(properties = list(id = "200", label = "Birmingham Centre"),
         geometry = list(coordinates = list(52.479, -1.906)))
  )
  httr2::local_mocked_responses(function(req) {
    expect_equal(req$url, paste0(.NM_AURN_LIVE_API, "/stations?limit=5000"))
    httr2::response_json(body = station_payload)
  })

  df <- nm_list_ukaq_stations("aurn_live")
  expect_equal(nrow(df), 2)
  expect_setequal(
    names(df),
    c("code", "site", "site_type", "latitude", "longitude", "start_date", "end_date", "network")
  )
  kens <- df[df$site == "London N. Kensington", ]
  expect_equal(kens$code, "MY1")
  expect_equal(kens$latitude, 51.521)
  expect_equal(kens$network, "aurn_live")
  expect_true(is.na(kens$site_type))
  birm <- df[df$site == "Birmingham Centre", ]
  expect_true(is.na(birm$code))  # not in the mocked site-code lookup
})

test_that("list_ukaq_stations(aurn_live, pollutant=) queries by phenomenon and drops variable", {
  local_mocked_bindings(
    .aurn_live_site_codes = function() c("London N. Kensington" = "MY1")
  )
  ts_payload <- list(list(
    id = "ts-1", label = "PM2.5 London N. Kensington",
    station = list(properties = list(id = "100", label = "London N. Kensington"),
                   geometry = list(coordinates = list(51.521, -0.213)))
  ))
  httr2::local_mocked_responses(function(req) {
    expect_equal(req$url, paste0(.NM_AURN_LIVE_API, "/timeseries?phenomenon=6001&limit=5000"))
    httr2::response_json(body = ts_payload)
  })

  df <- nm_list_ukaq_stations("aurn_live", pollutant = "PM2.5")
  expect_equal(nrow(df), 1)
  expect_equal(df$code, "MY1")
  expect_equal(df$site, "London N. Kensington")
  expect_false("variable" %in% names(df))
})

test_that("list_ukaq_stations(aurn_live, all_variables=TRUE) keeps one row per species", {
  local_mocked_bindings(.aurn_live_site_codes = function() character(0))
  ts_payload <- list(list(
    id = "ts-1",
    station = list(properties = list(id = "100", label = "London N. Kensington"),
                   geometry = list(coordinates = list(51.521, -0.213)))
  ))
  httr2::local_mocked_responses(function(req) httr2::response_json(body = ts_payload))

  df <- nm_list_ukaq_stations("aurn_live", pollutant = c("NO2", "O3"), all_variables = TRUE)
  expect_equal(nrow(df), 2)
  expect_setequal(df$variable, c("NO2", "O3"))
})

test_that("list_ukaq_stations(aurn_live) rejects site_type", {
  expect_error(
    nm_list_ukaq_stations("aurn_live", site_type = "Urban Traffic"),
    "site_type"
  )
})

test_that("fetch_ukaq_measurements(aurn_live) pivots to wide format and tags network", {
  local_mocked_bindings(
    .aurn_live_site_codes = function() c("London N. Kensington" = "MY1")
  )
  ts_discovery <- list(list(
    id = "ts-1",
    station = list(properties = list(id = "100", label = "London N. Kensington"),
                   geometry = list(coordinates = list(51.521, -0.213)))
  ))
  ts_data <- list(values = list(
    list(timestamp = 1704067200000, value = 12.5),
    list(timestamp = 1704070800000, value = 14.2)
  ))
  httr2::local_mocked_responses(function(req) {
    if (grepl("/timeseries\\?", req$url)) return(httr2::response_json(body = ts_discovery))
    if (grepl("getData", req$url)) return(httr2::response_json(body = ts_data))
    httr2::response_json(body = list())
  })

  d <- nm_fetch_ukaq_measurements("MY1", 2024, source = "aurn_live", pollutant = "PM2.5")
  expect_setequal(names(d), c("date", "code", "site", "PM2.5", "network"))
  expect_equal(nrow(d), 2)
  expect_equal(d$code[1], "MY1")
  expect_equal(d$site[1], "London N. Kensington")
  expect_true(all(d$network == "aurn_live"))
  expect_setequal(d$PM2.5, c(12.5, 14.2))
})

test_that("fetch_ukaq_measurements(aurn_live) with an unresolvable code returns empty", {
  # log$warn() goes through lgr, not base::warning() -- it does not raise an
  # R condition testthat::expect_warning() can catch (same reason no other
  # test in this file wraps a skipped-site case in expect_warning either).
  local_mocked_bindings(.aurn_live_site_codes = function() character(0))
  d <- nm_fetch_ukaq_measurements("NOPE", 2024, source = "aurn_live", pollutant = "NO2")
  expect_equal(nrow(d), 0)
})

test_that("fetch_ukaq_measurements(aurn_live) with on_missing='raise' stops on an unknown code", {
  local_mocked_bindings(.aurn_live_site_codes = function() character(0))
  expect_error(
    nm_fetch_ukaq_measurements(
      "NOPE", 2024, source = "aurn_live", pollutant = "NO2", on_missing = "raise"
    ),
    "unknown AURN code"
  )
})

test_that("fetch_ukaq_measurements(aurn_live) drops timestamp/value pairs with a NULL side", {
  local_mocked_bindings(
    .aurn_live_site_codes = function() c("London N. Kensington" = "MY1")
  )
  ts_discovery <- list(list(
    id = "ts-1",
    station = list(properties = list(id = "100", label = "London N. Kensington"),
                   geometry = list(coordinates = list(51.521, -0.213)))
  ))
  # NA, not NULL: jsonlite's toJSON(list(value = NULL)) encodes as
  # `{"value":{}}` (an empty object), not `{"value":null}`, so a literal
  # NULL here would not round-trip through response_json() the way a real
  # API's JSON null does. NA correctly encodes to `null` and decodes back
  # to NULL, matching what the live API actually sends for a missing value.
  ts_data <- list(values = list(
    list(timestamp = 1704067200000, value = 10.0),
    list(timestamp = 1704070800000, value = NA),
    list(timestamp = NA, value = 12.0)
  ))
  httr2::local_mocked_responses(function(req) {
    if (grepl("/timeseries\\?", req$url)) return(httr2::response_json(body = ts_discovery))
    if (grepl("getData", req$url)) return(httr2::response_json(body = ts_data))
    httr2::response_json(body = list())
  })

  d <- nm_fetch_ukaq_measurements("MY1", 2024, source = "aurn_live", pollutant = "NO2")
  expect_equal(nrow(d), 1)
  expect_equal(d$NO2, 10.0)
})

.FAKE_NETWORK_INFO_HTML <- paste0(
  '<html><body><form>\n',
  '<select id="site_id" name="site_id" class="form-control webkit-arrow_fix">\n',
  '<option value="">Select a site</option>\n',
  '<option value="MAN3">Manchester Piccadilly</option>\n',
  '<option value="MY1">London Marylebone Road</option>\n',
  "<option value=\"BRS8\">Bristol St Paul&#39;s</option>\n",
  "</select>\n</form></body></html>\n"
)

test_that("aurn_live_site_codes scrapes and decodes the network-info page, and caches", {
  .clear_aurn_live_codes_cache()
  n_calls <- 0L
  httr2::local_mocked_responses(function(req) {
    n_calls <<- n_calls + 1L
    expect_equal(req$url, paste0(.NM_AURN_NETWORK_INFO_URL, "?view=aurn"))
    httr2::response(body = charToRaw(.FAKE_NETWORK_INFO_HTML))
  })

  codes <- .aurn_live_site_codes()
  expect_equal(unname(codes["Manchester Piccadilly"]), "MAN3")
  expect_equal(unname(codes["London Marylebone Road"]), "MY1")
  expect_equal(unname(codes["Bristol St Paul's"]), "BRS8")  # &#39; decoded
  expect_false("" %in% unname(codes))

  # cached: a second call must not hit the network again
  again <- .aurn_live_site_codes()
  expect_identical(again, codes)
  expect_equal(n_calls, 1L)
  .clear_aurn_live_codes_cache()
})

test_that("aurn_live_site_codes is graceful on unparsable HTML", {
  .clear_aurn_live_codes_cache()
  httr2::local_mocked_responses(function(req) {
    httr2::response(body = charToRaw("<html>no select here</html>"))
  })
  codes <- .aurn_live_site_codes()
  expect_equal(length(codes), 0)
  .clear_aurn_live_codes_cache()
})
