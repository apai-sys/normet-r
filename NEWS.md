# normet 1.0.0

### Added

* **Trend**: added `nm_trend()` — the Mann-Kendall test (with the seasonal
  Sen 1968 variant) and the Theil-Sen slope with its Sen (1968) interval on a
  series, plus `nm_mann_kendall()` and `nm_theil_sen()` as standalone exports.
  Where the record's residuals carry AR(1) signal the Theil-Sen interval is
  replaced by the block-bootstrap interval and a Wald p (the block is the
  longer of the Politis-Romano 3 n^(1/3) heuristic and one calendar week for
  sub-daily records), because the classical MK p is anti-conservative there.
  Added `nm_trend_breaks()` — where the trend breaks: a greedy segmentation
  gated by BIC, each segment with its own Theil-Sen slope and Sen interval,
  and the block-bootstrap p of the search over every candidate position, the
  multiple-testing-corrected, autocorrelation-aware test to quote. A result's
  `value_col` may name `"long-term"`, the emission decomposition's separated
  long-term component (`date_unix + emi_base`), computed natively. Mirrors
  `normet-py` (PRs #52, #56); the deterministic statistics agree with it to
  the last digit, the bootstrap draws differ (different RNG streams, same
  math).
* **Verification**: added probabilistic scoring — `nm_crps_from_quantiles()`
  (the exact integral of the squared CDF distance, not a pinball sum),
  `nm_crps_from_samples()` (each sample stands at its rank's level),
  `nm_crps_observed()` and `nm_pinball_loss()`. A frame's `qNNN` columns name
  their own levels. Mirrors `normet-py` (PR #53).
* **Uncertainty decomposition**: added `nm_decompose_uncertainty()` — of the
  total band around a de-weathered estimate, how much is the met resampling
  and how much the model form. `n_models` members (each trained on its own
  seed) predict on the *same* `n_samples` met draws (the user's seed, the
  common-random-number anchor), and the per-date variance of the
  (n_models, n_samples) response splits orthogonally into the weather, model
  and interaction terms; the total is the three summands exactly, to
  floating point. The result carries `summary()` (per-source median variance
  and share), `as.data.frame()`, `plot()` (the stacked bands) and `print()`.
  Mirrors `normet-py` (PR #57).
* **Pre-trend test**: added `nm_pre_trend_test()` — whether the pre-period of
  a synthetic-control fit was parallel: the OLS slope of the pre-period
  residuals (observed minus synthetic) against the period index with its
  classical two-sided t-test, and the RMSPE of the final third of the
  pre-period over that of the first two thirds, read together as a traffic
  light: `fail` when the slope is significant at the 1 % level, `caution`
  when it is significant at `alpha` or the drift ratio exceeds 1.25, `ok`
  otherwise. `nm_scm_diagnostics()` carries it under `pre_trend` and the
  agent's SCM reading quotes it. Mirrors `normet-py` (PR #61).
* **Event-study figure**: added `nm_plot_event_study()` — the visual
  companion of `nm_pre_trend_test()`: the treated effect against event time
  (periods, not calendar days), the pre-period in the neutral grey and the
  post-period in the modelled red, an optional placebo band drawn over the
  post-period only. Accepts an SCM `synthetic` frame or a `treated` list as
  `nm_placebo_in_time()` returns it, and a band either aligned by row
  position (`nm_effect_bands_time()`) or by date (`nm_effect_bands_space()`);
  band columns are read as `ci_lo`/`ci_hi`, `lower`/`upper`, `low`/`high` or
  `p10`/`p90`. Mirrors `normet-py` (PR #62).
* **Agent / MCP**: `normet_trend` and `normet_trend_breaks` join the tools the
  assistant drives normet with (and the MCP server serves): the trend test of
  one column of a result table, synchronous, with the same readings the window
  shows. The MCP instructions now say a trend is what `normet_trend` says, and
  the corrected p it names is the one to quote.

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
* **`nm_decom_met()`: feature groups and Shapley attribution.** `groups =`
  attributes the meteorological features in named groups -- e.g.
  `list(local = met_cols, transport = traj_cols)` -- with one result column per
  group, and `attribution = "shapley"` averages each feature's or group's
  marginal effect over every order it could be frozen in, instead of freezing
  them one at a time (which makes the split depend on the order, and the
  default order on fitted importance). Shapley values are exact (all `2^k`
  coalitions, up to 10 features or groups -- four normalisations for two
  groups) or, with `n_permutations =`, sampled in antithetic pairs; either way
  the contributions add up exactly to the prediction minus `emi_total`. Groups
  default to Shapley; without groups the default stays sequential and its
  results are unchanged (checked `identical()` against the previous code).
  Also on `nm_decompose()`. Mirrors `normet-py`.
* **`resample_pools =` draws chosen variables from their own pool**
  (`nm_normalise_lgb()` / `nm_normalise_h2o()`, and via `nm_normalise()`,
  `nm_decom_met()`, `nm_decom_emi()`, `nm_decompose()`). A pool's columns name
  the variables drawn from it -- whole rows at a time, independently of
  `resample_df` and of the other pools. With a single pool every contribution
  is measured against the *average* conditions in it, so a transport term is
  an anomaly with a mean near zero; `list(transport = clean_hours[, traj_cols])`
  measures transport against a reference air mass instead. Each pool draws
  from its own seed stream, derived from its name, so a variable's draws do
  not move when others are frozen, nor when other pools are added or renamed;
  without pools the draws are unchanged.
  `nm_decom_met()` / `nm_decom_emi()` also take `conditional_on =`, applied to
  the `resample_df` pool. Mirrors `normet-py`.
* **Fixed: `nm_decom_met()` / `nm_decom_emi()` with `model = NULL` failed when a
  covariate was missing** ("arguments imply differing number of rows"): the
  observed series was taken before training, while `nm_build_model()` drops
  rows with a missing covariate. It is now taken from the frame actually
  decomposed.
* **Fixed: a feature listed twice in `nm_decom_met()`'s `variable_order`**
  failed deep inside the resampling with a data.table duplicate-column error;
  it is now refused up front with a clear message. `met_noise` is documented as
  what it is -- the model residual shifted by `met_base` -- rather than
  "unexplained meteorological variance".
* **GUI in Chinese** (View -> Language: Follow System / English / 中文): every
  label, button, menu, tab, tooltip and dialog is translated as it is set, and
  figures' texts as they are drawn, while the code still reads the English back.
  Data's own words (column names, backends, file names) stay as written. The
  translation engine and its catalogue are `normet-py`'s own (`uilang.py`,
  `_i18n.py`, `ui_zh.py`, kept as they are there); this window's own texts are
  in `ui_zh_r.py`. The HTML report the GUI exports follows the window's
  language, and is now written as UTF-8 on every platform.
* **`nm_join_trajectory_features()`** joins a trajectory feature table onto a
  panel backward: a row takes the latest trajectory to have arrived, less than
  one release interval before it (inferred: the commonest step between one
  site's successive trajectories), so a window whose run is missing stays empty.
  A nearest-time join handed 04:00 and 05:00 the 06:00 trajectory -- air that
  had not arrived -- and, without a tolerance, filled every row before the first
  and after the last. With a `site` column in both frames each row takes only
  its own site's trajectories and other sites' rows are left alone, so sites can
  be joined a batch at a time; a column sent again is replaced. Times are
  compared as UTC. The GUI's *Send to main window* uses the same rule, and says
  when no row took a trajectory instead of reporting a join that had not
  happened. Mirrors `normet-py`.
* **Fixed: `nm_build_trajectory_features()` kept one start height of several.**
  Rows were de-duplicated on the receptor time alone, so a run started at 100,
  500 and 1500 m came back as the 1500 m trajectory's row. Each height now has
  its own columns (`traj_dist_km_500m`, ...), and tdumps that start from
  different places are refused instead of interleaved. Mirrors `normet-py`.
* **`nm_run_back_trajectories()` fixes.** A tdump an earlier call left in a
  reused `work_dir` is removed before its run (a failed run used to pass it off
  as its own). Receptor times are run on UTC whatever their time zone, and text
  with an offset is converted by it; a time off the hour passes its minutes to
  `CONTROL` and its tdump name; repeated times run once and `NA` is skipped.
  Times no met file covers are skipped with one warning instead of each being
  handed every file to fail on, and `stop =` (a function polled before each
  run) ends a long batch, returning what was run. Mirrors `normet-py`.
* **Reading tables and their times.** `nm_read_table()` reads delimited text
  (separator, decimal comma, UTF-8/GB18030/Windows-1252 and gzip settled from the
  file), Excel (via readxl), Parquet/Feather (via arrow) and JSON;
  `nm_find_dates()` finds the times in a named column, a date plus a time
  column, or year/month/day/hour columns; `nm_parse_dates()` reads them in any
  common form (ISO 8601 with `T` and offsets, day- or month-first as the column
  shows, month names, AM/PM, CJK-written dates, Unix seconds or milliseconds,
  Excel serial days, `20200131`); `nm_on_clock()`, `nm_clock_to_utc()` and
  `nm_utc_to_clock()` move times between a site's local clock and UTC (a
  skipped hour goes forward to the change, a repeated one is taken in order);
  `nm_read_time_series()` does all of it. Mirrors `normet-py`'s `normet.io.tables`.
* **Fixed: `nm_process_date()` dropped the time from ISO dates and ignored
  their offsets.** `as.POSIXct("2020-01-01T13:00:00")` reads midnight, and
  `"... 13:00+01:00"` reads 13:00 UTC; text dates are now parsed value by value,
  each offset applied on its own -- so local times across a daylight-saving
  change (`+00:00` in winter, `+01:00` in summer) come out as UTC in order. The
  R counterpart of `normet-py`'s mixed-offset fix.
* **Figures in a journal style.** `nm_theme_normet()`: 7-8.5 pt text, 0.6 pt
  axes with ticks outward, frameless legends, a faint grid; `nm_palette`
  (Okabe-Ito) and `nm_colours` (observed blue, normalised/synthetic red, context
  grey, one meaning each); `nm_formula()` sets NO2, PM2.5, SO42- as chemistry
  writes them (Unicode, or plotmath for the PDF device). Every `nm_plot_*()`
  draws in it, with short date axes, series broken at gaps and line widths that
  follow a series' density. `nm_plot_pdp_grid()` marks each variable's deciles
  (`data =`) and draws whole-valued variables as steps; `nm_plot_scm_dashboard()`
  takes `ylabel =`. Mirrors `normet-py`'s `normet.style`.
* **`nm_plot_rolling()`** draws `nm_rolling()`'s windows as the window does: their
  mean, a band of one standard deviation where windows overlap, and the observed
  series behind (`data = df_prep`).
* **Fixed: `nm_plot_decomposition_stack()` stacked a total with its parts.** On
  `nm_decompose()`'s output it stacked `emi_total` (or `met_total`) beside the parts
  it is the sum of, counting them twice; by default (`exclude = NULL`) the total is
  left out now, so the emission stack adds up to `emi_total` and the meteorology
  stack to `observed`.
* **Fixed: sub-daily series were drawn on days.** `nm_plot_normalise()`,
  `nm_plot_decomposition_stack()`, the SCM plots and `nm_plot_effect_with_bands()`
  converted times to `Date`, so an hourly record put 24 points on each day; they
  keep the times now. `nm_plot_polar()` put north on the left (`start = -pi/2`)
  and stretched the circle over the data's directions; it now reads as a compass.
* **`nm_cycle_profiles()`** draws a record's mean by hour of day, day of week and
  month with 95% confidence intervals (or the IQR), as openair's
  `timeVariation`; the cycles default to those the record can show. Mirrors
  `normet-py`'s `cycle_profiles`.
* **Reports and figures in Chinese.** `nm_generate_html(lang = "zh")` writes the
  report's headings, labels and figure in Chinese; `options(normet.lang = "zh")`
  does the same for any figure's own texts. The words are `normet-py`'s.
* **`nm_scm()` documents what its pre-period fit can and cannot show**: the
  ridge features include the treated unit's own pre-period outcomes, so the fit
  flatters the counterfactual more the more donors there are (pure noise is
  fitted with a pre-period R-squared of 0.47 from the bundled panel's 103
  donors). Mirrors `normet-py`.

# normet 0.0.1

* Initial CRAN-like release.
* Core features: meteorological normalisation, time-series decomposition, synthetic control methods (SCM/ML-SCM).
* Backends: H2O AutoML (default), lightgbm.
* Uncertainty quantification: bootstrap, jackknife, placebo-in-space, placebo-in-time.
