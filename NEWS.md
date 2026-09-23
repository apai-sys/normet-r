# normet 1.0.0

### Changed (breaking)

* **Public API argument rename**: to match the equivalent rename in the sibling
  `normet-py` package, the following parameter names are renamed everywhere
  they appear across the package's public API: `value` → `target`,
  `predictors` → `covariates`, `na_rm` → `dropna`, `fraction` → `train_fraction`.
  Affected functions include `nm_normalise()`, `nm_decompose()`/`nm_decom_emi()`/
  `nm_decom_met()`, `nm_rolling()`, `nm_mlscm()`, `nm_build_model()`/
  `nm_train_model()`, `nm_train_h2o()`/`nm_train_lgb()`, `nm_do_all()`/
  `nm_do_all_unc()`/`nm_do_all_multisite()`/`nm_decompose_multisite()`,
  `nm_config_single()`/`nm_config_rolling()`, `nm_cv_score()`, and
  `nm_plot_polar()`/`nm_plot_time_series()` (as well as `nm_prepare_data()`,
  `nm_check_data()`, `nm_impute_values()`, and `nm_split_into_sets()`, renamed
  in a preceding pass). Call sites using positional arguments are unaffected;
  any call using `name = value` syntax with the old argument names must be
  updated. The `gui/normet_r_gui/bridge.R` task protocol (and the Python GUI
  frontend that invokes it) is renamed in lockstep: the `value=`/`predictors=`/
  `fraction=` key=value tokens are now `target=`/`covariates=`/`train_fraction=`.
* **Backends**: H2O is now an optional (`Suggests`) dependency rather than the
  required default; the lightgbm path (`nm_train_lgb`, `nm_predict_lgb`,
  `nm_normalise_lgb`) runs without it. The package was also restructured into
  focused `nm_*` modules.
* **Lag diagnostics**: added `nm_analyze_lag()` — a target's ACF/PACF plus the
  pre-whitened cross-correlation (CCF) with a meteorological driver — to suggest
  autoregressive and predictive lags for `nm_add_lag_features()`. Box–Jenkins
  pre-whitening avoids spurious seasonal peaks; `lag k>0` means the driver leads
  the target by `k` rows. Ships with `print`/`plot` methods for the result.
* **ERA5**: dropped the gridded NetCDF path (`nm_fetch_era5_at_sites`,
  `nm_download_era5`, `sample_netcdf_at_sites`) and the `ncdf4` dependency.
  ERA5 meteorology is now fetched as pre-interpolated single-point
  time-series via `nm_fetch_era5_timeseries` (CDS, `ecmwfr` only).
* **SCM**: added the `robust` backend — `nm_scm_robust()` (HSVT de-noising;
  Amjad, Shah & Shen 2018), also selectable via
  `nm_run_scm(scm_backend = "robust")`.
* **Transport features**: added a HYSPLIT back-trajectory adapter —
  `nm_read_trajectory_tdump()`, `nm_trajectory_features()`,
  `nm_build_trajectory_features()`, and `nm_run_back_trajectories()` (drives
  `hyts_std` end-to-end) — to turn `tdump` output into transport-aware
  predictors (inflow direction, distance/speed, residence time over source
  regions, along-path rainfall/BLH).
* **Trajectory quality columns and `min_hours`**: `nm_trajectory_features()` /
  `nm_build_trajectory_features()` / `nm_run_back_trajectories()` now emit
  `traj_n_endpoints` and `traj_age_max_h`, and take `min_hours`. A trajectory
  that HYSPLIT ended early (met files ran out, or it left the domain) used to
  be indistinguishable from a legitimately short-range one: its `dist_km`
  shrank and its residence fractions were taken over fewer points, with no
  flag. `min_hours` sets every feature except the two quality columns to `NA`
  for such rows; it is opt-in, so existing tables only gain two columns.
  `nm_run_back_trajectories()` warns about truncated runs either way. Mirrors
  `normet-py`.
* **`nm_run_back_trajectories()` met-file window is padded by one GDAS1 record**:
  each run is handed only the weekly files whose dates overlap
  `[receptor - hours_back, receptor]`, but a receptor time between one file's
  last record and the next file's first needs *both* to interpolate. Probed
  against `hyts_std` with two adjacent daily ARL files, a start time in that gap
  (23:30, 23:59) failed with only the earlier file and ran with both, so the
  strict overlap test broke hourly receptors in the last hours of every weekly
  file (00/06/12/18 UTC releases were unaffected). The window is now widened by
  3 h on each side. Mirrors `normet-py`.
* **`nm_build_trajectory_features()` warns when source regions overlap**: an
  endpoint inside several regions counts towards each, so overlapping regions'
  residence fractions add up to more than 1 and are not shares of the
  trajectory. The warning names the overlapping pairs (boxes directly, sf
  geometries via sf); regions that only touch do not count. Mirrors `normet-py`.
* **GDAS1 met download**: `nm_fetch_gdas1()` / `nm_gdas1_filenames()` pull the
  weekly GDAS1 (1°) ARL files from NOAA ARL's archive (streamed + cached) so
  `nm_run_back_trajectories()` can run when no local met is available.
* **UK air quality**: `nm_list_ukaq_stations()` / `nm_fetch_ukaq_measurements()`
  replace `nm_list_aurn_stations()` / `nm_fetch_aurn_measurements()` (removed,
  along with `nm_aurn_pollutant_codes`). Covers all six UK networks (AURN, AQE,
  SAQN, WAQN, NI, LMAM — around 1500 stations) from the openair `.RData`
  archives via `source = "aurn"`/`"aqe"`/`"saqn"`/`"waqn"`/`"ni"`/`"local"`, or
  DEFRA's live SOS API (AURN only, near-real-time rolling window) via
  `source = "aurn_live"` — both behind the same interface and returning the
  same schema (`aurn_live` rows leave `site_type`/`start_date`/`end_date` as
  `NA`, which the SOS API does not carry). Mirrors `normet-py`'s
  `normet.io.ukaq` argument for argument.

# normet 0.0.1

* Initial CRAN-like release.
* Core features: meteorological normalisation, time-series decomposition, synthetic control methods (SCM/ML-SCM).
* Backends: H2O AutoML (default), lightgbm.
* Uncertainty quantification: bootstrap, jackknife, placebo-in-space, placebo-in-time.
