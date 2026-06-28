test_that("nm_process_date handles various date formats and forces UTC", {
  # 1. Standard Date column
  df1 <- data.frame(date = as.Date("2026-05-19") + 0:4, value = 1:5)
  res1 <- nm_process_date(df1, verbose = FALSE)
  expect_s3_class(res1$date, "POSIXct")
  expect_equal(attr(res1$date, "tzone"), "UTC")

  # 2. String candidates
  df2 <- data.frame(my_date = c("2026-05-19 12:00:00", "2026-05-20 13:00:00"), value = 1:2)
  res2 <- nm_process_date(df2, verbose = FALSE)
  expect_true("date" %in% names(res2))
  expect_s3_class(res2$date, "POSIXct")
  expect_equal(attr(res2$date, "tzone"), "UTC")

  # 3. Invalid candidates should throw error
  df3 <- data.frame(not_a_date = c("hello", "world"), value = 1:2)
  expect_error(nm_process_date(df3, verbose = FALSE))
})

test_that("nm_prepare_data generates correct time features and cleans columns", {
  # Create a mock dataset
  dates <- seq(as.POSIXct("2026-01-01 00:00:00", tz = "UTC"),
    as.POSIXct("2026-01-02 23:00:00", tz = "UTC"),
    by = "hour")
  df <- data.frame(
    time = dates,
    val = rnorm(length(dates)),
    covar = rnorm(length(dates))
  )

  res <- nm_prepare_data(
    df = df,
    value = "val",
    covariates = "covar",
    na_rm = TRUE,
    split_method = "random",
    fraction = 0.75,
    seed = 123,
    verbose = FALSE
  )

  # Check columns
  expect_true("date" %in% names(res))
  expect_true("value" %in% names(res))
  expect_true("covar" %in% names(res))
  expect_true("date_unix" %in% names(res))
  expect_true("day_julian" %in% names(res))
  expect_true("weekday" %in% names(res))
  expect_true("hour" %in% names(res))
  expect_true("set" %in% names(res))

  # Check weekday is factor and hours are correct
  expect_s3_class(res$weekday, "factor")
  expect_equal(res$hour, as.integer(format(res$date, "%H")))
})

test_that("nm_split_into_sets splits correctly with different methods and fractions", {
  dates <- seq(as.POSIXct("2026-01-01", tz = "UTC"),
    as.POSIXct("2026-12-31", tz = "UTC"),
    by = "day")
  dt <- data.table::data.table(
    date = dates,
    value = rnorm(length(dates)),
    covar = rnorm(length(dates))
  )

  # 1. Random split
  res_rand <- normet:::nm_split_into_sets(data.table::copy(dt), split_method = "random", fraction = 0.8, seed = 123)
  expect_equal(mean(res_rand$set == "training"), 0.8, tolerance = 0.05)

  # 2. Time-series split (strict order)
  res_ts <- normet:::nm_split_into_sets(data.table::copy(dt), split_method = "ts", fraction = 0.75, seed = 123)
  train_idx <- which(res_ts$set == "training")
  test_idx <- which(res_ts$set == "testing")
  expect_true(max(train_idx) < min(test_idx))
  expect_equal(length(train_idx) / nrow(res_ts), 0.75, tolerance = 0.01)

  # 3. Season split
  res_seas <- normet:::nm_split_into_sets(data.table::copy(dt), split_method = "season", fraction = 0.7, seed = 123)
  # Verify each season is represented in training roughly at 70% fraction
  res_seas[, season := c("DJF", "DJF", "MAM", "MAM", "MAM", "JJA", "JJA", "JJA", "SON", "SON", "SON", "DJF")[as.integer(format(date, "%m"))]]
  seas_summary <- res_seas[, .(frac = sum(set == "training") / .N), by = season]
  for (f in seas_summary$frac) {
    expect_equal(f, 0.7, tolerance = 0.1)
  }

  # 4. Month split
  res_month <- normet:::nm_split_into_sets(data.table::copy(dt), split_method = "month", fraction = 0.6, seed = 123)
  res_month[, month := as.integer(format(date, "%m"))]
  month_summary <- res_month[, .(frac = sum(set == "training") / .N), by = month]
  for (f in month_summary$frac) {
    expect_equal(f, 0.6, tolerance = 0.1)
  }
})
