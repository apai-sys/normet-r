# Minimal but format-correct HYSPLIT tdump: 1 met grid, 1 backward trajectory,
# 5 diagnostic vars (PRESSURE RAINFALL MIXDEPTH RELHUMID AIR_TEMP), 3 endpoints
# (age 0, -1, -2). Receptor (age 0) at (51.520, -0.130); air origin (age -2)
# at (51.000, -2.500).
TDUMP <- paste(
  "     1     1",
  "    GDAS    20    10     1     0     0",
  "     1 BACKWARD OMEGA",
  "     1    20    10     1     0   51.520   -0.130    100.0",
  "     5 PRESSURE RAINFALL MIXDEPTH RELHUMID AIR_TEMP",
  "     1     1    20    10     1     0     0     0.0     0.0   51.520   -0.130    100.0    995.0    0.0   800.0     70.0    285.0",
  "     1     1    20     9    30    23     0     0.0    -1.0   51.300   -1.200    300.0    980.0    0.5   600.0     75.0    283.0",
  "     1     1    20     9    30    22     0     0.0    -2.0   51.000   -2.500    500.0    970.0    1.0   500.0     80.0    281.0",
  sep = "\n"
)

write_tdump <- function(dir, name = "tdump_2020100100") {
  p <- file.path(dir, name)
  writeLines(TDUMP, p)
  p
}

test_that("nm_read_trajectory_tdump parses endpoints", {
  tmp <- tempfile("traj_"); dir.create(tmp)
  df <- nm_read_trajectory_tdump(write_tdump(tmp))

  expect_equal(nrow(df), 3)
  expect_true(all(c("age_h", "lat", "lon", "height", "datetime") %in% colnames(df)))
  # MIXDEPTH -> blh, RELHUMID -> rh, AIR_TEMP -> temp; rainfall/pressure kept.
  expect_true(all(c("blh", "rh", "temp", "rainfall", "pressure") %in% colnames(df)))
  # 2-digit year decoded to 2020; receptor row is age 0.
  receptor <- df$datetime[df$age_h == 0]
  expect_equal(as.POSIXct("2020-10-01 00:00", tz = "UTC"), receptor)
})

test_that("nm_trajectory_features computes transport descriptors", {
  tmp <- tempfile("traj_"); dir.create(tmp)
  df <- nm_read_trajectory_tdump(write_tdump(tmp))
  f <- nm_trajectory_features(df, source_regions = list(sw_box = c(-3.0, 50.5, -1.5, 51.5)))

  expect_equal(f$traj_blh_mean, (800 + 600 + 500) / 3)
  expect_equal(f$traj_rain_sum, 1.5)
  expect_equal(f$traj_height_min, 100.0)
  expect_equal(f$traj_rh_mean, (70.0 + 75.0 + 80.0) / 3)
  expect_equal(f$traj_pressure_mean, (995.0 + 980.0 + 970.0) / 3)
  expect_equal(f$traj_temp_mean, (285.0 + 283.0 + 281.0) / 3)

  # Origin is SW of the receptor -> westerly inflow sector; path >= straight line.
  expect_gt(f$traj_dist_km, 100.0)
  expect_true(f$traj_inflow_deg > 200 && f$traj_inflow_deg < 290)
  expect_gte(f$traj_pathlen_km, f$traj_dist_km)

  # Only the origin endpoint falls in the SW box -> 1 of 3 endpoints.
  expect_equal(f$traj_resid_sw_box, 1 / 3)
})

test_that("nm_trajectory_features emits quality columns", {
  tmp <- tempfile("traj_"); dir.create(tmp)
  df <- nm_read_trajectory_tdump(write_tdump(tmp))
  f <- nm_trajectory_features(df)

  # The fixture reaches back exactly 2 h over 3 endpoints.
  expect_equal(f$traj_n_endpoints, 3)
  expect_equal(f$traj_age_max_h, 2)
  # Default (min_hours = NULL) keeps a short trajectory's geometry intact.
  expect_true(is.finite(f$traj_dist_km))
})

test_that("min_hours nulls a truncated trajectory but keeps the quality columns", {
  tmp <- tempfile("traj_"); dir.create(tmp)
  df <- nm_read_trajectory_tdump(write_tdump(tmp))
  box <- list(sw_box = c(-3.0, 50.5, -1.5, 51.5))

  # Reach (2 h) satisfies min_hours = 2 -> untouched.
  ok <- nm_trajectory_features(df, source_regions = box, min_hours = 2)
  expect_true(is.finite(ok$traj_dist_km))
  expect_equal(ok$traj_resid_sw_box, 1 / 3)

  # Asking for 72 h of a 2 h trajectory: every feature NA except the quality
  # columns, which stay so the truncation is visible rather than silent.
  short <- nm_trajectory_features(df, source_regions = box, min_hours = 72)
  expect_equal(short$traj_n_endpoints, 3)
  expect_equal(short$traj_age_max_h, 2)
  nulled <- setdiff(names(short), c("traj_n_endpoints", "traj_age_max_h"))
  expect_true(length(nulled) > 0)
  expect_true(all(vapply(short[nulled], is.na, logical(1))))
  # Same fields either way, so a table built from a mix stays rectangular.
  expect_setequal(names(short), names(ok))
})

test_that("nm_build_trajectory_features warns on truncated trajectories", {
  tmp <- tempfile("traj_"); dir.create(tmp)
  write_tdump(tmp, "tdump_a")

  skip_if_not_installed("lgr")
  lg <- nm_get_logger("io.trajectory")
  buf <- lgr::AppenderBuffer$new()
  lg$add_appender(buf, name = "test_buf")
  on.exit(lg$remove_appender("test_buf"), add = TRUE)

  out <- nm_build_trajectory_features(file.path(tmp, "tdump_*"), min_hours = 72)

  expect_true(all(is.na(out$traj_dist_km)))
  expect_equal(out$traj_age_max_h[1], 2)
  expect_true(any(grepl("truncated", buf$buffer_df$msg)))
})

test_that("overlapping source regions are detected, touching ones are not", {
  regions <- list(
    west = c(-10, 50, 0, 55),
    east = c(-2, 50, 5, 55),     # shares -2..0 with west
    north = c(-10, 55, 0, 60),   # only touches west along lat 55
    far = c(20, 30, 25, 35)
  )
  expect_equal(normet:::.overlapping_regions(regions), "west & east")
  expect_equal(normet:::.overlapping_regions(list(only = c(0, 0, 1, 1))), character(0))
})

test_that("overlap check handles sf polygons", {
  skip_if_not_installed("sf")
  tri <- sf::st_sfc(sf::st_polygon(list(rbind(c(-5, 50), c(5, 50), c(0, 58), c(-5, 50)))),
                    crs = 4326)
  regions <- list(tri = tri, box = c(-1, 51, 1, 52), away = c(20, 30, 25, 35))
  expect_equal(normet:::.overlapping_regions(regions), "tri & box")
})

test_that("nm_build_trajectory_features warns on overlapping regions", {
  skip_if_not_installed("lgr")
  tmp <- tempfile("traj_"); dir.create(tmp)
  write_tdump(tmp, "tdump_a")
  lg <- nm_get_logger("io.trajectory")
  buf <- lgr::AppenderBuffer$new()
  lg$add_appender(buf, name = "test_buf")
  on.exit(lg$remove_appender("test_buf"), add = TRUE)

  nm_build_trajectory_features(file.path(tmp, "tdump_*"),
    source_regions = list(uk = c(-6, 50, 2, 56), sw = c(-3.0, 50.5, -1.5, 51.5)))
  expect_true(any(grepl("overlap (uk & sw)", buf$buffer_df$msg, fixed = TRUE)))

  n_before <- nrow(buf$buffer_df)
  nm_build_trajectory_features(file.path(tmp, "tdump_*"),
    source_regions = list(sw = c(-3.0, 50.5, -1.5, 51.5)))
  later <- buf$buffer_df$msg[seq_len(nrow(buf$buffer_df)) > n_before]
  expect_false(any(grepl("overlap", later)))
})

test_that("nm_build_trajectory_features builds a receptor table", {
  tmp <- tempfile("traj_"); dir.create(tmp)
  write_tdump(tmp, "tdump_a")
  write_tdump(tmp, "tdump_b") # same receptor time -> deduplicated

  out <- nm_build_trajectory_features(
    file.path(tmp, "tdump_*"),
    source_regions = list(sw_box = c(-3.0, 50.5, -1.5, 51.5))
  )

  expect_s3_class(out, "data.frame")
  expect_equal(nrow(out), 1) # deduplicated on receptor timestamp
  expect_true("date" %in% colnames(out))
  expect_true(all(c("traj_dist_km", "traj_inflow_deg", "traj_resid_sw_box") %in% colnames(out)))
  expect_true(is.finite(out$traj_dist_km[1]))
})

test_that("SETUP.CFG text is well-formed", {
  txt <- normet:::.setup_cfg_text(normet:::.ALL_DIAGNOSTICS)
  expect_equal(txt[1], "&SETUP")
  expect_equal(txt[length(txt)], "/")
  expect_true("tm_pres = 1," %in% txt)
  expect_true("tm_rain = 1," %in% txt)
  expect_true("tm_mixd = 1," %in% txt)
  expect_true("tm_relh = 1," %in% txt)
  expect_true("tm_tamb = 1," %in% txt)

  subset_txt <- normet:::.setup_cfg_text(c("pressure", "rh"))
  expect_true("tm_pres = 1," %in% subset_txt)
  expect_true("tm_rain = 0," %in% subset_txt)
  expect_true("tm_relh = 1," %in% subset_txt)
  expect_true("tm_tamb = 0," %in% subset_txt)

  expect_error(normet:::.setup_cfg_text("bogus"), "Unknown diagnostic")
})

test_that("CONTROL text is well-formed", {
  txt <- normet:::.traj_control_text(
    as.POSIXct("2020-10-17 00:00", tz = "UTC"), 40.0, -90.0, 500.0, 24,
    "/data/oct1618.BIN", "tdump_x", 10000.0, 0
  )
  expect_equal(txt[1], "20 10 17 00")          # YY MM DD HH
  expect_equal(txt[2], "1")
  expect_equal(txt[3], "40.0000 -90.0000 500.0")
  expect_equal(txt[4], "-24")                  # negative run hours = backward
  expect_equal(txt[5], "0")
  expect_equal(txt[7], "1")                    # n_met
  expect_true(endsWith(txt[8], .Platform$file.sep))
  expect_equal(txt[9], "oct1618.BIN")
  expect_equal(txt[length(txt)], "tdump_x")
})

utc <- function(x) as.POSIXct(x, tz = "UTC")
MET <- paste0("gdas1.jan20.w", 1:5)

test_that(".parse_arl_date_range reads the span from a GDAS1 name", {
  r <- normet:::.parse_arl_date_range("/cache/dir/gdas1.apr20.w2")
  expect_equal(r$start, utc("2020-04-08 00:00:00"))
  expect_equal(r$end, utc("2020-04-14 23:59:59"))
  # w5 runs to the end of the month, however long it is.
  r5 <- normet:::.parse_arl_date_range("gdas1.apr20.w5")
  expect_equal(r5$end, utc("2020-04-30 23:59:59"))
  # A leap-year February has a 1-day w5.
  rf <- normet:::.parse_arl_date_range("gdas1.feb20.w5")
  expect_equal(rf$start, utc("2020-02-29 00:00:00"))
  expect_equal(rf$end, utc("2020-02-29 23:59:59"))
  # Unrecognised name -> NULL (callers keep the file).
  expect_null(normet:::.parse_arl_date_range("oct1618.BIN"))
})

test_that(".filter_met_files keeps only overlapping weeks", {
  # 72 h back from 16 Jan 12:00 stays inside w3 (15-21 Jan) and w2 (8-14 Jan).
  expect_equal(
    normet:::.filter_met_files(MET, utc("2020-01-13 12:00"), utc("2020-01-16 12:00")),
    c("gdas1.jan20.w2", "gdas1.jan20.w3")
  )
  expect_equal(
    normet:::.filter_met_files(MET, utc("2020-01-16 00:00"), utc("2020-01-17 00:00")),
    "gdas1.jan20.w3"
  )
})

test_that(".filter_met_files pads the window across a week boundary", {
  # 22:00 on 7 Jan lies in the gap between w1's last GDAS1 record (21:00) and
  # w2's first (8 Jan 00:00); interpolating there needs w2 as well. A strict
  # overlap test would drop it and hyts_std would fail (probed against hyts_std).
  win <- list(utc("2020-01-07 16:00"), utc("2020-01-07 22:00"))
  expect_equal(
    normet:::.filter_met_files(MET, win[[1]], win[[2]]),
    c("gdas1.jan20.w1", "gdas1.jan20.w2")
  )
  expect_equal(normet:::.filter_met_files(MET, win[[1]], win[[2]], pad_h = 0), "gdas1.jan20.w1")
  # ...but not once the window is a full record interval clear of the boundary.
  expect_equal(
    normet:::.filter_met_files(MET, utc("2020-01-07 06:00"), utc("2020-01-07 12:00")),
    "gdas1.jan20.w1"
  )
})

test_that(".filter_met_files always keeps unrecognised names", {
  paths <- c("gdas1.jan20.w1", "custom_met.BIN", "gdas1.jan20.w4")
  expect_equal(
    normet:::.filter_met_files(paths, utc("2020-01-02"), utc("2020-01-03")),
    c("gdas1.jan20.w1", "custom_met.BIN")
  )
})

# Stand-in for hyts_std: log the CONTROL it was given, then emit a canned tdump.
fake_run <- function(times, met_names, ...) {
  skip_on_os("windows")
  tmp <- tempfile("traj_"); dir.create(tmp)
  exe <- file.path(tmp, "hyts_std")
  writeLines(c(
    "#!/bin/sh",
    "name=$(tail -n 1 CONTROL)",
    "cp CONTROL \"CONTROL_$name\"",
    "cp \"$FAKE_TDUMP\" \"$name\""
  ), exe)
  Sys.chmod(exe, "755")
  old <- Sys.getenv("FAKE_TDUMP", unset = NA)
  Sys.setenv(FAKE_TDUMP = write_tdump(tmp))
  on.exit(if (is.na(old)) Sys.unsetenv("FAKE_TDUMP") else Sys.setenv(FAKE_TDUMP = old),
          add = TRUE)
  mets <- file.path(tmp, met_names)
  for (m in mets) writeLines("", m)
  work <- file.path(tmp, "work")
  nm_run_back_trajectories(times, 51.5, -0.13,
    met_files = mets, hysplit_exec = exe, work_dir = work, ...
  )
  work
}

control_mets <- function(work, name) {
  lines <- readLines(file.path(work, paste0("CONTROL_", name)))
  n_met <- as.integer(lines[7])
  lines[9 + 2 * (seq_len(n_met) - 1)]  # (dir, file) pairs -> file names
}

test_that("nm_run_back_trajectories passes only relevant met files", {
  work <- fake_run(c(utc("2020-01-16 12:00"), utc("2020-01-03 06:00")), MET, hours_back = 72)
  expect_equal(control_mets(work, "tdump_2020011612"), c("gdas1.jan20.w2", "gdas1.jan20.w3"))
  expect_equal(control_mets(work, "tdump_2020010306"), "gdas1.jan20.w1")
})

test_that("nm_run_back_trajectories falls back to all met files when none overlap", {
  work <- fake_run(utc("2021-06-01 00:00"), MET[1:2], hours_back = 24)
  expect_equal(control_mets(work, "tdump_2021060100"), MET[1:2])
})

test_that("nm_run_back_trajectories warns on truncated trajectories", {
  skip_if_not_installed("lgr")
  lg <- nm_get_logger("io.trajectory")
  buf <- lgr::AppenderBuffer$new()
  lg$add_appender(buf, name = "test_buf")
  on.exit(lg$remove_appender("test_buf"), add = TRUE)
  # The canned tdump reaches back 2 h, the run asks for 24 -> truncated.
  fake_run(utc("2020-01-16 12:00"), MET, hours_back = 24)
  expect_true(any(grepl("stopped short", buf$buffer_df$msg)))
})

test_that("nm_run_back_trajectories requires an executable hyts_std", {
  tmp <- tempfile("traj_"); dir.create(tmp)
  expect_error(
    nm_run_back_trajectories(
      as.POSIXct("2020-10-17", tz = "UTC"), 40.0, -90.0,
      met_files = file.path(tmp, "none.BIN"),
      hysplit_exec = file.path(tmp, "nonexistent_hyts_std")
    )
  )
})
