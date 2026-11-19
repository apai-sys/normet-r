# Parallel drivers called the way a script or the console calls them: from the
# global environment, with the data in a global variable. A promise on the global
# environment travels to a PSOCK worker unevaluated, and the worker's global
# environment is empty, so every worker failed with "object '...' not found" and
# the error was swallowed (2026-11-13). A call from inside a test_that() block
# cannot show this -- the test's own environment is serialised with the closure --
# hence the eval() in globalenv() below.

in_global <- function(expr, data) {
  for (nm in names(data)) assign(nm, data[[nm]], envir = globalenv())
  on.exit(rm(list = names(data), envir = globalenv()), add = TRUE)
  eval(expr, envir = globalenv())
}

small_my1 <- function(n = 600) {
  d <- normet::my1[seq_len(n), c("date", "NO2", "blh", "tp", "ssrd")]
  d[stats::complete.cases(d), ]
}

test_that("nm_do_all_unc runs its members on data held in a global variable", {
  skip_if_not_installed("lightgbm")
  out <- in_global(quote(nm_do_all_unc(
    df = .nm_test_df, target = "NO2", covariates = .nm_test_covs,
    n_samples = 5, n_models = 2, model_config = list(n_estimators = 10),
    verbose = FALSE)),
    list(.nm_test_df = small_my1(), .nm_test_covs = c("blh", "tp", "ssrd")))
  expect_true(all(c("mean", "lower_bound", "upper_bound") %in% colnames(out$res)))
  expect_equal(sum(grepl("^normalised_", colnames(out$res))), 2)
})

test_that("nm_do_all_unc says why when every member fails", {
  skip_if_not_installed("lightgbm")
  expect_error(
    in_global(quote(nm_do_all_unc(
      df = .nm_test_df, target = "not_a_column", covariates = c("blh", "tp"),
      n_samples = 5, n_models = 2, verbose = FALSE)),
      list(.nm_test_df = small_my1())),
    "First error")
})

test_that("nm_do_all_multisite runs every site and returns each site's model", {
  skip_if_not_installed("lightgbm")
  d <- small_my1()
  two <- rbind(transform(d, site = "A"), transform(d, site = "B"))
  out <- in_global(quote(nm_do_all_multisite(
    .nm_test_df, site_col = "site", target = "NO2", covariates = .nm_test_covs,
    n_cores = 2, return_models = TRUE, n_samples = 5,
    model_config = list(n_estimators = 10), verbose = FALSE)),
    list(.nm_test_df = two, .nm_test_covs = c("blh", "tp", "ssrd")))
  expect_setequal(unique(out$res$site), c("A", "B"))
  # Models used to be written with `<<-` inside the workers and never came back.
  expect_named(out$models, c("A", "B"))
  expect_false(any(vapply(out$models, is.null, logical(1))))
})

test_that("nm_multisite_apply names each failed site and its error", {
  two <- data.frame(site = c("A", "A", "B", "B"), x = 1:4)
  f <- function(df) if (df$site[1] == "B") stop("boom") else data.frame(y = sum(df$x))
  expect_warning(
    out <- in_global(quote(nm_multisite_apply(.nm_test_df, "site", .nm_test_f, n_cores = 2)),
                     list(.nm_test_df = two, .nm_test_f = f)),
    "B: boom")
  expect_equal(out$site, "A")
  expect_equal(out$y, 3)
  expect_error(
    in_global(quote(nm_multisite_apply(.nm_test_df, "site", function(df) stop("boom"),
                                       n_cores = 2)),
              list(.nm_test_df = two)),
    "A: boom")
})
