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

log_buffer <- function(envir = parent.frame()) {
  lg <- nm_get_logger("io.trajectory")
  buf <- lgr::AppenderBuffer$new()
  name <- paste0("test_buf_", sample.int(1e9, 1))
  lg$add_appender(buf, name = name)
  withr::defer(lg$remove_appender(name), envir = envir)
  buf
}

test_that("nm_run_back_trajectories skips times no met file covers", {
  skip_if_not_installed("lgr")
  buf <- log_buffer()
  # A receptor time whose window no file can touch is not run at all: handing
  # hyts_std every file only made each such run fail, one by one.
  times <- c(utc("2020-01-03 06:00"), utc("2021-06-01 00:00"))
  work <- fake_run(times, MET[1:2], hours_back = 24)
  expect_equal(control_mets(work, "tdump_2020010306"), "gdas1.jan20.w1")
  expect_false(file.exists(file.path(work, "CONTROL_tdump_2021060100")))
  expect_true(any(grepl("1 of 2 receptor times skipped", buf$buffer_df$msg)))

  expect_error(fake_run(times[2], MET[1:2], hours_back = 24), "No met file covers")
})

test_that("nm_run_back_trajectories removes a stale tdump", {
  skip_on_os("windows")
  # A reused work_dir held a tdump of the same name from an earlier receptor;
  # a run that then failed used to pass that file off as its own.
  tmp <- tempfile("traj_"); dir.create(tmp)
  work <- file.path(tmp, "work"); dir.create(work)
  writeLines(TDUMP, file.path(work, "tdump_2020011612"))
  exe <- file.path(tmp, "hyts_std")
  writeLines(c("#!/bin/sh", "exit 1"), exe)
  Sys.chmod(exe, "755")
  mets <- file.path(tmp, MET)
  for (m in mets) writeLines("", m)
  expect_error(
    suppressWarnings(nm_run_back_trajectories(utc("2020-01-16 12:00"), 51.5, -0.13,
      met_files = mets, hysplit_exec = exe, work_dir = work)),
    "No trajectories produced"
  )
  expect_false(file.exists(file.path(work, "tdump_2020011612")))
})

test_that("nm_run_back_trajectories runs on UTC and keeps minutes", {
  times <- c(
    as.POSIXct("2020-01-16 13:30", tz = "Europe/Paris"), # 12:30 UTC
    utc("2020-01-16 12:30"),                             # the same instant: run once
    utc("2020-01-03 06:00"),
    NA
  )
  work <- fake_run(times, MET, hours_back = 24)
  controls <- sort(basename(Sys.glob(file.path(work, "CONTROL_*"))))
  expect_equal(controls, c("CONTROL_tdump_2020010306", "CONTROL_tdump_202001161230"))
  lines <- readLines(file.path(work, "CONTROL_tdump_202001161230"))
  expect_equal(lines[1], "20 01 16 12 30")
  expect_equal(control_mets(work, "tdump_202001161230"), "gdas1.jan20.w3")

  # Text with an offset is converted by it; text without one is UTC.
  work <- fake_run(c("2020-01-16T13:30+01:00", "2020-01-03 06:00"), MET, hours_back = 24)
  controls <- sort(basename(Sys.glob(file.path(work, "CONTROL_*"))))
  expect_equal(controls, c("CONTROL_tdump_2020010306", "CONTROL_tdump_202001161230"))
})

test_that("nm_run_back_trajectories stops when asked", {
  skip_if_not_installed("lgr")
  buf <- log_buffer()
  calls <- 0
  stop_after_one <- function() {
    calls <<- calls + 1
    calls > 1
  }
  times <- c(utc("2020-01-16 12:00"), utc("2020-01-16 13:00"))
  work <- fake_run(times, MET, stop = stop_after_one)
  expect_length(Sys.glob(file.path(work, "CONTROL_*")), 1) # the second never started
  expect_true(any(grepl("Stopped after 1 of 2", buf$buffer_df$msg)))
  expect_error(fake_run(times, MET, stop = "yes"), "must be NULL or a function")
})

test_that(".missing_gdas1_files names the weeks a window needs", {
  have <- c("/met/gdas1.jan20.w1", "/met/gdas1.jan20.w2")
  f <- normet:::.missing_gdas1_files
  expect_equal(f(have, utc("2020-01-05"), utc("2020-01-16")), "gdas1.jan20.w3")
  expect_equal(f(have, utc("2020-01-02"), utc("2020-01-09")), character(0))
  # 22:00 on 14 Jan interpolates towards w3's first record, as in .filter_met_files.
  expect_equal(f(have, utc("2020-01-12"), utc("2020-01-14 22:00")), "gdas1.jan20.w3")
  expect_null(f(c(have, "/met/custom.arl"), utc("2020-01-05"), utc("2020-02-01")))
})

test_that("CONTROL text carries minutes off the hour", {
  txt <- normet:::.traj_control_text(
    utc("2020-10-17 12:30"), 40.0, -90.0, 500.0, 24, "/d/m", "t", 10000.0, 0
  )
  expect_equal(txt[1], "20 10 17 12 30")
})

# A tdump holding one trajectory per (lat, lon, height) start, all arriving
# 2020-10-01 00:00 and drifting south-west an hour at a time.
tdump_text <- function(starts, n_endpoints = 3) {
  head <- c("     1     1", "    GDAS    20    10     1     0     0",
            sprintf("%6d BACKWARD OMEGA", length(starts)))
  for (st in starts) {
    head <- c(head, sprintf("    20    10     1     0 %8.3f %8.3f %7.1f", st[1], st[2], st[3]))
  }
  head <- c(head, "     1 PRESSURE")
  rows <- character(0)
  for (k in seq_along(starts)) {
    st <- starts[[k]]
    for (a in seq_len(n_endpoints) - 1) {
      when <- utc("2020-10-01 00:00") - a * 3600
      lt <- as.POSIXlt(when, tz = "UTC")
      rows <- c(rows, sprintf(
        "%6d     1 %s %5d %5d %5d     0     0 %7.1f %8.3f %8.3f %8.1f    990.0",
        k, format(when, "%y", tz = "UTC"), lt$mon + 1, lt$mday, lt$hour, -a,
        st[1] - 0.3 * a, st[2] - 0.6 * a, st[3] + 10 * a
      ))
    }
  }
  c(head, rows)
}

test_that("nm_build_trajectory_features gives each start height its own columns", {
  tmp <- tempfile("traj_"); dir.create(tmp)
  # One run started at three heights used to collapse to a single row: the
  # last height's, the other two dropped as "duplicates" of the receptor time.
  writeLines(tdump_text(list(c(51.5, -0.1, 100), c(51.5, -0.1, 500), c(51.5, -0.1, 1500))),
             file.path(tmp, "tdump_x"))
  out <- nm_build_trajectory_features(file.path(tmp, "tdump_*"))
  expect_equal(nrow(out), 1)
  expect_true(all(c("traj_dist_km_100m", "traj_dist_km_500m", "traj_dist_km_1500m") %in% names(out)))
  expect_equal(out$traj_height_min_100m, 100)
  expect_equal(out$traj_height_min_1500m, 1500)
  expect_false("traj_dist_km" %in% names(out))
  expect_false(any(startsWith(names(out), ".start")))

  # One height: the columns keep their plain names.
  writeLines(tdump_text(list(c(51.5, -0.1, 500))), file.path(tmp, "tdump_x"))
  out <- nm_build_trajectory_features(file.path(tmp, "tdump_*"))
  expect_true("traj_dist_km" %in% names(out))
  expect_false(any(startsWith(names(out), ".start")))
})

test_that("nm_build_trajectory_features refuses trajectories from several places", {
  tmp <- tempfile("traj_"); dir.create(tmp)
  writeLines(tdump_text(list(c(51.5, -0.1, 500))), file.path(tmp, "tdump_a"))
  writeLines(tdump_text(list(c(10, 20, 500))), file.path(tmp, "tdump_b"))
  expect_error(nm_build_trajectory_features(file.path(tmp, "tdump_*")),
               "2 different places ((51.5, -0.1), (10, 20))", fixed = TRUE)
})

hourly <- function(start, hours, ...) {
  data.frame(date = seq(utc(start), by = "hour", length.out = hours), ..., stringsAsFactors = FALSE)
}
feats_at <- function(times, values, site = NULL) {
  f <- data.frame(date = utc(times), traj_x = values)
  if (!is.null(site)) f <- cbind(site = site, f, stringsAsFactors = FALSE)
  f
}

test_that("nm_join_trajectory_features takes the latest trajectory to have arrived", {
  # 6-hourly trajectories at 00, 06 and 18 (12's is missing), an hourly panel
  # from 22:00 the day before to 23:00.
  panel <- hourly("2020-01-01 22:00", 26)
  feats <- feats_at(c("2020-01-02 00:00", "2020-01-02 06:00", "2020-01-02 18:00"), c(0, 6, 18))
  out <- nm_join_trajectory_features(panel, feats)
  got <- stats::setNames(out$traj_x, format(out$date, "%d %H"))
  expect_true(is.na(got[["01 23"]]))            # before the first trajectory
  expect_equal(unname(got[c("02 00", "02 04", "02 05")]), c(0, 0, 0)) # not 06:00's
  expect_equal(unname(got[c("02 06", "02 11")]), c(6, 6))
  expect_true(all(is.na(got[c("02 12", "02 17")]))) # its trajectory is missing
  expect_equal(unname(got[c("02 18", "02 23")]), c(18, 18))
  expect_equal(names(out), c("date", "traj_x"))
  expect_equal(nrow(out), nrow(panel))

  # The interval can be given; a single trajectory alone matches its own time.
  expect_equal(sum(!is.na(nm_join_trajectory_features(panel, feats, tolerance = "2h")$traj_x)), 6)
  expect_equal(sum(!is.na(nm_join_trajectory_features(panel, feats, tolerance = 2)$traj_x)), 6)
  expect_equal(sum(!is.na(nm_join_trajectory_features(panel, feats[1, ])$traj_x)), 1)
})

test_that("nm_join_trajectory_features matches each site and keeps the others' rows", {
  panel <- rbind(hourly("2020-01-01", 3, site = "MY1"), hourly("2020-01-01", 3, site = "KC1"))
  t <- c("2020-01-01 00:00", "2020-01-01 01:00", "2020-01-01 02:00")
  out <- nm_join_trajectory_features(panel, feats_at(t, c(1, 2, 3), site = "MY1"))
  expect_equal(out$traj_x[out$site == "MY1"], c(1, 2, 3))
  expect_true(all(is.na(out$traj_x[out$site == "KC1"])))

  # The next site's batch fills its own rows and leaves MY1's; a batch sent
  # again replaces its columns rather than adding new ones.
  out <- nm_join_trajectory_features(out, feats_at(t, c(7, 8, 9), site = "KC1"))
  out <- nm_join_trajectory_features(out, feats_at(t, c(4, 5, 6), site = "MY1"))
  expect_equal(names(out), c("date", "site", "traj_x"))
  expect_equal(out$traj_x, c(4, 5, 6, 7, 8, 9))
})

test_that("nm_join_trajectory_features names a site the panel does not have", {
  skip_if_not_installed("lgr")
  buf <- log_buffer()
  panel <- hourly("2020-01-01", 3, site = "MY1")
  out <- nm_join_trajectory_features(panel, feats_at("2020-01-01", 1, site = "London"))
  expect_true(all(is.na(out$traj_x)))
  expect_true(any(grepl("site(s) London", buf$buffer_df$msg, fixed = TRUE)))

  # Untagged features onto several sites: every site takes them, and it is said.
  two <- rbind(panel, hourly("2020-01-01", 3, site = "KC1"))
  out <- nm_join_trajectory_features(two, feats_at("2020-01-01", 1))
  expect_equal(sum(!is.na(out$traj_x)), 2)
  expect_true(any(grepl("all 2 of the panel's sites", buf$buffer_df$msg)))
})

test_that("nm_join_trajectory_features without a site column in the panel", {
  panel <- hourly("2020-01-01", 2)
  out <- nm_join_trajectory_features(panel, feats_at("2020-01-01", 1, site = "MY1"))
  expect_equal(out$traj_x[1], 1) # one site: the panel is that site
  two <- rbind(feats_at("2020-01-01", 1, "A"), feats_at("2020-01-01", 2, "B"))
  expect_error(nm_join_trajectory_features(panel, two),
               "2 sites (A, B) but df has no 'site' column", fixed = TRUE)
})

test_that("nm_join_trajectory_features keeps rows without a time and compares as UTC", {
  feats <- feats_at(c("2020-07-01 00:00", "2020-07-01 06:00"), c(0, 6))
  panel <- data.frame(
    # 07:00 in London in July is 06:00 UTC: it takes 06:00's trajectory.
    date = c("2020-07-01 07:00+01:00", NA, "2020-07-01 05:00+00:00"),
    pm25 = c(1, 2, 3), stringsAsFactors = FALSE
  )
  out <- nm_join_trajectory_features(panel, feats)
  expect_equal(out$traj_x[c(1, 3)], c(6, 0))
  expect_true(is.na(out$traj_x[2]))  # no time: kept, with nothing joined
  expect_equal(out$date, panel$date) # the panel's own column is left as it was

  # A POSIXct in another time zone is the same instant.
  local <- data.frame(date = as.POSIXct("2020-07-01 07:00", tz = "Europe/London"))
  expect_equal(nm_join_trajectory_features(local, feats)$traj_x, 6)
})

test_that("nm_join_trajectory_features refuses ambiguous features", {
  panel <- hourly("2020-01-01", 2)
  twice <- feats_at(c("2020-01-01", "2020-01-01"), c(1, 2))
  expect_error(nm_join_trajectory_features(panel, twice), "keep one per time")
  expect_error(nm_join_trajectory_features(panel, twice[1, ], tolerance = "0h"),
               "tolerance must be positive")
  expect_error(nm_join_trajectory_features(panel[, 0, drop = FALSE], twice[1, ]),
               "no 'date' column")
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
