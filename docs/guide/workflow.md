# Step-by-step workflow

[Quick start](../getting_started/quickstart.md) runs the pipeline in one call.
This page takes it apart: each step of `nm_do_all()` on its own, then
decomposition, synthetic control and the options for larger studies. The
snippets continue from the quick start's `my1`, `met_vars` and `predictors`.

## 1. Prepare data

```r
df_prep <- nm_prepare_data(
  df             = my1,
  target         = "NO2",
  covariates     = met_vars,    # external predictors only
  split_method   = "random",    # "random" | "ts" | "month_ts" | "season_ts"
  train_fraction = 0.75
)
```

Two things happen here. The target column is renamed to `value`, which is what
the later steps read; and the time features (`date_unix`, `day_julian`,
`weekday`, `hour`) are computed and appended. In R, `nm_prepare_data()` takes
only the *external* covariates: the time features are added for you, and
`nm_train_model()` is where you choose which of them the model may use.

## 2. Train a model

```r
model <- nm_train_model(
  df           = df_prep,
  target       = "value",
  covariates   = predictors,    # weather + the time features to use
  backend      = "lightgbm",    # or "h2o"
  model_config = list(n_trials = 20, cv_folds = 3)
)

nm_modStats(df_prep, model)     # performance on the training and testing sets
```

Time features are opt-in: list `date_unix`, `day_julian`, `weekday` and
`hour` in `covariates` for the ones the model should see, or omit them all to
train purely on meteorology. `nm_decompose()` adapts to whichever subset ends
up in the model.

For H2O, the search is bounded by a model count under a time cap:

```r
nm_init_h2o()
model_h2o <- nm_train_model(
  df           = df_prep,
  target       = "value",
  covariates   = predictors,
  backend      = "h2o",
  model_config = list(
    max_models      = 5,         # models to train (ensembles not counted)
    max_runtime_secs = 600,       # safety cap
    include_algos   = c("GBM")
  )
)
nm_stop_h2o()
```

## 3. Normalise

```r
df_norm <- nm_normalise(
  df            = df_prep,
  model         = model,
  resample_vars = met_vars,     # the weather that is resampled away
  n_samples     = 300,
  n_cores       = 4
)
```

`df_norm` is a data frame with `date`, `observed` and `normalised`.
`nm_plot_normalise(df_norm)` draws it.

Quantile bands come from the same call with `return_quantiles =`:

```r
df_norm_q <- nm_normalise(
  df               = df_prep,
  model            = model,
  resample_vars    = met_vars,
  n_samples        = 300,
  return_quantiles = c(0.025, 0.5, 0.975)
)
# columns: date, observed, normalised, q025, q500, q975
nm_plot_normalise(df_norm_q, ci_low = "q025", ci_high = "q975")
```

Supply a different reference period with `resample_df`, for example the weather
of the weeks before the lockdown:

```r
ref_weather <- df_prep[df_prep$date < as.Date("2020-03-01"), ]

df_norm_ref <- nm_normalise(
  df            = df_prep,
  model         = model,
  resample_vars = met_vars,
  resample_df   = ref_weather,
  n_samples     = 300
)
```

For a target that spans sub-unit to hundreds of µg/m³, fit on the log scale:
`nm_do_all(..., log_transform = TRUE)` (also on `nm_do_all_unc()` and
`nm_normalise()`) trains on `log1p(value)` and back-transforms every result
column through `expm1`, so the output is in the original units and
non-negative by construction. See [Weather normalisation](../guide/examples_normalisation.md)
for what the flag changes.

`nm_normalise_auto()` chooses `n_samples` itself, stopping when the series
has converged:

```r
auto <- nm_normalise_auto(df_prep, model, resample_vars = met_vars)
auto$best_n
head(auto$res)
```

## Decomposition

Split the time series into emission-driven and meteorology-driven components:

```r
df_emi <- nm_decompose(method = "emission",    df = df_prep, model = model,
                        covariates = predictors)

df_met <- nm_decompose(method = "meteorology", df = df_prep, model = model,
                        covariates = predictors)

nm_plot_decomposition_stack(df_emi)
```

More on this step: [Time-series decomposition](examples_decomposition.md), and
[Trend analysis](examples_trend.md) for trend tests on the emission component.

## Counterfactual modelling (synthetic control)

SCM asks: *what would have happened to the treated unit if the intervention
had not occurred?* It builds a synthetic counterfactual from a weighted
combination of untreated "donor" units and compares it to what was actually
observed after the intervention.

The bundled `scm` panel reproduces the paper's ULEZ case study: the London
Ultra Low Emission Zone (launched 2019-04-08) is evaluated at the kerbside
site MY1, using deweathered monthly NO2 from traffic-type sites elsewhere in
the UK as the donor pool.

```r
win     <- scm[scm$date >= as.Date("2017-01-01") & scm$date < as.Date("2020-03-01"), ]
traffic <- win[grepl("Traffic", win$type), ]

n_months <- length(unique(traffic$date))
coverage <- tapply(!is.na(traffic$NO2_dw), traffic$code, sum)
panel    <- traffic[traffic$code %in% names(coverage)[coverage == n_months], ]

treated <- "MY1"
donors  <- setdiff(unique(panel$code), treated)
cutoff  <- "2019-04-01"   # the ULEZ launch month
```

### Run SCM

```r
result <- nm_run_scm(
  df           = panel,
  date_col     = "date",
  unit_col     = "code",
  outcome_col  = "NO2_dw",
  treated_unit = treated,
  donors       = donors,
  cutoff_date  = cutoff,
  scm_backend  = "scm"      # "scm" | "abadie" | "did" | "mcnnm" | "robust" | "mlscm" | "bayesian"
)
head(result)                # date | observed | synthetic | effect
```

Available backends: `scm` (ridge-augmented SCM), `abadie` (classic simplex),
`did` (difference-in-differences), `mcnnm` (matrix completion), `robust`
(HSVT de-noising, Amjad et al. 2018), `mlscm` (**experimental** — a direct
`nm_mlscm()` call emits an experimental warning; `nm_run_scm()` suppresses it)
and `bayesian` (Dirichlet-weighted, see [Bayesian SCM](examples_scm.md)).

### Placebo tests

```r
placebo <- nm_placebo_in_space(
  df = panel, date_col = "date", unit_col = "code", outcome_col = "NO2_dw",
  treated_unit = treated, donors = donors, cutoff_date = cutoff,
  scm_backend = "scm"
)

bands <- nm_effect_bands_space(placebo, level = 0.95)
nm_plot_effect_with_bands(bands, cutoff_date = cutoff)
```

### Uncertainty quantification

```r
boot_bands <- nm_uncertainty_bands(
  df = panel, date_col = "date", unit_col = "code", outcome_col = "NO2_dw",
  treated_unit = treated, donors = donors, cutoff_date = cutoff,
  scm_backend = "scm",
  method = "bootstrap", B = 200
)
nm_plot_uncertainty_bands(boot_bands, cutoff_date = cutoff)
```

More on this step: [Synthetic-control modelling](examples_scm_guide.md)
(diagnostics, pre-trend tests, staggered adoption, inference) and
[Bayesian SCM](examples_scm.md).

## Advanced features

### Ensemble uncertainty

`nm_do_all_unc()` runs the full pipeline `n_models` times with different seeds
and returns meteorologically normalised contributions with confidence bands
plus per-model statistics:

```r
unc <- nm_do_all_unc(
  df            = my1,
  target        = "NO2",
  backend       = "lightgbm",
  covariates    = predictors,
  resample_vars = met_vars,
  n_samples     = 300,
  n_models      = 10,
  confidence_level = 0.95
)

head(unc$res)      # observed, normalised_<seed> members, mean, weighted, bands
unc$mod_stats      # per-member performance metrics
```

[Uncertainty decomposition](examples_uncertainty.md) attributes the spread to
weather and model form.

### Multi-site pipelines

`nm_do_all_multisite()` takes one long-format table with a site column and
runs the pipeline per site in parallel:

```r
results_by_site <- nm_do_all_multisite(
  df            = df_all_sites,
  site_col      = "site",
  target        = "PM2.5",
  backend       = "lightgbm",
  covariates    = predictors,
  resample_vars = met_vars,
  n_cores       = 4
)
```

More: [Multi-site pipelines](examples_multisite.md).

### Feature engineering

```r
df <- nm_add_lag_features(df, cols = c("PM2.5"), lags = c(1, 2, 24))
df <- nm_add_rolling_features(df, cols = c("PM2.5"), windows = c(7, 30))
df <- nm_cyclical_encode(df, col = "hour", period = 24)
uv <- nm_wind_to_uv(df$ws, df$wd)   # data frame: u, v
```

More, including how to choose meteorology–pollution lags:
[Feature engineering](examples_feature_engineering.md).

### Cross-validation

`nm_cv_score()` trains and scores the backend across walk-forward
(time-ordered) folds of the prepared table:

```r
scores <- nm_cv_score(df_prep, target = "value",
                       covariates = predictors, n_splits = 5)
print(scores)     # one row per fold, with metrics and metadata
```

### Caching long-running computations

Pass `cache_dir` to the pipelines, or use the directory directly:

```r
cache <- nm_make_cache(".normet_cache")

results <- nm_do_all(
  df = my1, target = "NO2", covariates = predictors,
  resample_vars = met_vars, n_samples = 300,
  cache_dir = cache$path
)

# A manual key, for your own expensive step
key  <- nm_config_hash(nm_dataframe_hash(df_prep), n_samples = 300)
path <- file.path(cache$path, paste0(key, ".rds"))
```

`nm_make_cache()` returns a list with the directory (`path`) and, when the
`memoise` package is available, a `memoise` function for your own callables.

### Provenance tracking

```r
run <- nm_make_run(
  results$res,
  kind    = "do_all",
  config  = list(target = "NO2", backend = "lightgbm"),
  df      = my1,
  df_prep = results$df_prep,
  model   = results$model,
  seed    = 7654321
)
nm_save_run(run, "runs/my1_run")    # runs/my1_run.rds + runs/my1_run.meta.json

back <- nm_load_run("runs/my1_run") # path without the .rds works too
back$metadata
```

`nm_generate_html(run, "report.html")` renders a run as a single-file HTML
report (English; `lang = "zh"` for Chinese), and `nm_report_to_markdown(run,
"report.md")` as Markdown. More: [Caching and provenance](examples_caching.md).

### Data adapters

```r
# ERA5 reanalysis — single-point time-series straight from the CDS
era5 <- nm_fetch_era5_timeseries(
  sites     = data.frame(site = "MY1", lat = 51.52, lon = -0.15),
  date_from = "2018-01-01", date_to = "2023-12-31",
  variables = nm_era5_aq_variables_default,
  cache_dir = ".era5_cache"
)

# UK air quality — six networks from whole-year archives,
# or source = "aurn_live" for a near-real-time window
aurn <- nm_fetch_ukaq_measurements(
  "MY1", 2018:2023, source = "aurn", pollutant = "NO2"
)

# Open-Meteo — keyless ERA5-derived meteorology (no CDS account needed)
met <- nm_fetch_openmeteo_timeseries(
  sites     = list(MY1 = c(51.52, -0.15)),
  date_from = "2018-01-01", date_to = "2023-12-31"
)

# OpenAQ
openaq <- nm_fetch_openaq_measurements(
  location_id = 12345, parameter = "pm25",
  date_from = "2024-01-01", date_to = "2024-01-07"
)
```

More: [Data adapters](examples_data_adapters.md) and the worked
[OpenAQ + ERA5 example](examples_openaq.md).

## A note on the two sibling packages

`normet-py` additionally has a command-line tool, a Chronos-2 zero-shot
foundation-model path and a Sphinx documentation site. This R package covers
the same normalisation, decomposition and causal-inference core on R, with the
desktop GUI and the MCP server as its no-code and agent interfaces.
