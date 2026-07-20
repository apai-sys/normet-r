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
* **GDAS1 met download**: `nm_fetch_gdas1()` / `nm_gdas1_filenames()` pull the
  weekly GDAS1 (1°) ARL files from NOAA ARL's archive (streamed + cached) so
  `nm_run_back_trajectories()` can run when no local met is available.

# normet 0.0.1

* Initial CRAN-like release.
* Core features: meteorological normalisation, time-series decomposition, synthetic control methods (SCM/ML-SCM).
* Backends: H2O AutoML (default), lightgbm.
* Uncertainty quantification: bootstrap, jackknife, placebo-in-space, placebo-in-time.
