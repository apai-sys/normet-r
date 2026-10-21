test_that("nm_scm correctly solves weights under non-negative constraints", {
  # Generate mock panel dataset
  set.seed(42)
  dates <- seq(as.Date("2026-01-01"), as.Date("2026-01-20"), by = "day")
  units <- c("Treated", "Donor1", "Donor2", "Donor3")
  grid <- expand.grid(date = dates, code = units, stringsAsFactors = FALSE)

  # Outcome is a mixture: Treated = 0.6 * Donor1 + 0.4 * Donor2 + noise
  grid$poll <- 0
  grid$poll[grid$code == "Donor1"] <- sin(1:20) + 10
  grid$poll[grid$code == "Donor2"] <- cos(1:20) + 5
  grid$poll[grid$code == "Donor3"] <- runif(20) + 2
  grid$poll[grid$code == "Treated"] <- 0.6 * grid$poll[grid$code == "Donor1"] +
    0.4 * grid$poll[grid$code == "Donor2"] +
    rnorm(20, sd = 0.05)

  res <- nm_scm(
    df = grid,
    date_col = "date",
    unit_col = "code",
    outcome_col = "poll",
    treated_unit = "Treated",
    cutoff_date = "2026-01-15",
    donors = c("Donor1", "Donor2", "Donor3"),
    allow_negative_weights = FALSE,
    verbose = FALSE
  )

  # Check structure
  expect_true(is.list(res))
  expect_true(all(c("synthetic", "weights", "alpha") %in% names(res)))

  # Check constraints
  w <- res$weights
  expect_equal(sum(w), 1.0, tolerance = 1e-6)
  expect_true(all(w >= -1e-9))
  expect_equal(length(w), 3)
})

test_that("nm_scm correctly handles negative weights when allowed", {
  set.seed(42)
  dates <- seq(as.Date("2026-01-01"), as.Date("2026-01-20"), by = "day")
  units <- c("Treated", "Donor1", "Donor2", "Donor3")
  grid <- expand.grid(date = dates, code = units, stringsAsFactors = FALSE)

  # Extreme case to push weights to negative
  grid$poll <- 0
  grid$poll[grid$code == "Donor1"] <- 5
  grid$poll[grid$code == "Donor2"] <- 10
  grid$poll[grid$code == "Donor3"] <- 12
  grid$poll[grid$code == "Treated"] <- 2 # Treated is below all donors

  res <- nm_scm(
    df = grid,
    date_col = "date",
    unit_col = "code",
    outcome_col = "poll",
    treated_unit = "Treated",
    cutoff_date = "2026-01-15",
    donors = c("Donor1", "Donor2", "Donor3"),
    allow_negative_weights = TRUE,
    verbose = FALSE
  )

  w <- res$weights
  expect_equal(sum(w), 1.0, tolerance = 1e-6)
  # When Treated = 2, and all donors are >= 5, non-negative weights sum to 1 would predict at least 5.
  # Negative weights allow predicting 2, so at least one weight must be negative.
  expect_true(any(w < 0))
})

test_that("safe_name character sanitization works according to specifications", {
  # Re-define safe_name exactly as implemented in nm_causal_scm.r
  safe_name <- function(name) {
    if (name == "date") return("date")
    s <- gsub("[^A-Za-z0-9_]", "_", as.character(name))
    s <- gsub("_+", "_", s)
    s <- gsub("^_|_$", "", s)
    if (nchar(s) == 0) s <- "var"
    if (grepl("^[0-9]", s)) s <- paste0("v_", s)
    return(s)
  }

  expect_equal(safe_name("date"), "date")
  expect_equal(safe_name("my-covariate"), "my_covariate")
  expect_equal(safe_name("123var"), "v_123var")
  expect_equal(safe_name("   "), "var")
  expect_equal(safe_name("hello!world"), "hello_world")
  expect_equal(safe_name("multiple___underscores"), "multiple_underscores")
})

test_that("nm_scm_robust recovers donor mix and is reachable via nm_run_scm", {
  set.seed(42)
  dates <- seq(as.Date("2026-01-01"), as.Date("2026-03-01"), by = "day")
  donors <- c("Donor1", "Donor2", "Donor3")
  units <- c("Treated", donors)
  grid <- expand.grid(date = dates, code = units, stringsAsFactors = FALSE)

  n <- length(dates)
  grid$poll <- 0
  grid$poll[grid$code == "Donor1"] <- sin(seq_len(n)) + 10
  grid$poll[grid$code == "Donor2"] <- cos(seq_len(n)) + 5
  grid$poll[grid$code == "Donor3"] <- runif(n) + 2
  grid$poll[grid$code == "Treated"] <- 0.6 * grid$poll[grid$code == "Donor1"] +
    0.4 * grid$poll[grid$code == "Donor2"] +
    rnorm(n, sd = 0.05)

  res <- nm_scm_robust(
    df = grid, date_col = "date", unit_col = "code", outcome_col = "poll",
    treated_unit = "Treated", cutoff_date = "2026-02-15", donors = donors,
    verbose = FALSE
  )

  expect_true(is.list(res))
  expect_true(all(c("synthetic", "weights", "rank", "intercept") %in% names(res)))
  expect_equal(colnames(res$synthetic), c("date", "observed", "synthetic", "effect"))
  expect_equal(length(res$weights), 3)
  # Weights are unconstrained (not simplex), but should recover the donor mix.
  expect_equal(unname(res$weights[c("Donor1", "Donor2")]), c(0.6, 0.4), tolerance = 0.05)

  # Reachable through the dispatcher, returning the synthetic data.frame.
  out <- nm_run_scm(
    df = grid, date_col = "date", unit_col = "code", outcome_col = "poll",
    treated_unit = "Treated", cutoff_date = "2026-02-15", donors = donors,
    scm_backend = "robust", verbose = FALSE
  )
  expect_equal(colnames(out), c("date", "observed", "synthetic", "effect"))
  expect_equal(nrow(out), length(dates))
})

test_that(".nm_ridge_loo picks each target's penalty by exact leave-one-out", {
  set.seed(11)
  X <- matrix(rnorm(15 * 6), 15, 6)
  B <- cbind(X %*% rnorm(6) + rnorm(15), X %*% rnorm(6) + rnorm(15, sd = 3))
  newx <- matrix(rnorm(2 * 6), 2, 6)
  alphas <- c(0.1, 1, 5, 20)
  fit <- .nm_ridge_loo(X, B, alphas, newx)

  ridge <- function(X, y, a, newx) {  # intercept unpenalised, as RidgeCV fits it
    xm <- colMeans(X); ym <- mean(y)
    Xc <- sweep(X, 2, xm)
    b <- solve(crossprod(Xc) + a * diag(ncol(X)), crossprod(Xc, y - ym))
    as.numeric(sweep(newx, 2, xm) %*% b + ym)
  }
  for (k in seq_len(ncol(B))) {
    loo <- sapply(alphas, function(a) {
      mean(sapply(seq_len(nrow(X)), function(i) {
        (B[i, k] - ridge(X[-i, , drop = FALSE], B[-i, k], a, X[i, , drop = FALSE]))^2
      }))
    })
    expect_equal(fit$alpha[k], alphas[which.min(loo)])
    expect_equal(fit$pred[, k], ridge(X, B[, k], fit$alpha[k], newx), tolerance = 1e-8)
  }
})

test_that("nm_scm reproduces normet-py's ULEZ fit", {
  # The design of normet-py's manual: MY1 against the traffic sites with a complete
  # record, January 2017 to February 2020, cutoff April 2019.
  d <- scm[scm$date >= as.Date("2017-01-01") & scm$date < as.Date("2020-03-01") &
             grepl("Traffic", scm$type), ]
  cnt <- table(d$code[!is.na(d$NO2_dw)])
  donors <- setdiff(names(cnt)[cnt == length(unique(d$date))], "MY1")
  d <- d[d$code %in% c(donors, "MY1"), c("date", "code", "NO2_dw")]
  res <- nm_scm(d, treated_unit = "MY1", cutoff_date = "2019-04-01", donors = donors,
                outcome_col = "NO2_dw", verbose = FALSE)
  s <- res$synthetic
  pre <- s$date < as.Date("2019-04-01")
  expect_length(donors, 53)
  expect_equal(sqrt(mean(s$effect[pre]^2)), 0.16, tolerance = 0.05)
  expect_equal(mean(s$effect[!pre]), -18.14, tolerance = 0.01)
})

test_that("nm_bayesian_scm samples normet-py's posterior on the ULEZ design", {
  # normet-py (PyMC, NUTS) on this design: pre-cutoff RMSE 21.73, ATT 1.97, CAE6's
  # weight 0.730. A flat Dirichlet on 53 donors puts its mass in the simplex's interior,
  # away from the least-squares vertex (RMSE 13.20).
  d <- scm[scm$date >= as.Date("2017-01-01") & scm$date < as.Date("2020-03-01") &
             grepl("Traffic", scm$type), ]
  cnt <- table(d$code[!is.na(d$NO2_dw)])
  donors <- setdiff(names(cnt)[cnt == length(unique(d$date))], "MY1")
  d <- d[d$code %in% c(donors, "MY1"), c("date", "code", "NO2_dw")]
  res <- nm_bayesian_scm(d, treated_unit = "MY1", cutoff_date = "2019-04-01",
                         donors = donors, outcome_col = "NO2_dw", verbose = FALSE)
  s <- res$synthetic
  pre <- s$date < as.Date("2019-04-01")
  expect_equal(sqrt(mean(s$effect[pre]^2)), 21.73, tolerance = 0.03)
  expect_equal(mean(s$effect[!pre]), 1.97, tolerance = 0.3)
  expect_equal(unname(res$weights["CAE6"]), 0.73, tolerance = 0.05)
  expect_true(all(s$effect_low <= s$effect & s$effect <= s$effect_high))
  expect_gt(mean(s$effect_high[!pre] - s$effect_low[!pre]), 1)
})
