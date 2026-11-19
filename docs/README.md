# normet documentation

`normet` is an R package for **air-quality time-series analysis**: it trains a
model of a pollutant on weather and time, removes the weather-driven variation
("weather normalisation"), decomposes what remains into its drivers, and
estimates policy effects with synthetic control methods.

This folder mirrors the user guide of the sibling Python package
[`normet-py`](https://github.com/apai-sys/normet-py), written for the R API:
every function is `nm_*`, and every pipeline runs on the `normet` R package
itself. It is excluded from `R CMD build` (`.Rbuildignore`), so it ships with
the repository rather than with the installed package.

## Getting started

- [Installation](getting_started/installation.md) — R, the two model backends,
  and the optional packages behind specific features.
- [Quick start](getting_started/quickstart.md) — the whole normalisation
  pipeline on the bundled `my1` data, in one call.

## User guide

- [Step-by-step workflow](guide/workflow.md) — the pipeline one step at a time,
  then decomposition, synthetic control and the options for larger studies.
- [Weather normalisation](guide/examples_normalisation.md) — quantile bands,
  "what-if" weather and log-scale fits.
- [Feature engineering](guide/examples_feature_engineering.md) — lag, rolling
  and cyclical predictors, and choosing meteorology–pollution lags.
- [Time-series decomposition](guide/examples_decomposition.md) — the emission
  and meteorological components, grouped attribution and Shapley splits.
- [Trend analysis](guide/examples_trend.md) — Mann-Kendall and Theil-Sen with
  the block-bootstrap correction, and segmented trends.
- [Uncertainty decomposition](guide/examples_uncertainty.md) — attributing a
  de-weathered band to weather, model form and their interaction.
- [Synthetic-control modelling](guide/examples_scm_guide.md) — backends,
  diagnostics, pre-trend tests, inference and staggered adoption.
- [Bayesian SCM](guide/examples_scm.md) — the Dirichlet-weighted Bayesian SCM,
  start to finish.
- [Multi-site pipelines](guide/examples_multisite.md).
- [Caching and provenance](guide/examples_caching.md).
- [Data adapters](guide/examples_data_adapters.md) — your own tables, the UK
  networks, EEA, OpenAQ, ERA5, Open-Meteo and HYSPLIT trajectories.
- [Worked example: OpenAQ + ERA5](guide/examples_openaq.md).
- [Plotting](guide/examples_plotting.md) — polar plots, bands, PDP grids and
  the decomposition stack.

## Interfaces

- [Desktop GUI](guide/gui.md) — the Qt window that runs the workflow without
  code.
- [AI assistants (MCP server)](guide/mcp.md) — serving normet's tools to
  Claude Code, Claude Desktop or any other MCP client.

## Reference

- The package's pkgdown configuration (`_pkgdown.yml`) and the
  `vignettes/articles/` folder carry the R-native long-form documentation:
  data acquisition, the normalisation workflow, decomposition and uncertainty,
  causal inference, multi-site work and caching, backends, figures and reports,
  and the desktop GUI.
- Every function has a help page (`?nm_normalise`, `?nm_run_scm`, ...).
- What changed in each version: [NEWS.md](../NEWS.md). Planned work:
  [roadmap](roadmap.md).
