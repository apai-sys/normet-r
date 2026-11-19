# Quick start

This page runs the whole meteorological-normalisation pipeline on data that
ships with the package. It needs a model backend; `lightgbm` is the default
(see [Installation](installation.md)).

## One-shot meteorological normalisation

`nm_do_all()` runs the full pipeline — prepare → train → normalise — in a
single call. The example uses `my1`: hourly NO2 and ERA5 meteorology at
London Marylebone Road (MY1), January–August 2020, a window spanning the UK
COVID-19 lockdown.

```r
library(normet)

# Meteorological predictors + the time features the model will see
met_vars   <- c("ws", "wd", "temp", "RH", "atmos_pres", "blh", "tcc", "tp", "ssrd")
predictors <- c(met_vars, "date_unix", "day_julian", "weekday", "hour")

results <- nm_do_all(
  df            = my1,
  target        = "NO2",
  backend       = "lightgbm",      # or "h2o"
  covariates    = predictors,
  resample_vars = met_vars,        # resample met only — not the time features
  n_samples     = 300,
  n_cores       = 4                 # H2O cluster allocation (lightgbm ignores it)
)

head(results$res)                   # date | observed | normalised
nm_plot_normalise(results$res)
nm_modStats(results$df_prep, results$model)
```

`nm_do_all()` returns a list with three elements:

| Element | Contents |
|---|---|
| `res` | The normalised data frame: `date`, `observed`, `normalised` |
| `model` | The trained model, for decomposition and further normalisation |
| `df_prep` | The prepared frame the model was trained on (`value` + `set`) |

`nm_modStats(results$df_prep, results$model)` prints the model's performance
on the training and testing splits. `nm_plot_normalise()` draws the observed
and weather-normalised series together.

## Bundled example data

The package ships four real datasets from the model-description paper's case
studies:

| Object | Contents |
|---|---|
| `my1` | Hourly NO2 + ERA5 met at London Marylebone Road (MY1), Jan–Aug 2020 |
| `my1_pm25` | Hourly PM2.5 + met at MY1, Jan–Aug 2020 (transport-aware case) |
| `scm` | Monthly deweathered NO2 panel, UK sites, 2016–2021 (ULEZ SCM case) |
| `traj_my1` | HYSPLIT back-trajectory features arriving at MY1, Jan–Aug 2020 |

Sources: UK AURN (Defra, Open Government Licence v3.0); ERA5 (Copernicus
Climate Change Service); HYSPLIT (NOAA ARL). `system.file("extdata", "traj",
package = "normet")` holds a two-day sample of raw HYSPLIT `tdump` files for
the trajectory readers.

## Where to go next

- [Step-by-step workflow](../guide/workflow.md) — the same pipeline one step at
  a time, then decomposition, synthetic control and the advanced options.
- [Weather normalisation](../guide/examples_normalisation.md) — quantile bands,
  conditional "what-if" weather and log-scale fits.
- [Data adapters](../guide/examples_data_adapters.md) — your own tables, the
  UK networks, EEA, OpenAQ, ERA5 and Open-Meteo.
- [Desktop GUI](../guide/gui.md) — the same workflow without writing code.
