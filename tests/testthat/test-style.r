test_that("nm_formula writes formulas as chemistry does", {
  sub2 <- intToUtf8(0x2082)
  expect_equal(nm_formula("NO2"), paste0("NO", sub2))
  expect_equal(nm_formula("PM2.5"), paste0("PM", sub2, ".", intToUtf8(0x2085)))
  expect_equal(nm_formula("SO42-"), paste0("SO", intToUtf8(0x2084), intToUtf8(c(0xb2, 0x207b))))
  expect_equal(nm_formula("Ca2+"), paste0("Ca", intToUtf8(c(0xb2, 0x207a))))
  expect_equal(nm_formula("NH4+"), paste0("NH", intToUtf8(0x2084), intToUtf8(0x207a)))
  # What only reads as a formula is left as it is.
  expect_equal(nm_formula(c("CO", "NO", "ws", "blh", "OC1", "EC2", "S2", "atmos_pres", "MY1")),
               c("CO", "NO", "ws", "blh", "OC1", "EC2", "S2", "atmos_pres", "MY1"))
  expect_equal(nm_formula("O3 and PM10"),
               paste0("O", intToUtf8(0x2083), " and PM", intToUtf8(c(0x2081, 0x2080))))

  e <- nm_formula("Time series of NO2", as = "plotmath")
  expect_true(is.expression(e))
  expect_equal(deparse(e[[1]]), 'paste("Time series of ", N * O[2])')
  expect_equal(deparse(nm_formula("SO42-", as = "plotmath")[[1]]), 'S * O[4]^"2-"')
  expect_identical(nm_formula("ws", as = "plotmath"), "ws")
})

test_that(".break_at_gaps puts a row of NA in each gap", {
  t <- as.POSIXct("2020-01-01", tz = "UTC") + c(0:9, 30:39) * 3600
  df <- data.frame(date = t, y = 1:20, z = 1:20)
  out <- normet:::.break_at_gaps(df, "date", "y")
  expect_equal(nrow(out), 21)
  expect_equal(sum(is.na(out$y)), 1)
  expect_equal(out$z[is.na(out$y)], 10) # other columns are carried, not blanked
  expect_true(!is.unsorted(as.numeric(out$date)))
  # Evenly spaced: unchanged.
  expect_equal(nrow(normet:::.break_at_gaps(df[1:10, ], "date", "y")), 10)
})

test_that("nm_theme_normet is a ggplot2 theme with outward ticks and no legend frame", {
  skip_if_not_installed("ggplot2")
  th <- nm_theme_normet()
  expect_s3_class(th, "theme")
  expect_s3_class(th$legend.background, "element_blank")
  expect_equal(as.numeric(th$axis.ticks.length), 3)
})

test_that(".usable_cycles follows the record's step and span", {
  hourly <- as.POSIXct("2020-01-01", tz = "UTC") + (0:(24 * 90)) * 3600
  expect_equal(normet:::.usable_cycles(hourly), c("hour", "weekday", "month"))
  daily <- as.Date("2020-01-01") + 0:20
  expect_equal(normet:::.usable_cycles(daily), "weekday")
  monthly <- seq(as.Date("2018-01-01"), by = "month", length.out = 24)
  expect_equal(normet:::.usable_cycles(monthly), "month")
})

test_that("nm_cycle_profiles averages each series over its cycles", {
  skip_if_not_installed("ggplot2")
  df <- data.frame(date = as.POSIXct("2020-01-06", tz = "UTC") + (0:(24 * 14 - 1)) * 3600)
  df$x <- as.POSIXlt(df$date)$hour # the hour itself
  p <- nm_cycle_profiles(df, "x", cycles = c("hour", "weekday"))
  expect_s3_class(p, "ggplot")
  prof <- p$data
  hours <- prof[prof$cycle == "Hour of day", ]
  expect_equal(hours$mean, 0:23)
  expect_equal(hours$n, rep(14, 24))
  expect_equal(hours$low, hours$mean) # no spread within an hour
  days <- prof[prof$cycle == "Day of week", ]
  expect_equal(days$bin, 0:6)
  expect_equal(days$mean, rep(11.5, 7))
  expect_error(nm_cycle_profiles(df, "x", cycles = "season"), "Unknown cycle")
  expect_error(nm_cycle_profiles(df, "nope"), "not in df")
})

test_that("plots keep sub-daily times rather than collapsing them to days", {
  skip_if_not_installed("ggplot2")
  res <- data.frame(date = as.POSIXct("2020-01-01", tz = "UTC") + (0:47) * 3600,
                    observed = 1:48, normalised = 1:48)
  p <- nm_plot_normalise(res)
  expect_s3_class(p$data$date, "POSIXct")
  expect_equal(length(unique(p$data$date)), 48)
})

test_that("figures and the report speak Chinese when asked", {
  skip_if_not_installed("ggplot2")
  old <- options(normet.lang = "zh")
  on.exit(options(old))
  res <- data.frame(date = as.POSIXct("2020-01-01", tz = "UTC") + (0:47) * 3600,
                    observed = 1:48, normalised = 1:48)
  p <- nm_plot_normalise(res)
  expect_equal(p$labels$title, intToUtf8(c(0x89c2, 0x6d4b, 0x6d53, 0x5ea6, 0x4e0e, 0x5f52, 0x4e00,
                                           0x5316, 0x6d53, 0x5ea6)))
  options(normet.lang = "en")
  expect_equal(nm_plot_normalise(res)$labels$title, "Observed vs. Normalised concentration")
})

test_that("nm_generate_html writes the report in Chinese", {
  skip_if_not_installed("ggplot2")
  skip_if_not_installed("base64enc")
  run <- nm_make_run(
    result = data.frame(date = as.POSIXct("2020-01-01", tz = "UTC") + (0:47) * 3600,
                        observed = 1:48, normalised = 1:48),
    kind = "normalise"
  )
  f <- tempfile(fileext = ".html")
  nm_generate_html(run, f, lang = "zh")
  html <- paste(readLines(f, encoding = "UTF-8"), collapse = "\n")
  expect_match(html, '<html lang="zh">', fixed = TRUE)
  expect_match(html, intToUtf8(c(0x6eaf, 0x6e90, 0x4fe1, 0x606f)), fixed = TRUE) # Provenance
  expect_match(html, "data:image/png;base64", fixed = TRUE)
  expect_identical(getOption("normet.lang", "en"), "en") # the option is put back
  nm_generate_html(run, f)
  expect_match(paste(readLines(f), collapse = "\n"), "<h2>Provenance</h2>", fixed = TRUE)
})
