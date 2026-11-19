# Manual smoke test for the series-level convergence criterion in
# nm_normalise_auto (convergence_metric="series"/"global").
.libPaths(c(path.expand("~/R_libs_bench"), path.expand("~/R_libs_normet"), .libPaths()))
suppressPackageStartupMessages(devtools::load_all("/net/scratch/n94921cs/normet-r", quiet = TRUE))

set.seed(42)
n <- 500
df <- data.frame(
  date = seq(as.POSIXct("2021-01-01", tz = "UTC"), by = "hour", length.out = n),
  met1 = rnorm(n, 10, 3), met2 = rnorm(n)
)
df$value <- 5 + 2 * df$met1 - 3 * df$met2 + rnorm(n, 0, 2)
MET <- c("met1", "met2")

prep <- nm_prepare_data(df, target = "value", covariates = MET,
                        split_method = "random", train_fraction = 0.75, seed = 1)
model <- nm_train_model(prep[prep$set == "training", ], target = "value",
                        covariates = c(MET, "date_unix", "day_julian", "weekday", "hour"),
                        backend = "lightgbm",
                        model_config = list(n_trials = 1, cv_folds = 2, nrounds = 20),
                        verbose = FALSE)
cat("model built\n")

# 1. series metric, loose tol -> floor stop at batch*(streak(3)+1) = 40
r <- nm_normalise_auto(prep, model, resample_vars = MET, convergence_tol = "50%",
                       batch_size = 10, max_samples = 200, seed = 1,
                       verbose = FALSE, return_history = TRUE, n_cores = 1)
cat(sprintf("series loose: best_n=%d (expect 40)\n", r$best_n))
stopifnot(r$best_n == 40)
stopifnot(identical(names(r$res), c("date", "observed", "normalised")))
stopifnot(!any(is.na(r$res$normalised)), nrow(r$res) == n)
stopifnot(identical(names(r$history), c("n", "metric", "global_mean", "stable_count")))
print(r$history)

# 2. RSE ~ 1/sqrt(n_batches): strict tol runs to max, check scaling + warning
w <- tryCatch({
  r2 <- nm_normalise_auto(prep, model, resample_vars = MET, convergence_tol = "0.0001%",
                          batch_size = 10, max_samples = 200, seed = 1,
                          verbose = FALSE, return_history = TRUE, n_cores = 1)
  "NO WARNING"
}, warning = function(cond) {
  r2 <<- suppressWarnings(nm_normalise_auto(prep, model, resample_vars = MET,
        convergence_tol = "0.0001%", batch_size = 10, max_samples = 200, seed = 1,
        verbose = FALSE, return_history = TRUE, n_cores = 1))
  conditionMessage(cond)
})
cat("warning message:", w, "\n")
stopifnot(grepl("without strict convergence", w))
h <- r2$history
m50 <- h$metric[h$n == 50]; m200 <- h$metric[h$n == 200]
cat(sprintf("RSE scaling m50/m200 = %.2f (CLT ~ %.2f)\n", m50 / m200, sqrt(19 / 4)))
stopifnot(m50 / m200 > 1.3, m50 / m200 < 4)

# 3. legacy global metric, loose tol -> floor stop 10*(5+1)=60
r3 <- suppressWarnings(nm_normalise_auto(prep, model, resample_vars = MET,
      convergence_metric = "global", convergence_tol = "50%",
      batch_size = 10, max_samples = 200, seed = 1, verbose = FALSE, n_cores = 1))
cat(sprintf("global loose: best_n=%d (expect 60)\n", r3$best_n))
stopifnot(r3$best_n == 60)

# 4. same-n results identical across metrics
r4 <- suppressWarnings(nm_normalise_auto(prep, model, resample_vars = MET,
      convergence_metric = "global", convergence_tol = "0.0001%",
      batch_size = 10, max_samples = 40, seed = 1, verbose = FALSE, n_cores = 1))
stopifnot(max(abs(sort(r$res$normalised) - sort(r4$res$normalised))) < 1e-9)
cat("series/global res identical at same n OK\n")

# 5. bad metric errors
ok <- tryCatch({ nm_normalise_auto(prep, model, convergence_metric = "bogus"); FALSE },
               error = function(e) TRUE)
stopifnot(ok)
cat("bad metric raises error OK\n")

cat("ALL R SMOKE TESTS PASSED\n")
