library(normet)

# ---- helpers ---------------------------------------------------------------

.make_panel <- function(n_pre = 15, n_post = 5, n_donors = 3, seed = 42) {
  set.seed(seed)
  dates  <- seq(as.Date("2026-01-01"), by = "day", length.out = n_pre + n_post)
  units  <- c("Treated", paste0("Donor", seq_len(n_donors)))
  grid   <- expand.grid(date = dates, code = units, stringsAsFactors = FALSE)
  grid$poll <- rnorm(nrow(grid), mean = 10, sd = 1)
  grid
}

.make_scm_result <- function(effect_post = 2, n_pre = 20, n_post = 10) {
  dates  <- seq(as.Date("2026-01-01"), by = "day", length.out = n_pre + n_post)
  effect <- c(rnorm(n_pre, 0, 0.3), rep(effect_post, n_post))
  data.frame(date = dates, observed = 10 + effect, synthetic = 10, effect = effect)
}

# ---- nm_conformal_effect_interval ------------------------------------------

test_that("conformal interval returns correct structure", {
  res_df <- .make_scm_result(effect_post = 3)
  out <- nm_conformal_effect_interval(res_df, cutoff_date = "2026-01-21",
                                      n_perm = 200, random_state = 1)
  expect_named(out, c("att", "low", "high", "p_value", "n_post", "n_perm"))
  expect_true(is.numeric(out$att))
  expect_true(out$low <= out$att)
  expect_true(out$high >= out$att)
  expect_true(out$p_value >= 0 & out$p_value <= 1)
  expect_equal(out$n_post, 10L)
})

test_that("conformal interval detects large true effect (p < 0.1)", {
  res_df <- .make_scm_result(effect_post = 5, n_pre = 30, n_post = 10)
  out <- nm_conformal_effect_interval(res_df, cutoff_date = "2026-01-31",
                                      n_perm = 500, random_state = 7)
  expect_lt(out$p_value, 0.1)
})

test_that("conformal interval wraps list input (synthetic key)", {
  res_df  <- .make_scm_result()
  res_lst <- list(synthetic = res_df)
  out1 <- nm_conformal_effect_interval(res_df,  "2026-01-21", n_perm = 100, random_state = 1)
  out2 <- nm_conformal_effect_interval(res_lst, "2026-01-21", n_perm = 100, random_state = 1)
  expect_equal(out1$att, out2$att)
})

test_that("conformal interval errors on missing post-period", {
  res_df <- .make_scm_result(n_pre = 20, n_post = 5)
  expect_error(
    nm_conformal_effect_interval(res_df, cutoff_date = "2030-01-01"),
    "No post-period"
  )
})

# ---- nm_rmspe_ratio_test ---------------------------------------------------

.make_placebo_space <- function(treated_ratio = 3, n_donors = 5) {
  dates     <- seq(as.Date("2026-01-01"), by = "day", length.out = 30)
  cutoff    <- as.Date("2026-01-16")
  pre_mask  <- dates < cutoff
  post_mask <- !pre_mask

  make_eff <- function(ratio) {
    eff <- numeric(30)
    eff[pre_mask]  <- rnorm(sum(pre_mask),  0, 1)
    eff[post_mask] <- rnorm(sum(post_mask), 0, ratio)
    setNames(eff, as.character(dates))
  }

  treated_eff <- make_eff(treated_ratio)
  treated_df  <- data.frame(date = dates, effect = treated_eff)
  placebos <- lapply(seq_len(n_donors), function(i) {
    e <- make_eff(runif(1, 0.5, 1.5))
    data.frame(date = dates, effect = e)
  })
  names(placebos) <- paste0("Donor", seq_len(n_donors))
  list(treated = treated_df, placebos = placebos)
}

test_that("rmspe_ratio_test returns correct structure", {
  pbo <- .make_placebo_space()
  out <- nm_rmspe_ratio_test(pbo, "2026-01-16")
  expect_named(out, c("treated_ratio", "placebo_ratios", "p_value", "rank"))
  expect_true(is.numeric(out$treated_ratio))
  expect_true(is.numeric(out$p_value))
  expect_true(out$p_value >= 0 & out$p_value <= 1)
})

test_that("rmspe_ratio_test gives low p-value for clearly large treated ratio", {
  set.seed(42)
  pbo <- .make_placebo_space(treated_ratio = 10, n_donors = 20)
  out <- nm_rmspe_ratio_test(pbo, "2026-01-16")
  expect_lt(out$p_value, 0.15)
})

test_that("rmspe_ratio_test errors without treated key", {
  expect_error(nm_rmspe_ratio_test(list(placebos = list()), "2026-01-16"),
               "must contain 'treated'")
})

# ---- SCM variants ----------------------------------------------------------

test_that("nm_scm_abadie returns valid structure and sum-to-one weights", {
  grid <- .make_panel()
  out  <- nm_scm_abadie(grid, treated_unit = "Treated", cutoff_date = "2026-01-16")
  expect_named(out, c("synthetic", "weights"))
  expect_true(all(c("date", "observed", "synthetic", "effect") %in% colnames(out$synthetic)))
  expect_equal(sum(out$weights), 1, tolerance = 1e-5)
  expect_true(all(out$weights >= -1e-6))
})

test_that("nm_did_baseline returns plausible counterfactual", {
  grid <- .make_panel()
  out  <- nm_did_baseline(grid, treated_unit = "Treated", cutoff_date = "2026-01-16")
  expect_true("effect" %in% colnames(out$synthetic))
  expect_equal(sum(out$weights), 1, tolerance = 1e-5)
})

test_that("nm_scm_mcnnm returns synthetic column", {
  grid <- .make_panel()
  out  <- nm_scm_mcnnm(grid, treated_unit = "Treated", cutoff_date = "2026-01-16",
                        max_iter = 50)
  expect_true("synthetic" %in% names(out))
  expect_true("effect" %in% colnames(out$synthetic))
})

# ---- cache utilities -------------------------------------------------------

test_that("nm_cache_save and nm_cache_load roundtrip", {
  tmp  <- tempdir()
  key  <- "test_key_abc123"
  data <- list(x = 1:5, y = "hello")
  nm_cache_save(tmp, key, data)
  result <- nm_cache_load(tmp, key)
  expect_equal(result$x, data$x)
  expect_equal(result$y, data$y)
})

test_that("nm_cache_load returns NULL on miss", {
  expect_null(nm_cache_load(tempdir(), "nonexistent_key_xyz"))
})

test_that("nm_detect_backend identifies lightgbm by attribute", {
  m <- structure(list(), backend = "lightgbm")
  attr(m, "backend") <- "lightgbm"
  expect_equal(nm_detect_backend(m), "lightgbm")
})
