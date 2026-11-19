# Synthetic-control modelling

`normet` ships seven backends, all callable through `nm_run_scm()`:

| Backend | Estimator | When to use |
|---|---|---|
| `scm` | Ridge-augmented SCM (default) | Most cases; robust to noisy donors |
| `mlscm` | ML-SCM (**experimental**) | Many donors, non-linear donor–outcome relationships |
| `abadie` | Classic Abadie simplex SCM | Sparse donor pool; transparent weights |
| `did` | Difference-in-differences baseline | Sanity check against parallel trends |
| `mcnnm` | Matrix completion (Athey et al. 2021) | Highly unbalanced panels; missing observations |
| `robust` | Robust SCM — HSVT de-noising (Amjad 2018) | Noisy/low-rank donor matrices; measurement error |
| `bayesian` | Bayesian SCM with Dirichlet weights | A posterior over the weights and the effect |

```r
out <- nm_run_scm(
  df = panel,
  date_col = "date", unit_col = "code", outcome_col = "NO2_dw",
  treated_unit = "MY1", donors = donors,
  cutoff_date = "2019-04-01",
  scm_backend = "scm"
)
head(out)   # date | observed | synthetic | effect
```

## Diagnostics

After fitting, get a quality report and donor-stability summary:

```r
diag <- nm_scm_diagnostics(out, cutoff_date = "2019-04-01")
# pre_n, pre_rmse, pre_mae, pre_mape, pre_r2
# post_n, att, att_cum, post_rmse
# hhi, effective_n_donors, n_donors, top_donors, top_donor_share
# pre_trend (the nm_pre_trend_test() result)

stability <- nm_loo_weight_stability(
  df = panel, date_col = "date", unit_col = "code", outcome_col = "NO2_dw",
  treated_unit = treated, donors = donors, cutoff_date = cutoff
)
# dropped_donor, mean_abs_drift, max_abs_drift, effect_shift
```

## Pre-trend and event study

The parallel-trends check a reviewer asks for first: is the treated unit
tracking its synthetic control *before* the intervention?

```r
pre <- nm_pre_trend_test(out, cutoff_date = "2019-04-01")
print(pre)      # verdict: ok / caution / fail / insufficient
pre$slope; pre$p_slope; pre$rmpe_drift
```

`ok` means the pre-period residuals show no slope at the 5% level and the
RMS-prediction-error of the last third of the pre-period is within 1.25× of
the first two thirds. `fail` is a significant slope at the 1% level — a
trending pre-period is not parallel whatever the drift says. `caution` is
either. The diagnostic is also part of the full report:
`nm_scm_diagnostics(out, cutoff_date = ...)$pre_trend`.

The companion figure is the event study — the effect by periods since the
cutoff, pre-period in grey and post-period in red:

```r
nm_plot_event_study(out, cutoff_date = "2019-04-01",
                     title = "Effect by event time")
```

A placebo-in-time band can be laid over the post-period; its rows are already
aligned to event time 0, 1, 2, ..., so it lines up row by row:

```r
pt <- nm_placebo_in_time(
  df = panel, date_col = "date", unit_col = "code", outcome_col = "NO2_dw",
  treated_unit = treated, donors = donors, cutoff_date = cutoff,
  min_pre_period = 12, placebo_every = 1
)
nm_plot_event_study(out, cutoff_date = cutoff,
                    band = pt$ref_band_event_time,
                    title = "Effect by event time (placebo-in-time band)")
```

## Spatial layout of the donor pool

The weights say how much each donor contributes to the synthetic control, not
*where* the donors sit relative to the treated unit. For a policy that acts
through local or regional processes — a city's emissions regime, a river
basin's meteorology — a donor pool clustered on one side of the treated site
is a different object from one that surrounds it, and the two can carry the
same weights. If the panel carries latitude and longitude columns, the reading
is one call:

```r
table <- nm_donor_spatial_summary(
  panel, donors, treated,
  unit_col = "code", lat_col = "lat", lon_col = "lon"
)
# per donor: distance_km, bearing_deg (0 = north), compass sector
# (+ the fit's weight when weights = is given)

nm_spatial_summary(table)
# centroid_offset_km, centroid_bearing_deg, sector_coverage, sector_fraction
```

A donor with no coordinate in the panel gets a row of `NA`s and sector `"?"`
rather than being dropped — a missing fix is itself information. The same
section is appended to the full report when the panel supports it:

```r
nm_scm_diagnostics(
  out, cutoff_date = cutoff,
  panel = panel, donors = donors, treated_unit = treated,
  unit_col = "code", lat_col = "lat", lon_col = "lon"
)$spatial
```

It is a diagnostic, not a fitter: nothing here changes the weights, and no
distance or bearing is fed back into the fit.

## Inference

Two flavours of significance test:

```r
# Conformal-style finite-sample interval for the post-period ATT
ci <- nm_conformal_effect_interval(out, cutoff_date = cutoff,
                                    n_perm = 1000, ci_level = 0.95)
str(ci)     # att, low, high, p_value, n_post, n_perm

# Abadie's RMSPE-ratio placebo test
pl  <- nm_placebo_in_space(
  df = panel, date_col = "date", unit_col = "code", outcome_col = "NO2_dw",
  treated_unit = treated, donors = donors, cutoff_date = cutoff,
  scm_backend = "scm"
)
rmt <- nm_rmspe_ratio_test(pl, cutoff_date = cutoff)
rmt$p_value; rmt$rank
```

`nm_placebo_in_space()` returns the treated effect, the placebo runs, the
two-sided p-value and the placebo reference band. `nm_effect_bands_space()`
turns the placebos into per-date bands; `nm_effect_bands_time()` does the
same along event time for a `nm_placebo_in_time()` result.

## Staggered adoption (several treated units)

When the intervention rolls out unit by unit — the UK ULEZ 2021 expansion,
staggered driving restrictions across cities — each adopting unit gets its own
cutoff, and each is fitted against the units that have not adopted:

```r
res <- nm_run_scm_staggered(
  df            = panel,
  date_col      = "date", unit_col = "code", outcome_col = "NO2_dw",
  treated_units = c("London", "Manchester", "Leeds"),
  cutoff_dates  = c(London     = "2021-10-25",
                    Manchester = "2022-01-06",
                    Leeds      = "2022-04-04"),
  donors        = donors
)
# one row per adopting unit: cutoff_date, n_pre, n_post, pre_r2, effect, p_value
# + summary rows: mean / median of the units' effects
```

Every treated unit is fitted with its own pre- and post-period, and the other
treated units are excluded from every run's donor pool, so one city's
intervention cannot leak into another city's synthetic control. Each unit's
`p_value` is its own placebo-in-space test at its own cutoff, and the `mean`
row's `p_value` is the cross-unit permutation test: each donor in turn takes
every adopting unit's role (the full set of cutoffs) and its pseudo-effects
are averaged the same way the real units' are. The real treated units are not
permuted into the reference — their data already carries the intervention —
so the donor-only reference keeps the null honest.

## Batch run for every unit

`nm_scm_all()` fits the same design with every unit in the panel in turn,
which is the natural way to look for an effect you have not yet
hypothesised:

```r
all_units <- nm_scm_all(
  df = panel, date_col = "date", unit_col = "code", outcome_col = "NO2_dw",
  cutoff_date = cutoff, scm_backend = "scm"
)
# one long-format data frame holding every unit's result
```

See [Bayesian SCM](examples_scm.md) for the posterior-weighted backend, and
[Step-by-step workflow](workflow.md) for placebo and uncertainty bands in
context.
