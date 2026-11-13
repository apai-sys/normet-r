# normet: Normalisation, Decomposition, and Counterfactual Modelling for Air Quality Time-series

<!-- badges: start -->
[![R-CMD-check](https://github.com/apai-sys/normet-r/actions/workflows/R-CMD-check.yaml/badge.svg)](https://github.com/apai-sys/normet-r/actions/workflows/R-CMD-check.yaml)
[![Build GUI](https://github.com/apai-sys/normet-r/actions/workflows/build-gui.yml/badge.svg)](https://github.com/apai-sys/normet-r/actions/workflows/build-gui.yml)
[![GitHub R package version](https://img.shields.io/github/r-package/v/apai-sys/normet-r)](https://github.com/apai-sys/normet-r/blob/main/DESCRIPTION)
[![License: GPL-3](https://img.shields.io/badge/license-GPL--3-blue.svg)](LICENSE.md)
<!-- badges: end -->

normet is an R package for **air-quality time-series analysis**. Pollutant
concentrations depend on the weather as well as on emissions, so a raw series
cannot show on its own whether an intervention or a trend is real. normet trains a
machine-learning model of the pollutant on weather and time, then uses it to
remove the weather-driven variation ("weather normalisation", or
"de-weathering"). It splits what remains into its drivers, puts error bars on
the result, and estimates causal effects with synthetic control methods. It
covers the whole workflow, from downloading the data to the final figures.

## Features

- **Two machine-learning backends**: LightGBM (fast, in-process, the default) or
  H2O AutoML (a search over several algorithms).
- **Weather normalisation**: Monte Carlo resampling of the weather, with
  automatic detection of convergence.
- **Time-series decomposition**: separates emission-driven and meteorological
  contributions.
- **Synthetic control methods**: classic SCM, ML-SCM, Abadie, DiD, MC-NNM,
  robust and Bayesian.
- **Causal significance tests**: conformal inference, the RMSPE ratio,
  placebo-in-space and placebo-in-time.
- **Data acquisition**: built-in adapters for UK air quality (AURN, AQE, SAQN,
  WAQN, NI, LMAM), EEA Discomap, OpenAQ v3, ERA5 (Copernicus CDS or
  Open-Meteo) and HYSPLIT back-trajectories.
- **Your own tables**: CSV/TSV (any separator, decimal commas,
  UTF-8/GB18030/Windows code pages, gzipped), Excel, Parquet, Feather and JSON.
  Times can be in any common layout or format, and are put on the site's clock.
- **Multi-site pipelines**: parallel normalisation and decomposition across
  station networks.
- **On-disk caching**: SHA-1 content hashing skips repeated computation.
- **Journal-style figures**: one style for every plot (7–8.5 pt text,
  Okabe–Ito colours, formulas set as NO₂), plus diurnal/weekly/seasonal cycles
  and HTML reports in English or Chinese.
- **Desktop GUI**: a Qt app that runs the whole workflow without code.
- **AI agents**: `nm_mcp_server()` serves normet's tools to an MCP client.

## Installation

normet is not on CRAN. Install it from GitHub:

```r
# install.packages("remotes")
remotes::install_github("apai-sys/normet-r")
```

normet needs R ≥ 4.0. Model training needs at least one of the two backends,
which are optional dependencies:

```r
install.packages("lightgbm")   # default backend (recommended)
install.packages("h2o")        # alternative: H2O AutoML (needs Java)
```

Some data sources need more: OpenAQ needs a free API key (`OPENAQ_API_KEY`),
ERA5 from the Copernicus CDS needs an account and the `ecmwfr` package, and
running HYSPLIT needs a local HYSPLIT install. Open-Meteo, the UK networks
and the EEA need nothing. See
[Modelling backends](vignettes/articles/backends.Rmd) for the full list of
dependencies.

## Quick start

Normalise the bundled `my1` dataset (hourly NO2 at London Marylebone Road,
January to August 2020, with meteorology) in one call:

```r
library(normet)

covariates <- c("ws", "wd", "temp", "RH", "atmos_pres", "blh", "tcc", "tp", "ssrd")
predictors <- c(covariates, "date_unix", "day_julian", "weekday", "hour")

results <- nm_do_all(
  df            = my1,
  target        = "NO2",
  covariates    = predictors,   # what the model is trained on
  resample_vars = covariates,   # the weather that is resampled away
  n_samples     = 300
)

head(results$res)               # date | observed | normalised
nm_plot_normalise(results$res)
```

`results` also holds the trained `model` and the prepared data (`df_prep`), for
the next steps.

## Learn more

- [Getting started](vignettes/normet.Rmd): the core workflow on the bundled
  data, with output.
- [Data acquisition](vignettes/articles/data-acquisition.Rmd): your own tables,
  the UK networks, EEA, OpenAQ, ERA5 (CDS and Open-Meteo), and HYSPLIT
  trajectories.
- [Weather normalisation, step by step](vignettes/articles/normalisation-workflow.Rmd):
  prepare, train, explain, normalise, and rolling normalisation.
- [Decomposition and uncertainty](vignettes/articles/decomposition-uncertainty.Rmd):
  the emission and meteorological components, ensembles, and trends.
- [Causal inference with synthetic controls](vignettes/articles/causal-inference.Rmd):
  SCM variants, significance tests, effect bands and diagnostics.
- [Multi-site pipelines and caching](vignettes/articles/multisite-caching.Rmd).
- [Modelling backends: LightGBM and H2O](vignettes/articles/backends.Rmd).
- [Figures and reports](vignettes/articles/figures-reports.Rmd).
- [Desktop GUI](vignettes/articles/desktop-gui.Rmd).
- [NEWS](https://github.com/apai-sys/normet-r/blob/main/NEWS.md): what changed in each version.

Every function has a help page (`?nm_normalise`, `?nm_run_scm`, ...).

## Desktop GUI

A native Qt desktop app in [`gui/`](https://github.com/apai-sys/normet-r/tree/main/gui) (Python + PySide6) covers the full
workflow without writing R code. It runs every analysis on this package
through `Rscript`, and works on macOS, Windows and Linux. Install it with
`pip install ./gui` from the repository root, or download an installer built by
the [`build-gui.yml`](https://github.com/apai-sys/normet-r/blob/main/.github/workflows/build-gui.yml) workflow. See
[Desktop GUI](vignettes/articles/desktop-gui.Rmd) and the illustrated user manual
([English](https://github.com/apai-sys/normet-r/blob/main/gui/docs/manual/normet_manual.pdf),
[Chinese](https://github.com/apai-sys/normet-r/blob/main/gui/docs/manual/normet_manual_zh.pdf)).

## Citation

If you use normet, please cite it. `citation("normet")` gives the current
reference:

```
Song C (2026). normet: Normalisation, Decomposition, and Counterfactual
Modelling for Air Quality Time-Series. R package version 1.0.1,
https://github.com/apai-sys/normet-r.
```

A BibTeX entry is printed by `toBibtex(citation("normet"))`, and
[CITATION.cff](https://github.com/apai-sys/normet-r/blob/main/CITATION.cff) has the same reference for GitHub's "Cite this
repository" button.

## Contributing

Bug reports, feature requests and pull requests are welcome. Start with the
[contributing guide](CONTRIBUTING.md), and report security problems privately
as described in [SECURITY.md](SECURITY.md).

Please note that the normet project is released with a
[Contributor Code of Conduct](CODE_OF_CONDUCT.md). By contributing to this
project, you agree to abide by its terms.

## License

GPL-3. See [LICENSE.md](LICENSE.md).
