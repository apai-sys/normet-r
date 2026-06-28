# Minimal but format-correct HYSPLIT tdump: 1 met grid, 1 backward trajectory,
# 3 diagnostic vars (PRESSURE RAINFALL MIXDEPTH), 3 endpoints (age 0, -1, -2).
# Receptor (age 0) at (51.520, -0.130); air origin (age -2) at (51.000, -2.500).
TDUMP <- paste(
  "     1     1",
  "    GDAS    20    10     1     0     0",
  "     1 BACKWARD OMEGA",
  "     1    20    10     1     0   51.520   -0.130    100.0",
  "     3 PRESSURE RAINFALL MIXDEPTH",
  "     1     1    20    10     1     0     0     0.0     0.0   51.520   -0.130    100.0    995.0    0.0   800.0",
  "     1     1    20     9    30    23     0     0.0    -1.0   51.300   -1.200    300.0    980.0    0.5   600.0",
  "     1     1    20     9    30    22     0     0.0    -2.0   51.000   -2.500    500.0    970.0    1.0   500.0",
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
  # MIXDEPTH -> blh; rainfall/pressure kept.
  expect_true(all(c("blh", "rainfall", "pressure") %in% colnames(df)))
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

  # Origin is SW of the receptor -> westerly inflow sector; path >= straight line.
  expect_gt(f$traj_dist_km, 100.0)
  expect_true(f$traj_inflow_deg > 200 && f$traj_inflow_deg < 290)
  expect_gte(f$traj_pathlen_km, f$traj_dist_km)

  # Only the origin endpoint falls in the SW box -> 1 of 3 endpoints.
  expect_equal(f$traj_resid_sw_box, 1 / 3)
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
