# nm_decom_met attribution (sequential vs Shapley, groups) and resample pools.
# Mirrors normet-py's tests/test_decomposition_attribution.py and
# tests/test_normalise_pools.py.
#
# A known coalition game stands in for the model: nm_normalise() is replaced by
# a function whose "normalised" series depends only on which features are held
# at their observed values -- three main effects plus an a-b interaction that
# only appears when both a and b are held. Sequential freezing credits the
# interaction to whichever of a and b comes second; Shapley splits it evenly.

N <- 48
TT <- 0:(N - 1)
MAIN <- list(a = sin(TT / 5), b = 0.5 * cos(TT / 3), c = 0.1 * TT)
AB <- 0.3 + 0.2 * sin(TT / 7)
T0 <- as.POSIXct("2024-01-01", tz = "UTC")
FEATS <- c("a", "b", "c", "hour")

game <- function(fixed, rows = seq_len(N)) {
  out <- rep(10, length(rows))
  for (f in fixed) out <- out + MAIN[[f]][rows]
  if (all(c("a", "b") %in% fixed)) out <- out + AB[rows]
  out
}

frame <- function() {
  data.frame(date = T0 + 3600 * TT, value = 12 + cos(TT / 4),
             a = 1, b = 2, c = 3, hour = TT %% 24)
}

# Replace nm_normalise with the game and nm_extract_features with a fixed
# importance order; record every nm_normalise call.
use_game <- function(order = FEATS, env = parent.frame()) {
  calls <- new.env(parent = emptyenv())
  calls$args <- list()
  local_mocked_bindings(
    nm_normalise = function(df, model, resample_vars = NULL, ...) {
      calls$args[[length(calls$args) + 1L]] <- c(list(resample = sort(resample_vars)), list(...))
      fixed <- setdiff(names(MAIN), resample_vars)
      rows <- as.integer(round(as.numeric(difftime(df$date, T0, units = "hours")))) + 1L
      data.frame(date = df$date, observed = df$value, normalised = game(fixed, rows))
    },
    nm_extract_features = function(model, importance_ascending = FALSE, ...) {
      if (importance_ascending) rev(order) else order
    },
    .env = env
  )
  calls
}

decom <- function(...) {
  nm_decom_met(frame(), model = list(), n_samples = 2, n_cores = 1, verbose = FALSE, ...)
}

expect_closes <- function(res, cols) {
  everything <- game(c("a", "b", "c"))
  expect_equal(rowSums(res[, cols, drop = FALSE]), everything - res$emi_total, tolerance = 1e-12)
  expect_equal(res$met_noise, (res$observed - everything) - res$met_base, tolerance = 1e-12)
}

# ------------------------------------------------------------------ sequential

test_that("sequential is the default and credits the interaction to the later feature", {
  calls <- use_game()
  res <- decom()

  expect_equal(colnames(res), c("date", "observed", "emi_total", "a", "b", "c",
                                "met_total", "met_base", "met_noise"))
  expect_equal(res$emi_total, rep(10, N))
  expect_equal(res$a, MAIN$a)
  expect_equal(res$b, MAIN$b + AB)
  expect_equal(res$c, MAIN$c)
  expect_closes(res, c("a", "b", "c"))
  expect_equal(lapply(calls$args, `[[`, "resample"),
               list(c("a", "b", "c"), c("b", "c"), "c", character(0)))
})

test_that("the sequential split moves with the order", {
  use_game()
  res <- decom(variable_order = c("b", "a", "c"))
  expect_equal(res$a, MAIN$a + AB)
  expect_equal(res$b, MAIN$b)
})

# --------------------------------------------------------------------- shapley

test_that("Shapley splits the interaction evenly, from all 2^k coalitions", {
  calls <- use_game()
  res <- decom(attribution = "shapley")

  expect_equal(res$a, MAIN$a + AB / 2)
  expect_equal(res$b, MAIN$b + AB / 2)
  expect_equal(res$c, MAIN$c)
  expect_closes(res, c("a", "b", "c"))
  expect_length(calls$args, 8)
})

test_that("Shapley does not depend on importance", {
  use_game()
  first <- decom(attribution = "shapley")
  use_game(order = c("c", "b", "a", "hour"))
  reordered <- decom(attribution = "shapley")
  expect_equal(first[, c("a", "b", "c")], reordered[, c("a", "b", "c")])
})

test_that("sampled Shapley is exact for pairwise games and cheaper", {
  # An order and its reverse flip every pair, so one antithetic pair already
  # splits a pairwise interaction evenly -- using 6 of the 8 coalitions.
  calls <- use_game()
  res <- decom(attribution = "shapley", n_permutations = 2)
  expect_equal(res$a, MAIN$a + AB / 2)
  expect_equal(res$b, MAIN$b + AB / 2)
  expect_closes(res, c("a", "b", "c"))
  expect_length(calls$args, 6)
})

test_that("a sampling budget covering every coalition computes the exact values", {
  calls <- use_game()
  decom(attribution = "shapley", n_permutations = 4)
  expect_length(calls$args, 8)
})

# ---------------------------------------------------------------------- groups

test_that("groups default to Shapley over the groups", {
  calls <- use_game()
  res <- decom(groups = list(g1 = "a", g2 = c("b", "c")))

  expect_equal(colnames(res), c("date", "observed", "emi_total", "g1", "g2",
                                "met_total", "met_base", "met_noise"))
  expect_equal(res$g1, MAIN$a + AB / 2)
  expect_equal(res$g2, MAIN$b + MAIN$c + AB / 2)
  expect_closes(res, c("g1", "g2"))
  expect_length(calls$args, 4)
})

test_that("a group carries the interactions inside it", {
  use_game()
  res <- decom(groups = list(ab = c("a", "b"), rest = "c"))
  expect_equal(res$ab, MAIN$a + MAIN$b + AB)
  expect_equal(res$rest, MAIN$c)
})

test_that("sequential groups follow the listed order", {
  calls <- use_game()
  res <- decom(attribution = "sequential", groups = list(g1 = "a", g2 = c("b", "c")))
  expect_equal(res$g1, MAIN$a)
  expect_equal(res$g2, MAIN$b + MAIN$c + AB)
  expect_length(calls$args, 3)
})

test_that("nm_decompose forwards groups", {
  use_game()
  res <- nm_decompose(method = "meteorology", df = frame(), model = list(), n_samples = 2,
                      n_cores = 1, verbose = FALSE, groups = list(x = c("a", "b", "c")))
  expect_equal(res$x, game(c("a", "b", "c")) - 10)
})

test_that("inconsistent options are refused before any normalisation", {
  cases <- list(
    list(args = list(groups = list(g = c("a", "b"))), msg = "not in any"),
    list(args = list(groups = list(g = c("a", "b"), h = c("b", "c"))), msg = "in two groups"),
    list(args = list(groups = list(g = c("a", "a", "b", "c"))), msg = "twice in group"),
    list(args = list(groups = list(g = c("a", "b", "c", "zzz"))), msg = "not a meteorological"),
    list(args = list(groups = list(g = c("a", "b", "c", "hour"))), msg = "time variable"),
    list(args = list(groups = list(g = c("a", "b"), met_total = "c")), msg = "clashes"),
    list(args = list(groups = list(g = c("a", "b", "c"), h = character(0))), msg = "empty"),
    list(args = list(groups = list(c("a", "b", "c"))), msg = "named list"),
    list(args = list(groups = list(g = c("a", "b", "c")), variable_order = c("a", "b", "c")),
         msg = "groups"),
    list(args = list(attribution = "shapley", variable_order = c("a", "b", "c")), msg = "no effect"),
    list(args = list(n_permutations = 4), msg = "only applies"),
    list(args = list(attribution = "shapley", n_permutations = 0), msg = "at least 1"),
    list(args = list(attribution = "shapley", n_permutations = 2.5), msg = "whole number"),
    list(args = list(attribution = "shapley", n_permutations = Inf), msg = "whole number"),
    list(args = list(attribution = "banzhaf"), msg = "'sequential' or 'shapley'"),
    list(args = list(variable_order = c("a", "b", "b", "c")), msg = "more than once"),
    list(args = list(variable_order = c("a", "b")), msg = "variable_order")
  )
  for (case in cases) {
    calls <- use_game()
    expect_error(do.call(decom, case$args), case$msg, info = case$msg)
    expect_length(calls$args, 0)
  }
})

test_that("exact Shapley over too many features is refused", {
  feats <- paste0("f", 0:10)
  calls <- use_game(order = feats)
  df <- frame()
  for (f in feats) df[[f]] <- 1
  expect_error(
    nm_decom_met(df, model = list(), n_samples = 2, n_cores = 1, verbose = FALSE,
                 attribution = "shapley"),
    "n_permutations"
  )
  expect_length(calls$args, 0)
})

test_that("the emission decomposition refuses the meteorology-only options", {
  calls <- use_game()
  expect_error(
    nm_decompose(method = "emission", df = frame(), model = list(), verbose = FALSE,
                 groups = list(g = c("a", "b", "c"))),
    "nm_decom_met"
  )
  expect_error(
    nm_decompose(method = "emission", df = frame(), model = list(), verbose = FALSE,
                 attribution = "sequential"),
    "nm_decom_met"
  )
  expect_length(calls$args, 0)
})

# ---------------------------------------------------------- forwarded options

test_that("pools and the conditional filter reach every nm_normalise call", {
  calls <- use_game()
  pool <- data.frame(c = c(0, 1))
  decom(groups = list(ab = c("a", "b"), c = "c"), resample_pools = list(clean = pool),
        conditional_on = list(hour = c(0, 1)))

  expect_length(calls$args, 4)
  for (a in calls$args) {
    expect_identical(a$resample_pools, list(clean = pool))
    expect_true(all(a$resample_df$hour %in% c(0, 1)))
  }
})

test_that("nm_decom_emi forwards pools too", {
  calls <- use_game()
  pool <- data.frame(c = c(0, 1))
  nm_decom_emi(frame(), model = list(), n_samples = 2, n_cores = 1, verbose = FALSE,
               resample_pools = list(clean = pool))
  expect_gt(length(calls$args), 0)
  for (a in calls$args) expect_identical(a$resample_pools, list(clean = pool))
})

# ----------------------------------------------------------- missing values

test_that("a model trained here decomposes the rows it kept", {
  # The reported crash: nm_build_model drops rows with a missing covariate, while
  # `observed` was taken before training ("arguments imply differing number of rows").
  skip_if_not_installed("lightgbm")
  set.seed(0)
  n <- 300
  df <- data.frame(date = T0 + 3600 * (0:(n - 1)), t2m = rnorm(n, 10, 3), blh = runif(n, 200, 1200))
  df$pm <- 30 - 0.01 * df$blh + 0.5 * df$t2m + rnorm(n)
  df$pm[seq(1, n, 13)] <- NA
  df$blh[seq(3, n, 11)] <- NA
  cfg <- list(n_trials = 1, cv_folds = 2, nrounds = 15)

  met <- nm_decom_met(df, NULL, target = "pm", covariates = c("t2m", "blh"), model_config = cfg,
                      n_samples = 2, n_cores = 1, verbose = FALSE,
                      groups = list(local = c("t2m", "blh")))
  emi <- nm_decom_emi(df, NULL, target = "pm", covariates = c("t2m", "blh"), model_config = cfg,
                      n_samples = 2, n_cores = 1, verbose = FALSE)

  kept <- sum(!is.na(df$pm) & !is.na(df$blh))
  expect_equal(nrow(met), kept)
  expect_equal(nrow(emi), kept)
  expect_equal(met$met_total, met$observed - met$emi_total)
})

# -------------------------------------------------------------- resample pools

pool_frame <- function() {
  data.frame(date = T0 + 3600 * (0:39), value = 1, a = as.numeric(0:39),
             b = 1 + (0:39) %% 3, hour = (0:39) %% 24)
}
CLEAN <- data.frame(b = c(7, 8))

test_that("pool variables come from the pool, the rest from resample_df", {
  df <- data.table::as.data.table(pool_frame())
  out <- nm_generate_resampled(df, c("a", "b"), TRUE, 11, df, list(clean = CLEAN))
  expect_true(all(out$b %in% c(7, 8)))
  expect_true(all(out$a %in% df$a))
  expect_gt(length(unique(out$a)), 10)
})

test_that("adding a pool leaves the other variables' draws alone", {
  df <- data.table::as.data.table(pool_frame())
  plain <- nm_generate_resampled(df, c("a", "b"), TRUE, 11, df)
  pooled <- nm_generate_resampled(df, c("a", "b"), TRUE, 11, df, list(clean = CLEAN))
  expect_identical(plain$a, pooled$a)
})

test_that("a pooled variable's draws do not move when others are fixed", {
  df <- data.table::as.data.table(pool_frame())
  both <- nm_generate_resampled(df, c("a", "b"), TRUE, 11, df, list(clean = CLEAN))
  alone <- nm_generate_resampled(df, "b", TRUE, 11, df, list(clean = CLEAN))
  expect_identical(both$b, alone$b)
})

test_that("a pool's draws do not depend on the other pools", {
  # Its seed comes from its name, so a pool that sorts before it changes nothing.
  df <- data.table::as.data.table(pool_frame())
  one <- nm_generate_resampled(df, c("a", "b"), TRUE, 11, df, list(clean = CLEAN))
  two <- nm_generate_resampled(df, c("a", "b"), TRUE, 11, df,
                               list(`a-pool` = data.frame(a = c(100, 200)), clean = CLEAN))
  expect_identical(one$b, two$b)
  expect_true(all(two$a %in% c(100, 200)))
})

test_that("a pool keeps its rows together", {
  df <- data.table::as.data.table(pool_frame())
  pool <- data.frame(a = c(100, 200, 300), b = c(1, 2, 3))
  out <- nm_generate_resampled(df, c("a", "b"), TRUE, 11, df, list(p = pool))
  expect_equal(out$a, 100 * out$b)
})

test_that("bad pools are refused", {
  preds <- c("a", "b", "hour")
  expect_error(.nm_check_resample_pools(list(p = CLEAN, q = data.frame(b = 9)), preds),
               "two resample pools")
  expect_error(.nm_check_resample_pools(list(p = CLEAN[0, , drop = FALSE]), preds), "no rows")
  expect_error(.nm_check_resample_pools(list(p = data.frame(traj_resid_contnent = 0.5)), preds),
               "no model feature")
  expect_error(.nm_check_resample_pools(list(p = 1:3), preds), "must be a data frame")
  expect_error(.nm_check_resample_pools(list(CLEAN), preds), "named list")
  expect_null(.nm_check_resample_pools(NULL, preds))
})

test_that("nm_normalise draws pooled variables from the pool on every worker", {
  skip_if_not_installed("lightgbm")
  model <- list()
  attr(model, "backend") <- "lightgbm"
  attr(model, "feature_names") <- c("a", "b", "hour")
  local_mocked_bindings(nm_predict_lgb = function(model, newdata, verbose = FALSE, ...) {
    newdata$a + 1000 * newdata$b
  })
  res <- nm_normalise(pool_frame(), model, verbose = FALSE, resample_vars = c("a", "b"),
                      n_samples = 6, seed = 3, n_cores = 2, aggregate = FALSE,
                      resample_pools = list(clean = CLEAN))
  draws <- as.matrix(res[, setdiff(colnames(res), c("date", "observed"))])
  b <- floor(draws / 1000)
  expect_true(all(b %in% c(7, 8)))
  expect_true(all((draws - 1000 * b) %in% pool_frame()$a))
})

test_that("the cache tells pools apart", {
  skip_if_not_installed("lightgbm")
  model <- list()
  attr(model, "backend") <- "lightgbm"
  attr(model, "feature_names") <- c("a", "b", "hour")
  local_mocked_bindings(nm_predict_lgb = function(model, newdata, verbose = FALSE, ...) {
    1000 * newdata$b
  })
  cache_dir <- file.path(tempdir(), paste0("nmcache_pools_", as.integer(runif(1, 1, 1e8))))
  dir.create(cache_dir, showWarnings = FALSE, recursive = TRUE)
  on.exit(unlink(cache_dir, recursive = TRUE), add = TRUE)
  run <- function(pool) {
    nm_normalise(pool_frame(), model, verbose = FALSE, cache_dir = cache_dir,
                 resample_vars = "b", n_samples = 4, seed = 3, n_cores = 1,
                 resample_pools = list(clean = pool))$normalised
  }
  first <- run(CLEAN)
  other <- run(data.frame(b = 5))
  expect_true(all(other != first))
  expect_identical(run(CLEAN), first)
})
