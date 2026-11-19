# Installation

`normet` supports R 4.0 and later on macOS, Windows and Linux. Install the
released version from CRAN:

```r
install.packages("normet")
```

The development version is on GitHub:

```r
# install.packages("remotes")
remotes::install_github("apai-sys/normet-r")
```

Or from a local clone:

```r
# from the repository root
remotes::install_local(".")
```

## Model backends

The package installs without a model backend, but training needs at least one.
Both are optional dependencies (`Suggests`), so `library(normet)` never fails
because one is missing; the training call raises an error naming the package to
install.

```r
install.packages("lightgbm")   # default backend: fast, in-process
install.packages("h2o")        # alternative: H2O AutoML (needs Java)
```

`lightgbm` is the default for every pipeline (`backend = "lightgbm"`). The H2O
backend (`backend = "h2o"`) searches several algorithms; its `model_config`
takes `max_models` (models to train; Stacked Ensembles not counted),
`max_runtime_secs` (a safety cap) and `include_algos`. An H2O run needs a
cluster: `nm_init_h2o()` starts one, and `nm_stop_h2o()` shuts it down (the
pipelines start and stop it themselves where needed).

## Optional packages

Everything else is optional and imported lazily. The function that needs a
package raises an error naming it.

| Package | Used for |
|---|---|
| `lightgbm` | The default backend (`backend = "lightgbm"`) |
| `h2o` | The AutoML backend (`backend = "h2o"`; needs Java) |
| `arrow` | Parquet and Feather tables (`nm_read_table`) |
| `readxl` | Excel tables (`.xlsx`, `.xls`) |
| `ecmwfr` | ERA5 from the Copernicus CDS (`nm_fetch_era5_timeseries`) |
| `sf` | Polygon source regions for trajectory features (`nm_load_source_regions`) |
| `memuse` | Memory estimates for large jobs |
| `patchwork` | The one-figure SCM dashboard (`nm_plot_scm_dashboard`) |
| `forecast` | STL-residual event detection (`nm_detect_events(method = "stl_residual")`) |
| `solitude` | Isolation-forest anomaly scores (`nm_anomaly_scores(method = "isolation")`) |

## Data sources

Most adapters run on the package's own dependencies. Two need credentials, one
needs a local program:

| Source | Needs |
|---|---|
| UK networks (AURN, AQE, SAQN, WAQN, NI, LMAM) | Nothing |
| EEA reporting network | Nothing |
| Open-Meteo (ERA5-derived meteorology) | Nothing |
| OpenAQ | A free API key in `OPENAQ_API_KEY` (or passed as `api_key =`) |
| ERA5 via the Copernicus CDS | A CDS account stored with `ecmwfr::wf_set_key()`, and `ecmwfr` |
| HYSPLIT back-trajectories | A local HYSPLIT install (`hyts_std`); GDAS1 met can be downloaded with `nm_fetch_gdas1()` |

## Desktop app

The desktop GUI lives in [`gui/`](https://github.com/apai-sys/normet-r/tree/main/gui)
(Python + PySide6) and drives this package through `Rscript`. From a clone:

```bash
pip install ./gui
normet-r-gui                 # optionally: normet-r-gui mydata.csv
```

It needs `Rscript` on `PATH` and `normet` installed in that R. Ready-made
installers (`.dmg` on macOS, `.exe` on Windows, `.AppImage` on Linux) are built
by the [`build-gui.yml`](https://github.com/apai-sys/normet-r/actions/workflows/build-gui.yml)
workflow's 3-OS matrix — grab the latest from **Actions → Artifacts**. See
[the GUI guide](../guide/gui.md) for a tour of the window.

## Checking the installation

```r
library(normet)
packageVersion("normet")
citation("normet")

# Which backends are available?
requireNamespace("lightgbm", quietly = TRUE)
requireNamespace("h2o", quietly = TRUE)
```

The quick start runs the whole pipeline on the bundled `my1` data; see
[Quick start](quickstart.md).

## Dependencies

| Group | Packages |
|---|---|
| Core | `data.table`, `digest`, `dplyr`, `doParallel`, `foreach`, `ggplot2`, `httr2`, `jsonlite`, `lgr`, `lubridate`, `magrittr`, `memoise`, `parallel`, `progress`, `quadprog`, `rlang`, `scales`, `zoo` |
| Backends | `lightgbm` (default) or `h2o` |
| Tables | `arrow`, `readxl` |
| Data adapters | `ecmwfr` (ERA5 CDS) |
| Trajectories | `sf` (polygon source regions) |
| Figures | `patchwork` (SCM dashboard) |
