# Uncertainty decomposition (nm_decompose_uncertainty): the two-way orthogonal
# split of the model-by-draw matrix. The math is pinned twice -- against the
# additivity identity it rests on and against a per-timestamp reference computed
# the long way -- and the full pipeline is checked on one small lightgbm run.

test_that("the two-way split is orthogonal and exact", {
  set.seed(1)
  I <- 3; J <- 4; T <- 5
  z <- array(rnorm(I * J * T), dim = c(I, J, T))
  d <- .nm_unc_decompose(z)
  # The total is the three summands, to floating point: the identity the
  # attribution rests on.
  expect_equal(d$var_total, d$var_weather + d$var_model + d$var_interaction,
               tolerance = 1e-14)
  # Every term is a sum of squares: non-negative.
  expect_true(all(d$var_weather >= -1e-12))
  expect_true(all(d$var_model >= -1e-12))
  expect_true(all(d$var_interaction >= -1e-12))
  # Against the per-timestamp reference, the long way: the main effect of each
  # factor about the grand mean, and the interaction what the two leave out.
  ref <- vapply(seq_len(T), function(t) {
    zz <- z[, , t]
    g <- mean(zz)
    pm <- rowMeans(zz)
    pd <- colMeans(zz)
    inter <- zz - (matrix(rep(pm, times = J), nrow = I, ncol = J) +
                     matrix(rep(pd, each = I), nrow = I, ncol = J) - g)
    c(var_model = mean((pm - g)^2), var_weather = mean((pd - g)^2),
      var_interaction = mean(inter^2), var_total = mean((zz - g)^2))
  }, numeric(4))
  expect_equal(d$var_model, ref["var_model", ], tolerance = 1e-12)
  expect_equal(d$var_weather, ref["var_weather", ], tolerance = 1e-12)
  expect_equal(d$var_interaction, ref["var_interaction", ], tolerance = 1e-12)
  expect_equal(d$var_total, ref["var_total", ], tolerance = 1e-12)
})

test_that("a vanishing factor takes its main effect and the interaction to zero", {
  set.seed(1)
  I <- 3; J <- 4; T <- 5
  z <- array(rnorm(I * J * T), dim = c(I, J, T))
  # Identical draws: nothing varies with the weather.
  zd <- z
  for (j in seq_len(J)) zd[, j, ] <- z[, 1, , drop = FALSE]
  dd <- .nm_unc_decompose(zd)
  expect_true(max(abs(dd$var_weather)) < 1e-12)
  expect_true(max(abs(dd$var_interaction)) < 1e-12)
  # Identical members: nothing varies with the model form.
  zm <- z
  for (i in seq_len(I)) zm[i, , ] <- z[1, , , drop = FALSE]
  dm <- .nm_unc_decompose(zm)
  expect_true(max(abs(dm$var_model)) < 1e-12)
  expect_true(max(abs(dm$var_interaction)) < 1e-12)
})

test_that("the result object carries the record and the run's provenance", {
  fake <- structure(list(
    var_weather = c(1, 2, 3), var_model = c(0.5, 0.25, 1),
    var_interaction = c(0.1, 0.1, 0.2), var_total = c(1.6, 2.35, 4.2),
    date = as.POSIXct(c("2024-01-01", "2024-01-02", "2024-01-03"), tz = "UTC"),
    target = "NO2", n_models = 2L, n_weather_draws = 5L,
    seed = 7654321L, notes = c("note one", "note two")
  ), class = "nm_unc_decomposition")
  # print(): the one-line median spread shares, as py's __str__ writes them.
  expect_match(capture.output(print(fake)),
               "NO2: 3 dates, 2 models x 5 met draws", fixed = TRUE)
  # summary(): the four sources, the total's share exactly 1.
  s <- summary(fake)
  expect_equal(s$source, c("weather", "model", "interaction", "total"))
  expect_equal(s$pct_median[4], 1.0)
  expect_equal(s$var_median, c(2, 0.5, 0.1, 2.35))
  # as.data.frame(): the per-date rows, each source's share of the total.
  df <- as.data.frame(fake)
  expect_equal(nrow(df), 3)
  expect_equal(df$var_total, c(1.6, 2.35, 4.2))
  expect_equal(df$pct_weather + df$pct_model + df$pct_interaction,
               rep(1, 3), tolerance = 1e-12)
  # plot(): a ggplot that stacks the three sources under the total line.
  p <- plot(fake)
  expect_s3_class(p, "ggplot")
})

test_that("the guards refuse a degenerate run", {
  df <- data.frame(
    date = as.POSIXct("2024-01-01", tz = "UTC") + (0:99) * 3600,
    y = rnorm(100), x = rnorm(100)
  )
  expect_error(nm_decompose_uncertainty(df, "y", "lightgbm", "x", n_samples = 1),
               "n_samples.*at least 2")
  expect_error(nm_decompose_uncertainty(df, "y", "lightgbm", "x", n_models = 1),
               "n_models.*at least 2")
  expect_error(nm_decompose_uncertainty(df, "y", "lightgbm"), "covariates")
  expect_error(nm_decompose_uncertainty(df, "y", "no-such-backend", "x"), "Unknown backend")
})

test_that("the lightgbm pipeline decomposes a small run additively", {
  skip_if_not_installed("lightgbm")
  data(my1, package = "normet")
  covs <- setdiff(names(my1), c("date", "NO2"))
  res <- nm_decompose_uncertainty(
    my1[1:600, ], target = "NO2", covariates = covs,
    n_models = 2, n_samples = 20,
    model_config = list(n_trials = 5, nrounds = 300)
  )
  expect_equal(length(res$date), 600)
  expect_equal(res$n_models, 2L)
  expect_equal(res$n_weather_draws, 20L)
  expect_equal(res$seed, 7654321L)
  # The additivity the attribution rests on, on real predictions.
  expect_equal(res$var_total,
               res$var_weather + res$var_model + res$var_interaction,
               tolerance = 1e-10)
  # Every source is non-negative, and the shares read back to the medians.
  expect_true(all(res$var_weather >= 0, res$var_model >= 0, res$var_interaction >= 0))
  s <- summary(res)
  expect_equal(s$pct_median[4], 1.0)
  expect_true(all(s$var_median >= 0))
  # The record's weather factor dominates on this short slice: the model-form
  # term of a two-member, five-trial ensemble is small by construction.
  expect_true(s$var_median[1] > s$var_median[2])
})
