# normet: Normalisation, Decomposition, and Counterfactual Modelling for Air Quality Time-series

[![CRAN](https://www.r-pkg.org/badges/version/normet)](https://CRAN.R-project.org/package=normet)
[![R-CMD-check](https://github.com/apai-sys/normet-r/actions/workflows/R-CMD-check.yaml/badge.svg)](https://github.com/apai-sys/normet-r/actions/workflows/R-CMD-check.yaml)
[![Build GUI](https://github.com/apai-sys/normet-r/actions/workflows/build-gui.yml/badge.svg)](https://github.com/apai-sys/normet-r/actions/workflows/build-gui.yml)

`normet` is an R package for **air quality time-series analysis**. It covers the full workflow from data acquisition through weather normalisation, decomposition, uncertainty quantification, and causal impact evaluation.

---

## Features

- **Dual ML backend** — LightGBM (fast, in-process, default) or H2O AutoML (multi-algorithm search)
- **Weather normalisation** — Monte Carlo resampling with auto-convergence detection
- **Time-series decomposition** — isolate emission vs. meteorological contributions
- **Synthetic Control Methods** — classic SCM, ML-SCM, Abadie, DiD, MC-NNM, Bayesian
- **Causal significance tests** — conformal inference, RMSPE ratio, placebo-in-space/time
- **Data acquisition** — built-in adapters for DEFRA/AURN, EEA Discomap, OpenAQ v3, ERA5, HYSPLIT back-trajectories
- **Multi-site pipelines** — parallel normalisation and decomposition across station networks
- **On-disk caching** — SHA-1 content hashing to skip redundant computation

---

## Installation

```r
# install.packages("devtools")
devtools::install_github("apai-sys/normet-r")
```

### Backend setup

```r
install.packages("lightgbm")   # default backend (recommended)
install.packages("h2o")        # alternative: H2O AutoML (requires Java)
```

---

## Quick Start

```r
library(normet)

data("my1")

predictors <- c("u10", "v10", "d2m", "t2m", "blh", "sp", "ssrd", "tcc", "tp", "rh2m",
                "date_unix", "day_julian", "weekday", "hour")
weather_vars <- c("u10", "v10", "d2m", "t2m", "blh", "sp", "ssrd", "tcc", "tp", "rh2m")

results <- nm_do_all(
  df            = my1,
  value         = "PM2.5",
  predictors    = predictors,
  resample_vars = weather_vars,
  n_samples     = 300
)

head(results$out)   # date | observed | normalised
```

---

## Data Acquisition

### UK AURN (DEFRA)

```r
# Browse available stations
stations <- nm_list_aurn_stations(pollutant = "no2")
head(stations)

# Download hourly measurements
df_aurn <- nm_fetch_aurn_measurements(
  station   = "MY1",
  pollutant = "no2",
  date_from = "2022-01-01",
  date_to   = "2022-12-31"
)
```

### EEA Discomap

```r
df_eea <- nm_fetch_eea_data(
  country   = "GB",
  pollutant = "PM2.5",
  year_from = 2021,
  year_to   = 2022
)
```

### OpenAQ v3

```r
# Find monitoring locations
locs <- nm_openaq_locations(country = "GB", pollutant = "pm25")

# Download measurements (set OPENAQ_API_KEY env var or pass api_key=)
df_oaq <- nm_fetch_openaq_measurements(
  location_id = locs$id[1],
  date_from   = "2022-01-01",
  date_to     = "2022-06-30"
)
```

### ERA5 Meteorology

```r
# Fetch ERA5 as single-point time-series straight from the CDS (no NetCDF)
df_era5 <- nm_fetch_era5_timeseries(
  sites     = data.frame(site = "MY1", lat = 51.52, lon = -0.15),
  date_from = "2022-01-01",
  date_to   = "2022-12-31",
  variables = nm_era5_aq_variables_default,
  cache_dir = ".era5_cache"
)
# Columns use short names: site, date, lat, lon, t2m, u10, v10, ...
```

### Open-Meteo Meteorology

Keyless alternative to the Copernicus CDS — no account or `~/.cdsapirc`
needed, serves the same ERA5 archive:

```r
met <- nm_fetch_openmeteo_timeseries(
  sites     = list(MY1 = c(51.52, -0.15)),   # name = c(lat, lon)
  date_from = "2022-01-01",
  date_to   = "2022-12-31"
)
# Columns use short names: site, date, t2m, d2m, rh2m, sp, tcc, tp, ssrd,
# u10, v10, lat, lon — same ERA5 naming/units as nm_fetch_era5_timeseries.
```

### HYSPLIT Back-Trajectories

Turn HYSPLIT back-trajectory output (`tdump` files, generated separately with
`splitr`/`pysplit`/`hyts_std`) into per-receptor transport features — inflow
direction, transport distance/speed, trajectory height, along-path
rainfall/boundary-layer height, and residence-time fractions over source
regions:

```r
traj <- nm_build_trajectory_features(
  "traj/tdump_*",
  source_regions = list(industrial_NE = c(116.0, 39.0, 120.0, 42.0))
)
# traj has a `date` (receptor time) column + traj_* feature columns.
# Join onto the panel and pass traj_* to nm_do_all (also in resample_vars to
# deweather transport; omit from resample_vars to keep the transport signal).
```

Or drive HYSPLIT (`hyts_std`) directly for a set of receptor times, against
GDAS1 meteorology downloaded on demand:

```r
met_files <- nm_fetch_gdas1(
  date_from = "2022-01-01", date_to = "2022-01-08", cache_dir = "gdas1_cache"
)
traj <- nm_run_back_trajectories(
  times = my1$date, lat = 51.52, lon = -0.15,
  met_files = met_files, hysplit_exec = "/opt/hysplit/exec/hyts_std",
  hours_back = 72
)
```

---

## Step-by-Step Workflow

### 1. Prepare data

```r
df_prep <- nm_prepare_data(
  df           = my1,
  value        = "PM2.5",
  predictors   = weather_vars,
  split_method = "random",
  fraction     = 0.75
)
```

### 2. Train model

```r
model <- nm_train_model(
  df           = df_prep,
  value        = "value",
  predictors   = predictors,
  backend      = "lightgbm",          # or "h2o"
  model_config = list(n_trials = 50, cv_folds = 5)
)

nm_modStats(df_prep, model)           # performance metrics
```

### 3. Explain model

```r
# Feature importance
nm_feature_importance(model)

# Partial dependence plots
pdp_data <- nm_pdp(df_prep, model, var_list = c("blh", "rh2m"))
nm_plot_pdp(pdp_data)
```

### 4. Weather normalisation

```r
# Standard
df_norm <- nm_normalise(
  df            = df_prep,
  model         = model,
  resample_vars = weather_vars,
  n_samples     = 600
)

# Auto-convergence: finds optimal n_samples automatically
auto <- nm_normalise_auto(
  df            = df_prep,
  model         = model,
  resample_vars = weather_vars
)
cat("Optimal samples:", auto$best_n, "\n")
head(auto$res)   # date | observed | normalised
```

### 5. Rolling normalisation

```r
df_rolling <- nm_rolling(
  df            = df_prep,
  value         = "value",
  model         = model,
  resample_vars = weather_vars,
  n_samples     = 300,
  window_days   = 14,
  rolling_every = 7
)
```

### 6. Decomposition

```r
df_emi <- nm_decompose(method = "emission",    df = df_prep, value = "value", model = model, n_samples = 300)
df_met <- nm_decompose(method = "meteorology", df = df_prep, value = "value", model = model, n_samples = 300)
```

### 7. Uncertainty ensemble

```r
unc <- nm_do_all_unc(
  df            = my1,
  value         = "PM2.5",
  predictors    = predictors,
  resample_vars = weather_vars,
  n_models      = 10,
  n_samples     = 300
)
nm_plot_uncertainty_bands(unc)
```

---

## Causal Inference

### Setup

```r
data("scm")
cutoff      <- as.Date("2015-10-23")
treated     <- unique(scm$ID[scm$group == "target"])
donors      <- unique(scm$ID[scm$group == "control"])
```

### SCM variants

```r
# Classic lasso SCM
scm_res <- nm_run_scm(
  df = scm, date_col = "date", outcome_col = "SO2wn", unit_col = "ID",
  treated_unit = treated, donors = donors, cutoff_date = cutoff,
  scm_backend = "scm"
)

# ML-SCM — exploratory only, not recommended for inference (see ?nm_mlscm)
ml_res <- nm_run_scm(df = scm, ..., scm_backend = "mlscm")

# Abadie (2010) quadratic-programme weights
ab_res <- nm_scm_abadie(
  df = scm, date_col = "date", outcome_col = "SO2wn", unit_col = "ID",
  treated_unit = treated, donors = donors, cutoff_date = cutoff
)

# Difference-in-Differences baseline
did_res <- nm_did_baseline(df = scm, ..., treated_unit = treated,
                           donors = donors, cutoff_date = cutoff)

# Matrix-completion NNM
mc_res <- nm_scm_mcnnm(df = scm, ..., treated_unit = treated,
                       donors = donors, cutoff_date = cutoff)

# Robust SCM — HSVT de-noising (Amjad, Shah & Shen 2018)
rb_res <- nm_scm_robust(df = scm, ..., treated_unit = treated,
                        donors = donors, cutoff_date = cutoff)

# Bayesian SCM (Dirichlet prior + Metropolis-Hastings)
bayes_res <- nm_bayesian_scm(
  df = scm, date_col = "date", outcome_col = "SO2wn", unit_col = "ID",
  treated_unit = treated, donors = donors, cutoff_date = cutoff,
  draws = 2000, ci_level = 0.95
)
nm_plot_bayesian_scm(bayes_res, cutoff_date = cutoff)
```

### Significance tests

```r
# Conformal prediction interval on the treatment effect
ci <- nm_conformal_effect_interval(scm_res, cutoff_date = cutoff, ci_level = 0.95)

# RMSPE ratio test (placebo-in-space)
placebo <- nm_placebo_in_space(
  df = scm, date_col = "date", outcome_col = "SO2wn", unit_col = "ID",
  treated_unit = treated, donors = donors, cutoff_date = cutoff,
  scm_backend = "scm"
)
rmspe <- nm_rmspe_ratio_test(placebo, cutoff_date = cutoff)
print(rmspe$p_value)

# Placebo in time (historical falsification)
tp <- nm_placebo_in_time(
  df = scm, date_col = "date", outcome_col = "SO2wn", unit_col = "ID",
  treated_unit = treated, cutoff_date = cutoff
)
```

### Effect bands & diagnostics

```r
bands <- nm_effect_bands_space(placebo, level = 0.95, method = "quantile")
nm_plot_effect_with_bands(bands, cutoff_date = cutoff)

# Jackknife / bootstrap uncertainty
jack <- nm_uncertainty_bands(
  df = scm, ..., method = "jackknife", treated_unit = treated,
  donors = donors, cutoff_date = cutoff
)
nm_plot_uncertainty_bands(jack, cutoff_date = cutoff)

# Weight stability diagnostics
nm_scm_diagnostics(scm_res, cutoff_date = cutoff)
nm_loo_weight_stability(df = scm, ..., treated_unit = treated,
                        donors = donors, cutoff_date = cutoff)
```

---

## Multi-Site Pipelines

```r
# Normalise all sites in parallel
multi <- nm_do_all_multisite(
  df       = df_network,
  site_col = "site",
  value    = "PM2.5",
  predictors    = predictors,
  resample_vars = weather_vars,
  n_samples     = 300
)

# Apply any function across sites
nm_multisite_apply(df_network, site_col = "site", func = my_analysis_fn, n_cores = 4)
```

---

## Caching

Results are keyed by a SHA-1 hash of data + config; unchanged runs skip recomputation.

```r
# Via nm_do_all
results <- nm_do_all(df = my1, ..., cache_dir = ".normet_cache")

# Manual cache API
key  <- nm_config_hash(value = "PM2.5", n_samples = 300)
hit  <- nm_cache_load(".normet_cache", key)
if (is.null(hit)) {
  result <- my_slow_function(...)
  nm_cache_save(".normet_cache", key, result)
}
```

---

## H2O Backend

```r
nm_init_h2o()

model_h2o <- nm_train_model(
  df           = df_prep,
  value        = "value",
  backend      = "h2o",
  predictors   = predictors,
  model_config = list(include_algos = c("GBM", "XGBoost"), max_runtime_secs = 120)
)

nm_stop_h2o()
```

---

## Desktop GUI

A native Qt desktop app (`gui/`, Python + PySide6) covers the full workflow
without writing R code — every computation is delegated to this R package
through `Rscript` subprocesses, so it needs R (with `normet` installed) on
the machine that runs it. It runs on macOS, Windows, and Linux.

**Install from source:**

```bash
pip install ./gui        # from the repo root, needs Python 3.10+
normet-gui                # optionally: normet-gui mydata.csv
```

**Or download a ready-made installer** — `.dmg` (macOS), `.exe` (Windows,
Inno Setup), `.AppImage` (Linux) — built by
[`build-gui.yml`](.github/workflows/build-gui.yml)'s 3-OS matrix; grab the
latest from the workflow's **Actions → Artifacts**, or build one locally with
`gui/packaging/macos/build_dmg.sh` (macOS) or
`pyinstaller gui/packaging/normet_r_gui.spec` (any OS — see
[`gui/packaging/README.md`](gui/packaging/README.md)). R itself is never
bundled — only the bridge script; use **R → Locate Rscript…** in the app if
it isn't on `PATH`.

**Main window** — the same numbered-step workflow as the Quick Start above
(Data → Columns → Train → Normalise → Decompose → Rolling → PDP), with
results in tabs that activate as each step finishes and a traffic-light
verdict banner summarising model quality. The Train step exposes the H2O
AutoML algorithm picker (GBM/DRF/GLM/DeepLearning/StackedEnsemble/XGBoost)
when that backend is selected; the H2O cluster is started once per GUI
session and shut down on exit. An adjacent **Multi-scale decomposition**
panel differences rolling-deweathered series at increasing window widths
against Step 4's full-record baseline, isolating the meteorological residual
specific to each timescale.

**Data Studio** (🌐 toolbar button) — browse/search every UK AURN station by
the pollutants it measures or its official site code (e.g. "MY1" for London
Marylebone Road, resolved from DEFRA's station metadata), pick a date range,
and fetch hourly measurements together with meteorology from Open-Meteo (no
key) or the Copernicus CDS. The merged table can be saved as CSV or sent
straight into Step 1.

**SCM Studio** (🧪 toolbar button) — the counterfactual workflow on panel
data: map date/unit/outcome columns, pick the treated unit, cutoff and donor
pool, choose an estimator (`scm`, `mlscm`, `abadie`, `did`, `mcnnm`,
`robust`), then run fit + diagnostics, placebo-in-space/time,
jackknife/bootstrap uncertainty bands and the all-units batch — each with a
p-value / fit-quality verdict.

**Transport Studio** (🧭 toolbar button) — build transport-aware predictors
from HYSPLIT back-trajectories: parse existing `tdump` files into
per-receptor features (inflow direction, transport distance/speed, residence
time over named source regions, along-path rainfall/boundary-layer height),
preview them, then join straight onto the loaded dataset by nearest hour —
the new `traj_*` columns are auto-ticked as predictors in Step 1. An advanced
panel can also drive `hyts_std` itself, downloading the matching GDAS1
meteorology first, if HYSPLIT is installed locally.

Long computations run in the background; the window stays responsive and
tasks can be abandoned from the status bar.

---

## Dependencies

| Group        | Packages                                            |
|-------------|------------------------------------------------------|
| ML backends | `lightgbm` (optional), `h2o` (optional, needs Java) |
| Core        | `data.table`, `lubridate`, `foreach`, `doSNOW`      |
| SCM         | `glmnet`, `quadprog`                                 |
| I/O         | `httr2`, `ecmwfr` (ERA5)                             |
| Visualisation | `ggplot2`                                          |
| Base R      | `parallel`, `stats`, `utils`                        |
| GUI (optional, `gui/`) | Python 3.10+, `PySide6`, `pandas`, `matplotlib` |

---

## Citation

```bibtex
@Manual{normet-pkg,
  title        = {normet: Normalisation, Decomposition, and Counterfactual Modelling for Air Quality Time-Series},
  author       = {Congbo Song},
  year         = {2026},
  note         = {R package version 1.0.0},
  organization = {University of Manchester},
  url          = {https://github.com/apai-sys/normet-r},
}
```

---

## License

GPL-3 — see [LICENSE](LICENSE).

## Contributing

Issues and pull requests welcome: [github.com/apai-sys/normet-r](https://github.com/apai-sys/normet-r)
