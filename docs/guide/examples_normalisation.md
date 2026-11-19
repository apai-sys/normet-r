# Weather normalisation

The core idea: hold every other feature fixed and *resample* the meteorology
so the model averages out weather variability, leaving a series that reflects
underlying emissions.

## One-shot pipeline

```r
library(normet)

df <- nm_read_table("my_site.csv")     # CSV/TSV/Excel/Parquet/Feather/JSON

met_vars   <- c("t2m", "blh", "u10", "v10")
predictors <- c(met_vars, "date_unix", "day_julian", "weekday", "hour")

results <- nm_do_all(
  df            = df,
  target        = "PM2.5",
  backend       = "lightgbm",    # or "h2o"
  covariates    = predictors,
  resample_vars = met_vars,
  n_samples     = 300
)
head(results$res)                # date | observed | normalised
```

`results$res` is a data frame with `date`, `observed` and `normalised`.

## Quantile bands (resampling uncertainty)

For a single trained model, pass `return_quantiles =` to `nm_normalise()`:

```r
out <- nm_normalise(
  df               = results$df_prep,
  model            = results$model,
  resample_vars    = met_vars,
  n_samples        = 300,
  return_quantiles = c(0.025, 0.5, 0.975)
)
# columns: date, observed, normalised, q025, q500, q975
nm_plot_normalise(out, ci_low = "q025", ci_high = "q975")
```

These bands reflect *resampling* uncertainty (one model, many shuffles). For
*model* uncertainty (many seeds, each with its own training run), use
`nm_do_all_unc()`, which trains several models and combines them.

## Automatic sample count

`nm_normalise_auto()` picks the number of resamples itself. Its `"series"`
metric stops when the per-date relative standard error at a high percentile
has fallen below the tolerance for several consecutive checks:

```r
auto <- nm_normalise_auto(
  df            = results$df_prep,
  model         = results$model,
  resample_vars = met_vars,
  convergence_tol = "3%"
)
auto$best_n
head(auto$res)
```

`return_history = TRUE` adds the per-batch convergence trace (useful for
auditing the stopping path).

## Counterfactual "what-if" conditions

`conditional_on` restricts the resample pool (it lives on
`nm_normalise_ext()`). Each element is a scalar
(exact match), a vector (`%in%` semantics), or a function (a logical mask):

```r
# What would PM2.5 have been with summer-like meteorology?
out_summer <- nm_normalise_ext(
  df             = results$df_prep,
  model          = results$model,
  resample_vars  = met_vars,
  resample_df    = transform(results$df_prep,
                             month = as.integer(format(date, "%m"))),
  conditional_on = list(month = 6:8),
  n_samples      = 300
)

# Holding wind direction in the south-westerly sector
out_sw <- nm_normalise_ext(
  df             = results$df_prep,
  model          = results$model,
  resample_vars  = met_vars,
  conditional_on = list(wd = function(d) d >= 180 & d <= 270),
  n_samples      = 300
)
```

A filter column must exist in the resampling pool — a covariate the model
uses, or a column of `resample_df`. The `transform()` call above adds
`month` to the pool without retraining the model.

## Log-scale fits (low-concentration, multi-decade pollutants)

A pollutant that ranges from sub-unit to hundreds of µg/m³ spends most of its
raw-scale variance on its high hours, so a linear fit buys accuracy where the
policy question is least — and the values a health assessment actually reads
are the low ones. Fitting on `log1p(value)` makes errors count in relative
rather than absolute terms: a fixed relative miss maps to a bounded error at
every level, while its absolute error grows with the level.

```r
results <- nm_do_all(
  df            = df,
  target        = "PM2.5",
  backend       = "lightgbm",
  covariates    = c("t2m", "blh", "u10", "v10", "hour"),
  resample_vars = c("t2m", "blh", "u10", "v10"),
  n_samples     = 300,
  log_transform = TRUE
)
```

What the flag changes, and what it doesn't:

- The model **trains on `log1p(value)`** and the de-weathering resamples and
  predicts on that scale; every column of `results$res` — `observed`,
  `normalised`, the quantile columns — is back-transformed through `expm1`,
  so the result is in the original units and non-negative by construction.
- The returned `df_prep` carries `log1p(value)` in its `value` column: it is
  the frame the model was trained on, which is what you want for
  `nm_modStats(results$df_prep, results$model)`.
- `nm_do_all_unc()` accepts the same flag; every ensemble member trains on
  the log scale, the ensemble output is in original units, and the per-member
  statistics that drive the weights are log-space (the scale each member was
  fitted on).
- `nm_normalise()` accepts it too, for a model you trained yourself: pass the
  frame and the model in the log1p space, get the original-scale result back.
- It needs a non-negative target: a concentration that is negative in the
  original units is rejected with an error giving the count and minimum of the
  offending values.
- The HTML report (via `nm_make_run()`'s `config`) notes the scale and the
  share of observations below 1 in the original units — the population the
  scale is for.

Judge the fit in the space it optimises. `nm_modStats()` scores the model on
the prepared data; for the normalised output, compare observed against
normalised on both scales, remembering that RMSE and log-RMSE say different
things and FAC2 is scale-free and unchanged.

Leave `log_transform = FALSE` (the default) for data that doesn't span
decades; the linear path is bit-identical to before.

## Rolling normalisation

`nm_rolling()` re-normalises over moving windows, so the de-weathered series
is measured against the meteorology of its own window rather than the whole
record:

```r
rolled <- nm_rolling(
  df            = results$df_prep,
  model         = results$model,
  resample_vars = met_vars,
  n_samples     = 300,
  window_days   = 14,
  rolling_every = 7
)
# one row per timestamp and one column per rolling window
nm_plot_rolling(rolled, data = results$df_prep)
```

See also [Step-by-step workflow](workflow.md) and
[Uncertainty decomposition](examples_uncertainty.md).
