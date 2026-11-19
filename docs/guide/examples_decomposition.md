# Time-series decomposition

The snippets continue from the quick start's `results`: `df_prep` and `model`
are its prepared frame and trained model, and `predictors` its covariate list.

`normet` exposes two decomposition strategies through a single entry point:

```r
nm_decompose(method = "emission",    df = df_prep, model = model, covariates = predictors)
nm_decompose(method = "meteorology", df = df_prep, model = model, covariates = predictors)
```

Both are nested-normalisation routes built on `nm_normalise()`: they take
variables out of the resample pool (holding them at their observed values)
and difference the resulting series to peel off each component's contribution.

## Emission (temporal trends)

The `"emission"` path successively removes a time variable (`date_unix`,
`day_julian`, `weekday`, `hour`) from the resample pool to peel off temporal
trends, giving a hierarchical attribution (trend → seasonality → diurnal).

```r
df_emi <- nm_decompose(
  method = "emission", df = df_prep, model = model, covariates = predictors
)
# columns: date, observed, date_unix, day_julian, weekday, hour,
#          emi_total, emi_base, emi_noise
```

Each named time column holds that level's marginal contribution; `emi_total`
is the combined emission-driven signal, split into a constant `emi_base` and a
zero-mean `emi_noise`.

## Meteorology (weather effects)

The `"meteorology"` path starts from `emi_total`, the normalised series with
every meteorological predictor resampled, and splits the model's prediction
minus `emi_total` into one contribution per predictor.

```r
df_met <- nm_decompose(
  method = "meteorology", df = df_prep, model = model, covariates = predictors
)
# columns: date, observed, emi_total, <each met feature>,
#          met_total, met_base, met_noise
```

`met_total` (= `observed − emi_total`) equals `met_base` (its mean) plus the
contributions plus `met_noise`, and `met_noise` is the model residual
(`observed − prediction`) shifted by `met_base` — what the model does not
explain, not a weather term.

By default the predictors are fixed one at a time in order of feature
importance (`attribution = "sequential"`). That is cheap, but each
contribution is conditional on the predictors fixed before it, so the split
changes with the order — and importance can reorder when the model is
refitted. Pin it with `variable_order =`, or remove the order altogether with
`attribution = "shapley"`, which averages each predictor's effect over every
order (exact for up to 10 predictors; pass `n_permutations =` for a sampled
estimate beyond that).

### Grouped attribution: transport vs local

To separate long-range transport from local meteorology, attribute the two
sets of predictors as groups. Groups default to Shapley attribution, and with
two groups that costs four normalisations:

```r
df_tr <- nm_decompose(
  method = "meteorology", df = df_prep, model = model, covariates = predictors,
  groups = list(local = met_cols, transport = traj_cols)
)
# columns: date, observed, emi_total, local, transport,
#          met_total, met_base, met_noise
```

Both columns are measured against `emi_total`, which averages over the air
masses in the resample pool, so over the record they are anomalies with a mean
near zero. To measure transport against a reference air mass instead, draw the
trajectory predictors from a pool of their own:

```r
clean <- df_prep[df_prep$traj_resid_atlantic > 0.8, ]

df_ref <- nm_decompose(
  method = "meteorology", df = df_prep, model = model, covariates = predictors,
  groups = list(local = met_cols, transport = traj_cols),
  resample_pools = list(transport = clean[traj_cols])
)
```

`emi_total` is then the level under clean Atlantic air with average local
weather, and `transport` the change from that air mass to the one that
actually arrived. A pool's columns name the predictors drawn from it; the
local weather is still drawn from the whole record (`resample_df`, filtered by
`conditional_on` if given).

If you omit `model`, `nm_decompose()` trains one for you — pass `backend`
(and optionally `model_config`) so it knows how.

## Plotting

```r
nm_plot_decomposition_stack(df_emi)
nm_plot_decomposition_stack(df_met, exclude = c("observed", "met_noise"))
```

The stack plot draws every component column except the observed series and
anything in `exclude`, with the observed series as a thin dark line.

## Trend on the emission component

The emission decomposition is the natural input to the trend tests; see
[Trend analysis](examples_trend.md):

```r
nm_trend(df_emi, value_col = "emi_total", name = "MY1 NO2 emission-driven")
nm_trend_breaks(df_emi, value_col = "long-term", name = "MY1 NO2 long-term")
```
