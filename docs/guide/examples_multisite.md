# Multi-site batch pipelines

The snippets continue from the quick start: `df_network` is a long-format
panel with a site column, and `predictors`/`covariates` are the covariate
lists used there.

When you have one long-format data frame with many stations, use the
multi-site drivers:

```r
df_norm <- nm_do_all_multisite(
  df            = df_network,
  site_col      = "site",
  target        = "PM2.5",
  backend       = "lightgbm",
  covariates    = predictors,
  resample_vars = covariates,
  n_samples     = 300,
  n_cores       = 8
)

df_decomp <- nm_decompose_multisite(
  df         = df_network,
  site_col   = "site",
  method     = "emission",
  target     = "PM2.5",
  covariates = predictors,
  n_cores    = 8
)
```

`nm_do_all_multisite()` returns the normalised results with the site column
appended; with `return_models = TRUE` it returns a list with `res` (the
table) and `models` (a list named by site). `nm_decompose_multisite()`
returns the per-site decomposition results with the site column appended.
Both run sites in parallel and both warn and skip a failed site rather than
stopping the batch; if every site fails, the error lists each one.

For other per-site operations, the generic helper `nm_multisite_apply()`
parallelises any function that takes a per-site data frame and returns a data
frame:

```r
site_summary <- function(df, ...) {
  data.frame(n = nrow(df), mean_no2 = mean(df$NO2, na.rm = TRUE))
}

nm_multisite_apply(df_network, site_col = "site", func = site_summary, n_cores = 4)
```

`site_kwarg` passes the site's identifier to the function under a chosen
argument name when the function needs to know which site it is working on.

Pair multi-site runs with the on-disk cache: the first site's model and
normalisation are reused when the same configuration is asked for again. See
[Caching and provenance](examples_caching.md).
