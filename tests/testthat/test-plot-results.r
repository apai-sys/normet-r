# Synthetic results shaped as nm_decompose's and nm_rolling's, so no model is trained.
.hours <- function(n) as.POSIXct("2020-01-01", tz = "UTC") + (seq_len(n) - 1) * 3600

test_that("a decomposition's stack leaves out the total its parts add up to", {
  set.seed(1)
  n <- 48
  emi <- data.frame(date = .hours(n), observed = rnorm(n, 50), emi_base = 30,
                    date_unix = rnorm(n), day_julian = rnorm(n), weekday = rnorm(n),
                    hour = rnorm(n), emi_noise = rnorm(n))
  emi$emi_total <- rowSums(emi[c("emi_base", "date_unix", "day_julian", "weekday", "hour",
                                 "emi_noise")])
  stacked <- levels(ggplot2::ggplot_build(nm_plot_decomposition_stack(emi))$plot$data$variable)
  expect_false("emi_total" %in% stacked)
  expect_setequal(stacked, c("emi_base", "date_unix", "day_julian", "weekday", "hour", "emi_noise"))

  met <- data.frame(date = .hours(n), emi_total = rnorm(n, 40), ws = rnorm(n), temp = rnorm(n),
                    met_base = 1, met_noise = rnorm(n))
  met$met_total <- rowSums(met[c("ws", "temp", "met_base", "met_noise")])
  met$observed <- met$emi_total + met$met_total
  stacked <- levels(nm_plot_decomposition_stack(met)$data$variable)
  expect_setequal(stacked, c("emi_total", "ws", "temp", "met_base", "met_noise"))
  # Asked for, a column is still left out as it is told.
  stacked <- levels(nm_plot_decomposition_stack(met, exclude = c("observed", "ws"))$data$variable)
  expect_true(all(c("met_total", "emi_total") %in% stacked))
  expect_false("ws" %in% stacked)
})

test_that("nm_plot_rolling draws the windows' mean, their spread and the observed series", {
  n <- 72
  rolled <- data.frame(date = .hours(n),
                       window_01 = c(1:48, rep(NA, 24)),
                       window_02 = c(rep(NA, 24), 1:48 + 2))
  df_prep <- data.frame(date = .hours(n), value = seq_len(n) * 1.5)
  p <- nm_plot_rolling(rolled, data = df_prep)
  expect_s3_class(p, "ggplot")
  d <- p$data[!is.na(p$data$date), ]
  expect_equal(d$rolling_mean[1], 1)             # one window: its own value
  expect_true(is.na(d$band_low[1]))              # and no spread
  expect_equal(d$rolling_mean[30], (30 + 6 + 2) / 2)
  expect_false(is.na(d$band_low[30]))            # two overlap: a band
  expect_equal(d$observed, df_prep$value)
  expect_equal(p$labels$title, "Rolling normalisation — mean of 2 windows")
  expect_no_error(ggplot2::ggplot_build(p))
  # Without the table: no observed series, the windows still drawn.
  expect_false("observed" %in% colnames(nm_plot_rolling(rolled)$data))
  expect_error(nm_plot_rolling(data.frame(date = .hours(3), x = 1:3)), "window")

  old <- options(normet.lang = "zh")
  on.exit(options(old))
  expect_equal(nm_plot_rolling(rolled)$labels$title,
               "滚动归一化——2 个窗口的均值")
})
