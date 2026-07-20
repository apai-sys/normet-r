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
    target = "val",
    covariates = "covar",
    dropna = TRUE,
    split_method = "random",
    train_fraction = 0.75,
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
  res_rand <- normet:::nm_split_into_sets(data.table::copy(dt), split_method = "random", train_fraction = 0.8, seed = 123)
  expect_equal(mean(res_rand$set == "training"), 0.8, tolerance = 0.05)

  # 2. Time-series split (strict order)
  res_ts <- normet:::nm_split_into_sets(data.table::copy(dt), split_method = "ts", train_fraction = 0.75, seed = 123)
  train_idx <- which(res_ts$set == "training")
  test_idx <- which(res_ts$set == "testing")
  expect_true(max(train_idx) < min(test_idx))
  expect_equal(length(train_idx) / nrow(res_ts), 0.75, tolerance = 0.01)

  # Helper: within one date-ordered group, "testing" positions must form a
  # single contiguous run (a block held out at *some* position, not
  # scattered/interleaved) -- this is the invariant that still holds after
  # randomising the block's position; it no longer sits fixed at the end.
  expect_contiguous_test_block <- function(is_test) {
    if (!any(is_test)) return(invisible(TRUE))
    runs <- rle(is_test)
    expect_equal(sum(runs$values), 1)
  }

  # 3. month_ts split: chronological within each (year, month); no leakage
  # within a block, every calendar month across every year contributes
  # training rows, and the held-out block is contiguous but at a
  # randomised (seeded) position rather than always the trailing slice.
  res_mts <- normet:::nm_split_into_sets(data.table::copy(dt), split_method = "month_ts", train_fraction = 0.6, seed = 123)
  res_mts[, ym := format(date, "%Y-%m")]
  data.table::setorder(res_mts, ym, date)
  mts_summary <- res_mts[, .(frac = sum(set == "training") / .N), by = ym]
  for (f in mts_summary$frac) {
    expect_equal(f, 0.6, tolerance = 0.1)
  }
  for (grp in split(res_mts$set == "testing", res_mts$ym)) {
    expect_contiguous_test_block(grp)
  }

  # 4. season_ts split: chronological within each (meteorological year, season);
  # December rolls into the following year's DJF block. Same contiguous-
  # block-at-a-randomised-position invariant as month_ts.
  res_sts <- normet:::nm_split_into_sets(data.table::copy(dt), split_method = "season_ts", train_fraction = 0.7, seed = 123)
  season_map <- c("DJF", "DJF", "MAM", "MAM", "MAM", "JJA", "JJA", "JJA", "SON", "SON", "SON", "DJF")
  mon <- as.integer(format(res_sts$date, "%m"))
  res_sts[, season := season_map[mon]]
  res_sts[, season_year := as.integer(format(date, "%Y"))]
  res_sts[mon == 12L, season_year := season_year + 1L]
  data.table::setorder(res_sts, season_year, season, date)
  sts_summary <- res_sts[, .(frac = sum(set == "training") / .N),
                          by = .(season_year, season)]
  for (f in sts_summary$frac) {
    expect_equal(f, 0.7, tolerance = 0.1)
  }
  for (grp in split(res_sts$set == "testing", paste(res_sts$season_year, res_sts$season))) {
    expect_contiguous_test_block(grp)
  }

  # 5. Randomised block position: with several different seeds, the
  # held-out block's position within a fixed month should not always land
  # in the same place (the old bug: always the trailing slice).
  starts <- sapply(1:6, function(s) {
    r <- normet:::nm_split_into_sets(data.table::copy(dt), split_method = "month_ts", train_fraction = 0.6, seed = s)
    r[, ym := format(date, "%Y-%m")]
    data.table::setorder(r, ym, date)
    jan <- r[ym == "2026-01"]
    min(which(jan$set == "testing"))
  })
  expect_true(length(unique(starts)) > 1)
})
