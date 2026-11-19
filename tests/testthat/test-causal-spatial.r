# Mirrors normet-py's tests/test_causal_spatial.py (PR #65).
#
# The haversine and bearing primitives are checked against values a spherical
# Earth has to give (a meridian degree, a parallel degree, the quarter and
# half circumference). The summary is checked on a constructed triangle of
# donors -- one due north, one due east, one due south of the treated unit --
# where every distance, bearing, sector and the centroid offset is known by
# construction, plus the honest treatment of a donor whose fix is missing.

KM_PER_DEG_N <- pi / 180.0 * 6371.0
KM_PER_DEG_E <- pi / 180.0 * 6371.0 * cos(pi / 180.0 * 51.5)

CUTOFF <- "2023-05-01"
TREATED <- "T"

.triangle_panel <- function() {
  # T at the origin of the layout; N due north, S due south, and E placed so
  # its forward azimuth lies mid-sector (~108 degrees, in [90, 135)): a
  # same-latitude east leg's initial bearing is a fraction of a degree *north*
  # of 90, which would fall in the NE bin. GHOST is named but unfixed.
  fixes <- list(T = c(51.5, 0.0), N = c(52.0, 0.0), E = c(51.4, 0.5), S = c(51.0, 0.0))
  dates <- as.Date("2023-01-01") + 0:2 * 31  # three monthly fixes, one per unit
  rows <- do.call(rbind, lapply(dates, function(date) {
    do.call(rbind, lapply(names(fixes), function(u) {
      data.frame(
        date = date, ID = u, value = 1.0,
        lat = fixes[[u]][1], lon = fixes[[u]][2], stringsAsFactors = FALSE
      )
    }))
  }))
  rows
}

.triangle_table <- function() {
  nm_donor_spatial_summary(.triangle_panel(), c("N", "E", "S", "GHOST"), TREATED, unit_col = "ID")
}

# A cell of the donor table by donor name: R 4.4 attaches no names when a
# column is pulled out of a data.frame, so the lookup goes through the donor
# column itself.
.cell <- function(tbl, donor, col) tbl[[col]][match(donor, rownames(tbl))]

# ------------------------------------------------------------------ primitives
test_that("nm_haversine coincides with itself", {
  expect_equal(nm_haversine(51.5, -0.1, 51.5, -0.1), 0.0)
})

test_that("nm_haversine: a quarter of a meridian is a quarter circumference", {
  expect_equal(nm_haversine(0.0, 0.0, 90.0, 0.0), pi / 2.0 * 6371.0, tolerance = 1e-9)
})

test_that("nm_haversine: antipodes are a half circumference", {
  expect_equal(nm_haversine(0.0, 0.0, 0.0, 180.0), pi * 6371.0, tolerance = 1e-9)
})

test_that("nm_haversine: one degree of parallel at 51.5 degrees north", {
  # The great circle, not the parallel's arc: the reference is the spherical
  # law of cosines, which the haversine must agree with to rounding.
  phi <- pi / 180.0 * 51.5
  dlam <- pi / 180.0 * 1.0
  sigma <- acos(sin(phi)^2 + cos(phi)^2 * cos(dlam))
  expect_equal(nm_haversine(51.5, 0.0, 51.5, 1.0), 6371.0 * sigma, tolerance = 1e-9)
  # And within the parallel's own arc length, which a degree of parallel
  # is to ~0.001 %: the flat-earth reading is still the right magnitude.
  expect_equal(nm_haversine(51.5, 0.0, 51.5, 1.0), KM_PER_DEG_E, tolerance = 1e-4)
})

test_that("nm_haversine is symmetric", {
  a <- nm_haversine(48.8, 2.3, 51.5, -0.1)
  b <- nm_haversine(51.5, -0.1, 48.8, 2.3)
  expect_equal(a, b, tolerance = 1e-12)
})

test_that("nm_haversine is elementwise", {
  d <- nm_haversine(c(51.5, 51.5), c(0.0, 0.0), 52.0, 0.0)
  expect_length(d, 2L)
  expect_equal(unlist(d), rep(0.5 * KM_PER_DEG_N, 2), tolerance = 1e-9)
})

test_that("nm_bearing gives the dues on the compass", {
  # Meridians and the equator are great circles, so the dues there are exact;
  # a same-latitude leg away from the equator curves, and its *initial*
  # bearing is a fraction of a degree off the parallel's 90.
  expect_equal(nm_bearing(51.5, 0.0, 52.5, 0.0), 0.0, tolerance = 1e-9)
  expect_equal(nm_bearing(51.5, 0.0, 50.5, 0.0), 180.0, tolerance = 1e-9)
  expect_equal(nm_bearing(0.0, 0.0, 0.0, 1.0), 90.0, tolerance = 1e-9)
  expect_equal(nm_bearing(0.0, 0.0, 0.0, -1.0), 270.0, tolerance = 1e-9)
})

test_that("nm_bearing: the diagonal is the forward azimuth", {
  # From the equator to (45, 45): y = sin(45)cos(45), x = sin(45), so the
  # forward azimuth is arctan(cos 45) -- a fact the great circle keeps.
  expect_equal(
    nm_bearing(0.0, 0.0, 45.0, 45.0),
    atan2(cos(pi / 180.0 * 45.0), 1.0) * 180.0 / pi,
    tolerance = 1e-9
  )
})

test_that("nm_bearing is always in [0, 360) and elementwise", {
  b <- nm_bearing(c(51.5, 51.5), c(0.0, 0.0), 50.5, -1.0)
  expect_length(b, 2L)
  expect_true(all(unlist(b) >= 0.0 & unlist(b) < 360.0))
})

# ------------------------------------------------------------- donor summary
test_that("nm_donor_spatial_summary places the triangle and keeps the missing one", {
  table <- .triangle_table()

  expect_equal(rownames(table), c("N", "E", "S", "GHOST"))
  expect_equal(colnames(table), c("donor", "distance_km", "bearing_deg", "sector"))
  # N and S sit on the treated unit's meridian, so their legs are exact; the
  # east leg is checked against the primitive itself, and on its magnitude.
  expect_equal(.cell(table, "N", "distance_km"), 0.5 * KM_PER_DEG_N, tolerance = 1e-9)
  expect_equal(.cell(table, "E", "distance_km"), nm_haversine(51.5, 0.0, 51.4, 0.5), tolerance = 1e-9)
  expect_gt(.cell(table, "E", "distance_km"), 34.0)
  expect_lt(.cell(table, "E", "distance_km"), 38.0)
  expect_equal(.cell(table, "S", "distance_km"), 0.5 * KM_PER_DEG_N, tolerance = 1e-9)
  expect_equal(.cell(table, "N", "bearing_deg"), 0.0, tolerance = 1e-9)
  expect_gt(.cell(table, "E", "bearing_deg"), 100.0)
  expect_lt(.cell(table, "E", "bearing_deg"), 115.0)
  expect_equal(.cell(table, "S", "bearing_deg"), 180.0, tolerance = 1e-9)
  expect_equal(.cell(table, c("N", "E", "S"), "sector"), c("N", "E", "S"))
  # The unfixed donor is read as missing, not dropped: the table is a
  # reading of the pool as named.
  expect_true(is.na(.cell(table, "GHOST", "distance_km")))
  expect_true(is.na(.cell(table, "GHOST", "bearing_deg")))
  expect_equal(.cell(table, "GHOST", "sector"), "?")
})

test_that("nm_donor_spatial_summary reads one fix per unit as the median", {
  df <- .triangle_panel()
  # One drifting fix on N's rows must not move the station: the median of
  # the unit's fixes is its position.
  i <- which(df$ID == "N" & df$date == min(df$date))[1]
  df$lat[i] <- df$lat[i] + 1e-6
  tbl <- nm_donor_spatial_summary(df, "N", TREATED, unit_col = "ID")
  expect_equal(
    .cell(tbl, "N", "distance_km"),
    0.5 * KM_PER_DEG_N,
    tolerance = 1e-9
  )
})

test_that("nm_donor_spatial_summary carries the weights when given", {
  w <- c(N = 0.5, E = 0.5)
  table <- nm_donor_spatial_summary(.triangle_panel(), c("N", "E", "S"), TREATED, unit_col = "ID", weights = w)
  expect_equal(.cell(table, "N", "weight"), 0.5)
  expect_equal(.cell(table, "E", "weight"), 0.5)
  expect_true(is.na(.cell(table, "S", "weight")))
  expect_false("weight" %in% colnames(.triangle_table()))
})

test_that("nm_donor_spatial_summary errors when the treated unit is unfixed", {
  panel <- .triangle_panel()
  df <- panel[panel$ID != TREATED, , drop = FALSE]
  expect_error(nm_donor_spatial_summary(df, "N", TREATED, unit_col = "ID"), "no coordinate")
})

test_that("nm_donor_spatial_summary errors when the coordinate columns are absent", {
  expect_error(
    nm_donor_spatial_summary(.triangle_panel()[, c("date", "ID", "value", "lat")], "N", TREATED, unit_col = "ID"),
    "coordinate columns"
  )
})

# ------------------------------------------------------------ spatial summary
test_that("nm_spatial_summary: the centroid of a triangle is the mean offset", {
  table <- .triangle_table()
  s <- nm_spatial_summary(table, n_donors = 4L)

  # The centroid as an averaged (east, north) offset vector of the placed
  # donors, read back from the table's own distances and bearings.
  placed <- table[is.finite(table$distance_km), , drop = FALSE]
  rad <- placed$bearing_deg * pi / 180
  d <- placed$distance_km
  exp <- sqrt(mean(d * sin(rad))^2 + mean(d * cos(rad))^2)
  expect_equal(s$centroid_offset_km, exp, tolerance = 1e-12)
  expect_gt(s$centroid_bearing_deg, 100.0)
  expect_lt(s$centroid_bearing_deg, 115.0)
  expect_equal(s$sector_coverage, c(N = 1L, E = 1L, S = 1L))
  expect_equal(s$sector_fraction, 3 / 8.0)
  expect_equal(s$n_donors_placed, 3L)
  expect_equal(s$n_donors_missing, 1L)
})

test_that("nm_spatial_summary of a single donor is that donor", {
  s <- nm_spatial_summary(.triangle_table()[c("N"), , drop = FALSE])
  expect_equal(s$centroid_offset_km, 0.5 * KM_PER_DEG_N, tolerance = 1e-9)
  expect_equal(s$centroid_bearing_deg, 0.0, tolerance = 1e-9)
  expect_equal(s$sector_coverage, c(N = 1L))
})

test_that("nm_spatial_summary of an unplaced pool is all missing", {
  s <- nm_spatial_summary(.triangle_table()["GHOST", , drop = FALSE], n_donors = 1L)
  expect_true(is.na(s$centroid_offset_km))
  expect_true(is.na(s$centroid_bearing_deg))
  expect_equal(s$sector_coverage, integer(0))
  expect_equal(s$sector_fraction, 0.0)
  expect_equal(s$n_donors_placed, 0L)
  expect_equal(s$n_donors_missing, 1L)
})

test_that("sector labels follow the bearing, not the alphabet", {
  # W (270) must be listed after E (90) in bearing order, not by name.
  s <- nm_spatial_summary(.triangle_table()[c("E", "S"), , drop = FALSE])
  expect_equal(names(s$sector_coverage), c("E", "S"))
})

# ---------------------------------------------------- nm_scm_diagnostics wiring
.fit_with_coordinates <- function() {
  # 120 pre-cutoff days, 40 post, per unit, with the triangle's coordinates.
  dates <- seq(as.Date("2023-01-01"), by = "day", length.out = 160)
  t <- seq_along(dates) - 1
  coords <- list(T = c(51.5, 0.0), N = c(52.0, 0.0), E = c(51.5, 0.5), S = c(51.0, 0.0))
  rows <- do.call(rbind, lapply(names(coords), function(u) {
    v <- 10.0 + 0.1 * t + ifelse(u == "T" & dates >= as.Date(CUTOFF), 10.0, 0.0)
    data.frame(
      date = dates, ID = u, value = v,
      lat = coords[[u]][1], lon = coords[[u]][2], stringsAsFactors = FALSE
    )
  }))
  panel <- rows
  result <- nm_scm(
    df = panel, date_col = "date", unit_col = "ID", outcome_col = "value",
    treated_unit = TREATED, cutoff_date = CUTOFF, donors = c("N", "E", "S"),
    allow_negative_weights = FALSE, verbose = FALSE
  )
  list(result = result, panel = panel)
}

test_that("nm_scm_diagnostics appends the spatial section when the panel has fixes", {
  fit <- .fit_with_coordinates()
  out <- nm_scm_diagnostics(
    fit$result, CUTOFF,
    panel = fit$panel, treated_unit = TREATED, unit_col = "ID",
    lat_col = "lat", lon_col = "lon"
  )
  expect_true("spatial" %in% names(out))
  expect_equal(rownames(out$spatial$donors), c("N", "E", "S"))
  # Donors default to the fit's weights' names, so the weight column is there.
  expect_true("weight" %in% colnames(out$spatial$donors))
  expect_equal(out$spatial$n_donors_placed, 3L)
  expect_equal(out$spatial$n_donors_missing, 0L)
  # The section agrees with calling the summary directly.
  direct <- nm_donor_spatial_summary(
    fit$panel, c("N", "E", "S"), TREATED, unit_col = "ID", weights = fit$result$weights
  )
  expect_equal(out$spatial$donors, direct)
})

test_that("nm_scm_diagnostics without a panel is what it was before", {
  fit <- .fit_with_coordinates()
  out <- nm_scm_diagnostics(fit$result, CUTOFF)
  expect_false("spatial" %in% names(out))
  # The panel carries fixes but no treated unit was named: still no section.
  out <- nm_scm_diagnostics(fit$result, CUTOFF, panel = fit$panel, unit_col = "ID", lat_col = "lat", lon_col = "lon")
  expect_false("spatial" %in% names(out))
})
