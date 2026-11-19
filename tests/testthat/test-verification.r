# Probabilistic scoring: nm_pinball_loss, nm_crps_from_quantiles,
# nm_crps_from_samples, nm_crps_observed. Every value is pinned to the reference
# computed by normet-py on the same fixture files (the CRPS math is
# deterministic, so R and py agree to the last digit).

test_that("the pinball loss matches the reference", {
  po <- read.csv(test_path("ver_po.csv"))
  expect_equal(nm_pinball_loss(po$p, po$o, 0.5), 5.562003138618371e-01, tolerance = 1e-12)
  expect_equal(nm_pinball_loss(po$p, po$o, 0.1), 5.868571246514594e-01, tolerance = 1e-12)
  # q = 1/2 is half the MAE, so it brackets the reference from both sides.
  mae <- mean(abs(po$p - po$o))
  expect_equal(nm_pinball_loss(po$p, po$o, 0.5), mae / 2, tolerance = 1e-12)
  # A non-finite row is dropped, and the mean is over the rows that remain.
  p <- po$p; p[4] <- NA
  o <- po$o; o[8] <- Inf
  expect_equal(nm_pinball_loss(p, o, 0.3), 5.738077693855442e-01, tolerance = 1e-12)
  expect_error(nm_pinball_loss(po$p, head(po$o, 199), 0.5), "199")
})

test_that("the CRPS from quantiles matches the reference (named and qNNN levels)", {
  q <- read.csv(test_path("ver_q.csv"))
  obs <- read.csv(test_path("ver_obs.csv"))$obs
  levs <- c(0.0125, 0.05, 0.2, 0.3, 0.5, 0.7, 0.8, 0.95, 0.9875)
  names(q) <- as.character(levs)
  expect_equal(
    nm_crps_from_quantiles(q, obs, quantiles = names(q)),
    6.473120103036230e-01, tolerance = 1e-12
  )
  # qNNN-named columns carry their level in the name: q050 is the 5 % level.
  q2 <- q
  names(q2) <- paste0("q", sprintf("%03d", round(levs * 1000)))
  v2 <- nm_crps_from_quantiles(q2, obs)
  expect_true(is.finite(v2))
  # The levels are the rounded ones (0.012, not 0.0125), so the value moves a
  # little -- the mechanism, not the reference, is what is pinned here.
  expect_true(abs(v2 - 6.473120103036230e-01) < 1e-2)
  expect_error(nm_crps_from_quantiles(q2[, 1:2], obs, quantiles = c("q012", "q012")),
               "The quantile levels repeat.")
  expect_error(nm_crps_from_quantiles(q2, obs, quantiles = "q999"), "No such column")
})

test_that("the one-level guard says the point prediction is not a quantile array", {
  po <- read.csv(test_path("ver_po.csv"))
  expect_error(nm_crps_from_quantiles(po$p, po$o),
               "One level is a point prediction: score it with nm_crps_observed.")
})

test_that("the CRPS from samples matches the reference (frame and matrix alike)", {
  s <- read.csv(test_path("ver_s.csv"))
  obs <- read.csv(test_path("ver_obs2.csv"))$obs
  expect_equal(nm_crps_from_samples(s, obs), 5.421042140911965e-01, tolerance = 1e-12)
  # The matrix path sorts the same rows: the value does not depend on the shape.
  expect_equal(nm_crps_from_samples(as.matrix(s), obs), 5.421042140911965e-01, tolerance = 1e-12)
  # A single sample is a point prediction, not an ensemble.
  expect_error(nm_crps_from_samples(s[, 1, drop = FALSE], obs),
               "One sample is a point prediction: score it with nm_crps_observed.")
  # Rows with a non-finite observation are dropped before scoring.
  p <- s
  p[3, ] <- NA
  expect_true(is.finite(nm_crps_from_samples(p, obs)))
})

test_that("the CRPS of the observations matches the reference", {
  po <- read.csv(test_path("ver_po.csv"))
  expect_equal(nm_crps_observed(po$p, po$o), 1.394187433084717e+00, tolerance = 1e-12)
  # No spread at all is a score of zero, not an error.
  expect_equal(nm_crps_observed(rep(1, 200), rep(1, 200)), 0)
  expect_error(nm_crps_observed(po$p, head(po$o, 199)), "199")
  expect_error(nm_crps_observed(rep(NA, 200), rep(NA, 200)), "Nothing to score")
})
