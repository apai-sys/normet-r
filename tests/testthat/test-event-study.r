# Mirrors normet-py's test_bands.py event-study tests (PR #62).

# 20 daily points before the cutoff, 10 after, with a +3 level shift and a
# little pre-period scatter well clear of the jump.
.es_frame <- function() {
  idx <- seq(as.Date("2023-01-01"), by = "day", length.out = 30)
  effect <- c(rep(0, 20), rep(3, 10))
  effect[seq(1, 20, by = 3)] <- 0.5
  data.frame(date = idx, effect = effect)
}

# The built data of the first layer of the given geom ("Line", "Point", "Ribbon").
.es_layer <- function(p, geom) {
  built <- ggplot2::ggplot_build(p)
  kinds <- vapply(p$layers, function(l) sub("^Geom", "", class(l$geom)[1]), character(1))
  i <- which(kinds == geom)[1]
  expect_false(is.na(i), info = paste("no", geom, "layer"))
  built$data[[i]]
}

.es_kinds <- function(p) vapply(p$layers, function(l) sub("^Geom", "", class(l$geom)[1]), character(1))

test_that("nm_plot_event_study splits the periods by event time", {
  p <- nm_plot_event_study(.es_frame(), "2023-01-21")
  kinds <- .es_kinds(p)
  # No band given: the two series and the two reference lines, nothing else drawn.
  expect_setequal(kinds, c("Line", "Point", "Hline", "Vline"))

  line <- .es_layer(p, "Line")
  pre <- line[line$x < 0, ]
  post <- line[line$x >= 0, ]
  expect_equal(nrow(pre), 20)
  expect_equal(nrow(post), 10)
  # Event time is a period count: pre runs -20..-1, post starts at 0.
  expect_equal(range(pre$x), c(-20, -1))
  expect_equal(range(post$x), c(0, 9))
  # The shift shows up where it was injected.
  expect_equal(post$y, rep(3, 10))
  expect_equal(head(line$y, 3), c(0.5, 0, 0))
})

test_that("nm_plot_event_study band starts at the cutoff", {
  band <- data.frame(p10 = rep(1, 10), p90 = rep(5, 10),
                     ci_lo = rep(0.5, 10), ci_hi = rep(5.5, 10))
  p <- nm_plot_event_study(list(treated = .es_frame()), "2023-01-21", band = band)
  ribbon <- .es_layer(p, "Ribbon")
  # ci_lo/ci_hi win over p10/p90 when both are present, and the band covers
  # only the post-period: x runs from event time 0 to 9.
  expect_equal(range(ribbon$x), c(0, 9))
  expect_equal(min(ribbon$ymin), 0.5)
  expect_equal(max(ribbon$ymax), 5.5)
})

test_that("nm_plot_event_study aligns a date-carrying band", {
  # A date-carrying band spans the whole window; only its post rows are drawn.
  band <- data.frame(date = .es_frame()$date, lower = 1, upper = 2)
  p <- nm_plot_event_study(.es_frame(), "2023-01-21", band = band)
  ribbon <- .es_layer(p, "Ribbon")
  expect_equal(range(ribbon$x), c(0, 9))
  expect_equal(unique(ribbon$ymin), 1)
})

test_that("nm_plot_event_study rejects bad input", {
  expect_error(nm_plot_event_study(data.frame(observed = 1), "2023-01-01"), "effect")
  expect_error(nm_plot_event_study(data.frame(effect = c(1, 2)), "2023-01-01"), "date")
  expect_error(
    nm_plot_event_study(.es_frame(), "2023-01-21", band = data.frame(low = 1)),
    "ci_lo"
  )
  expect_error(
    nm_plot_event_study(.es_frame(), "2023-01-21",
                        band = data.frame(date = as.Date("2020-01-01"), low = 1, high = 2)),
    "cover the post-period"
  )
})
