# Placebo-in-time picks its fake cutoffs as normet-py does.

make_panel <- function(n_dates = 40) {
  set.seed(1)
  dates <- seq(as.Date("2020-01-01"), by = "day", length.out = n_dates)
  units <- c("T", paste0("D", 1:5))
  grid <- expand.grid(date = dates, code = units, stringsAsFactors = FALSE)
  base <- 10 + sin(seq_len(n_dates) / 3)
  grid$poll <- base[match(grid$date, dates)] + rnorm(nrow(grid), 0, 0.3) +
    as.integer(factor(grid$code)) * 0.5
  grid
}

test_that("nm_placebo_in_time leaves min_pre_period dates before each fake cutoff", {
  df <- make_panel()
  dates <- sort(unique(df$date))
  # Cutoff at the 31st date: 30 pre, 10 post. normet-py's range(5, 30) with the
  # post-period ending before the cutoff gives i = 5..20 (from 0): 16 cutoffs, the
  # first the 6th date.
  res <- nm_placebo_in_time(df, treated_unit = "T", cutoff_date = dates[31],
                            min_pre_period = 5, placebo_every = 1,
                            n_cores = 1, verbose = FALSE)
  keys <- as.Date(names(res$placebos))
  expect_length(keys, 16)
  expect_equal(min(keys), dates[6])
  expect_equal(max(keys), dates[21])
})

test_that("nm_placebo_in_time finds no cutoff when the pre-period is too short", {
  df <- make_panel()
  dates <- sort(unique(df$date))
  res <- nm_placebo_in_time(df, treated_unit = "T", cutoff_date = dates[31],
                            min_pre_period = 35, n_cores = 1, verbose = FALSE)
  expect_length(res$placebos, 0)
  expect_true(is.na(res$p_value))
})
