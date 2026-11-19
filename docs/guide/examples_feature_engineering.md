# Feature engineering

`normet` provides a few light helpers for building predictors from tidy,
long-format time-series (a `date` column plus one row per timestamp). They
never mutate the input and are happy with per-station panels via `group_col`.

```r
library(normet)

df <- nm_add_lag_features(df, cols = c("ws", "blh"),
                           lags = c(1, 3, 24), group_col = "station")
df <- nm_add_rolling_features(df, cols = c("pm25"), windows = c(24),
                               aggs = "mean")
df <- nm_cyclical_encode(df, col = "hour", period = 24)
uv <- nm_wind_to_uv(df$ws, df$wd)   # data frame with u, v
```

- `nm_add_lag_features(df, cols, lags, group_col, date_col, suffix)` appends
  `<col><suffix><lag>` columns, computed within each group when `group_col`
  is given.
- `nm_add_rolling_features(df, cols, windows, aggs, min_periods, group_col,
  date_col, suffix, causal)` appends rolling summaries. `causal = TRUE` (the
  default) uses only past and current values, so a row's predictor never
  contains its own future.
- `nm_cyclical_encode(df, col, period, drop, prefix)` turns an integer cycle
  (hour of day, month) into sine/cosine pairs.
- `nm_wind_to_uv(speed, direction_deg, convention)` returns `u` and `v` from
  wind speed and direction (`"meteorological"`: the direction the wind is
  *from*, clockwise from North; `"oceanographic"`: the direction it is
  *toward*).

## Choosing meteorology–pollution lags

The lags you pass to `nm_add_lag_features()` are a modelling choice, not
something the helper guesses for you. To pick them in a data-driven way, use
`nm_analyze_lag()`, which returns a full lag-structure diagnostic:

- **ACF / PACF** of the target — how persistent the pollutant is, and which of
  its *own* past values to include as autoregressive lags.
- **Cross-correlation (CCF)** between a meteorological driver and the
  pollutant — how many steps the driver *leads* the pollutant.

```r
diag <- nm_analyze_lag(
  df       = df,
  target   = "pm25",
  driver   = "ws",
  max_lag  = 48,       # rows (hours, if hourly)
  prewhiten = TRUE     # recommended — see below
)

diag$peak_lag
diag$driver_lags
diag$target_ar_lags
```

The object has class `nm_lag_diagnostics`: lists `acf`/`pacf` (and `ccf` when
a driver is given) as data frames of `lag`/`value`, the suggested
`target_ar_lags` and `driver_lags`, the `peak_lag`, and the significance
`band`.

The CCF sign convention matches `nm_add_lag_features()` for `k > 0`: a
`peak_lag` of 8 means `nm_add_lag_features(df, cols = "ws", lags = 8)` is the
predictor to add. Lag 0 is contemporaneous and has no counterpart in
`nm_add_lag_features()` — the raw column already carries it.

### Why pre-whitening matters

Meteorology and pollution both carry strong diurnal and seasonal cycles and
are heavily autocorrelated. A naive CCF on the raw series is dominated by that
*shared seasonality* and produces spurious peaks at many lags. With
`prewhiten = TRUE` (the default), `nm_analyze_lag()` performs Box–Jenkins
pre-whitening: it fits an AR(p) to the driver (order chosen by AIC up to
`max_ar`), takes its innovations as the whitened driver, and filters the
target with the same AR polynomial before computing the CCF. The peak that
survives is a credible lead–lag, not an artefact of the daily cycle. If
pre-whitening fails (e.g. too few points), it warns and falls back to the raw
CCF.

For a regularly spaced series this is essential; `nm_analyze_lag()` sorts by
`date` and assumes regular spacing, dropping non-finite values pairwise. For
multi-site panels, call it once per site (pass a single-site slice).

### From diagnostic to model

A typical workflow turns the diagnostic into predictors and lets the learner do
the final selection:

```r
diag <- nm_analyze_lag(df, target = "pm25", driver = "ws", max_lag = 48)

# driver_lags may include lag 0 (contemporaneous), which the helper rejects;
# drop it and fall back to the peak, or lag 1 if the peak is 0/NULL.
lags <- diag$driver_lags[diag$driver_lags > 0]
if (length(lags) == 0) lags <- if (is.null(diag$peak_lag) || diag$peak_lag == 0) 1 else diag$peak_lag

df <- nm_add_lag_features(df, cols = "ws", lags = lags)
df <- nm_add_lag_features(df, cols = "pm25",
                           lags = if (length(diag$target_ar_lags)) diag$target_ar_lags else 1)

# ... then train as usual; LightGBM weights the lags via importance.
```

Run `nm_analyze_lag()` once per driver (`blh`, `tp`, `t2m`, …) to assemble the
lag set for each meteorological variable.
