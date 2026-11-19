# Element by element: as.POSIXct() reads a whole vector by its first value's format.
utc <- function(x) {
  .POSIXct(vapply(x, function(v) as.numeric(as.POSIXct(v, tz = "UTC")), numeric(1),
                  USE.NAMES = FALSE), tz = "UTC")
}
bytes_file <- function(text, ext = ".csv") {
  f <- tempfile(fileext = ext)
  con <- file(f, "wb")
  writeBin(text, con)
  close(con)
  f
}

test_that("nm_parse_dates reads ISO times with a T, and offsets each by its own", {
  # as.POSIXct() would read both as midnight and ignore the offset.
  x <- nm_parse_dates(c("2020-01-31T13:00", "2020-01-31 13:00:00+01:00"))
  expect_equal(x, utc(c("2020-01-31 13:00", "2020-01-31 12:00")), ignore_attr = TRUE)

  # Local time across a daylight-saving change: +00:00 in winter, +01:00 in
  # summer. Each value is converted to UTC by its own offset; no-offset is UTC.
  x <- nm_parse_dates(c("2020-03-29T00:30+00:00", "2020-03-29T02:30+01:00",
                        "2020-03-29 03:00", "2020-07-01T12:00Z"))
  expect_equal(x, utc(c("2020-03-29 00:30", "2020-03-29 01:30", "2020-03-29 03:00",
                        "2020-07-01 12:00")), ignore_attr = TRUE)
})

test_that("nm_parse_dates settles the day/month order from the column", {
  x <- nm_parse_dates(c("31/01/2020 13:00", "01/02/2020 14:00"))
  expect_equal(x, utc(c("2020-01-31 13:00", "2020-02-01 14:00")), ignore_attr = TRUE)
  expect_match(attr(x, "how"), "day first")
  x <- nm_parse_dates(c("01/31/2020", "02/01/2020"))
  expect_equal(x, utc(c("2020-01-31", "2020-02-01")), ignore_attr = TRUE)
  expect_match(attr(x, "how"), "month first")
  # Neither tells: month first, unless dotted (day first) or asked.
  expect_equal(nm_parse_dates("01/02/2020"), utc("2020-01-02"), ignore_attr = TRUE)
  expect_equal(nm_parse_dates("01.02.2020"), utc("2020-02-01"), ignore_attr = TRUE)
  expect_equal(nm_parse_dates("01/02/2020", dayfirst = TRUE), utc("2020-02-01"),
               ignore_attr = TRUE)
  expect_match(attr(nm_parse_dates("01/02/2020"), "how"), "does not tell")
})

test_that("nm_parse_dates reads month names, AM/PM, CJK dates and numbers", {
  expect_equal(nm_parse_dates(c("Jan 5, 2020 1:30 PM", "5 Feb 2020")),
               utc(c("2020-01-05 13:30", "2020-02-05")), ignore_attr = TRUE)
  cjk <- paste0("2020", intToUtf8(0x5e74), "1", intToUtf8(0x6708), "31", intToUtf8(0x65e5),
                " 13", intToUtf8(0x65f6), "05", intToUtf8(0x5206))
  expect_equal(nm_parse_dates(cjk), utc("2020-01-31 13:05"), ignore_attr = TRUE)
  expect_equal(nm_parse_dates(c(1577880000, 1577883600)),
               utc(c("2020-01-01 12:00", "2020-01-01 13:00")), ignore_attr = TRUE)
  expect_equal(nm_parse_dates(1577880000000), utc("2020-01-01 12:00"), ignore_attr = TRUE)
  expect_equal(nm_parse_dates(c(43831, 43832.5)),
               utc(c("2020-01-01", "2020-01-02 12:00")), ignore_attr = TRUE)
  expect_equal(nm_parse_dates(20200131), utc("2020-01-31"), ignore_attr = TRUE)
  expect_equal(nm_parse_dates(2020013113), utc("2020-01-31 13:00"), ignore_attr = TRUE)
  expect_error(nm_parse_dates(c(1, 2)), "not times normet can read")
  expect_true(all(is.na(nm_parse_dates(c("bad", NA)))))
})

test_that("nm_process_date no longer drops the time of ISO dates", {
  df <- data.frame(date = c("2020-01-01T13:00:00", "2020-01-01 14:00:00+01:00"), x = 1:2)
  out <- nm_process_date(df, verbose = FALSE)
  expect_equal(out$date, utc(c("2020-01-01 13:00", "2020-01-01 13:00")))
})

test_that("clocks: on a zone, to UTC and back", {
  x <- c("2020-07-01T07:00+01:00", "2020-01-01T07:00Z", "2020-01-01 08:00")
  expect_equal(nm_on_clock(x, "Europe/London"),
               utc(c("2020-07-01 07:00", "2020-01-01 07:00", "2020-01-01 08:00")))
  expect_equal(nm_on_clock(as.POSIXct("2020-07-01 08:00", tz = "Europe/Paris"), "Europe/London"),
               utc("2020-07-01 07:00"))
  expect_equal(nm_on_clock(x[1]), utc("2020-07-01 06:00"))

  clock <- utc(c("2020-07-01 07:00", "2020-03-29 01:30", "2020-10-25 01:30", "2020-10-25 01:30"))
  # 01:30 on 29 March does not exist in London: forward to the change (01:00 UTC);
  # 01:30 on 25 October happens twice: first BST, then GMT.
  expect_equal(nm_clock_to_utc(clock, "Europe/London"),
               utc(c("2020-07-01 06:00", "2020-03-29 01:00", "2020-10-25 00:30",
                     "2020-10-25 01:30")))
  expect_equal(nm_utc_to_clock(utc("2020-07-01 06:00"), "Asia/Shanghai"), utc("2020-07-01 14:00"))
  expect_equal(nm_clock_to_utc(clock[1], "UTC"), clock[1])
})

test_that("nm_read_table settles separators, decimal commas and encodings", {
  # Semicolons, decimal commas, a blank row, a UTF-8 "\u00b5" in the header.
  f <- bytes_file(c(charToRaw("Date;NO2 (ug/m3) "), as.raw(c(0xc2, 0xb5)),
                    charToRaw("\r\n31.01.2020 13:00;12,5\r\n;\r\n01.02.2020 14:00;9,0\r\n")))
  df <- nm_read_table(f)
  expect_equal(nrow(df), 2)
  expect_equal(df[[2]], c(12.5, 9))
  expect_equal(names(df)[2], paste0("NO2 (ug/m3) ", intToUtf8(0xb5)))

  # Windows-1252 (a degree sign GB18030 cannot read either) and GB18030 headers.
  f <- bytes_file(charToRaw("date,Temp (\xb0)\n2020-01-01,3\n"))
  expect_equal(names(nm_read_table(f))[2], paste0("Temp (", intToUtf8(0xb0), ")"))
  f <- bytes_file(c(as.raw(c(0xc8, 0xd5, 0xc6, 0xda)), charToRaw(",x\n2020-01-01,3\n")))
  expect_equal(names(nm_read_table(f))[1], intToUtf8(c(0x65e5, 0x671f)))

  # Gzipped tabs, with Excel's byte-order mark.
  g <- tempfile(fileext = ".tsv.gz")
  con <- gzfile(g, "wb")
  writeBin(c(as.raw(c(0xef, 0xbb, 0xbf)),
             charToRaw("time\tpm25\n2020-01-01 00:00\t3.5\n2020-01-01 01:00\t4\n")), con)
  close(con)
  df <- nm_read_table(g)
  expect_equal(names(df), c("time", "pm25"))
  expect_equal(df$pm25, c(3.5, 4))
  expect_true(is.character(df$time))
  expect_equal(nm_find_dates(df)$date, utc(c("2020-01-01 00:00", "2020-01-01 01:00")))

  j <- tempfile(fileext = ".json")
  writeLines('[{"date": "2020-01-01", "x": 1}, {"date": "2020-01-02", "x": 2}]', j)
  expect_equal(nm_read_table(j)$x, c(1, 2))
  expect_true(".csv.gz" %in% nm_table_suffixes)
})

test_that("nm_find_dates finds the times however they are laid out", {
  parts <- data.frame(year = 2020, month = 1, day = c(1, 1), hour = c(0, 1), pm25 = c(3, 4))
  out <- nm_find_dates(parts)
  expect_equal(names(out), c("date", "pm25"))
  expect_equal(out$date, utc(c("2020-01-01 00:00", "2020-01-01 01:00")))
  expect_match(attr(out, "normet_dates"), "joined from year, month, day, hour")

  split <- data.frame(Date = c("2020-01-01", "2020-01-02"), time = c("13:00", "14:30"), x = 1:2)
  out <- nm_find_dates(split)
  expect_equal(out$date, utc(c("2020-01-01 13:00", "2020-01-02 14:30")))
  expect_equal(names(out), c("date", "x"))
  expect_match(attr(out, "normet_dates"), "hours from 'time'")

  unnamed <- data.frame(station = "MY1", when = c("2020-01-01 13:00", "2020-01-02 14:00"))
  expect_equal(nm_find_dates(unnamed)$date, utc(c("2020-01-01 13:00", "2020-01-02 14:00")))
  expect_error(nm_find_dates(data.frame(x = 1:3)), "No column of times")
})

test_that("nm_read_time_series puts offset times on the table's clock", {
  f <- tempfile(fileext = ".csv")
  writeLines(c("date,x", "2020-03-29T00:30+00:00,1", "2020-03-29T02:30+01:00,2"), f)
  out <- nm_read_time_series(f, zone = "Europe/London")
  expect_equal(out$date, utc(c("2020-03-29 00:30", "2020-03-29 02:30")))
  expect_equal(attr(out, "normet_zone"), "Europe/London")
  expect_match(attr(out, "normet_dates"), "UTC offsets put on Europe/London")
  out <- nm_read_time_series(f)
  expect_equal(out$date, utc(c("2020-03-29 00:30", "2020-03-29 01:30")))
})
