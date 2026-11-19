# Trend analysis

The snippets continue from the quick start and the decomposition guide:
`df_prep`, `model` and `predictors` are the prepared frame, trained model and
covariate list used there.

De-weathering produces an emission-driven series. The next question every
such record invites is whether that series is *trending*, how fast, and
whether that statement is statistically honest. That is what `nm_trend()`
answers.

## Why a dedicated module

Hourly air-quality records are strongly autocorrelated — the diurnal and
weekly structure survives the model, and consecutive hours share the same
met-driven state. A Mann-Kendall test on such a record treats its 8,760
hourly values as independent draws, and the overconfidence is not a small
correction: on a two-year hourly AR(1) record with a true trend, the classical
p-value can read 0 when the correct inference would be "significant but far
less decisively so." `nm_trend()` therefore refuses to hand over a naked
p-value for a record it can see to be autocorrelated, and reports both what
was measured and what the correction changed.

## The entry point: `nm_trend`

```r
library(normet)

# The emission component is the natural input; a deweathered series works too.
df_emi <- nm_decompose(
  method = "emission", df = df_prep, model = model, covariates = predictors
)

res <- nm_trend(
  df_emi,
  value_col = "emi_total",
  name = "MY1 NO2 emission-driven"
  # seasonal_period = 24 for hourly records with a diurnal cycle,
  # 7 for daily records with a weekly cycle, 12 for monthly.
)
print(res)      # one line: n, MK p, slope with its interval, and the correction
summary(res)    # two-column metric/value table, report-ready
```

What each quantity means:

| Quantity | Source | Note |
|---|---|---|
| Mann-Kendall p | classical test | With tie correction (Hirsch et al. 1982) and continuity correction. *Not* autocorrelation-adjusted — there is no equally standard corrected variant, and the result says so. |
| Slope | Theil-Sen | Median pair-wise slope; robust to the occasional spike a pollution event leaves in the record. Units per **day** when the input carries timestamps, per **step** otherwise. |
| Slope interval | Sen (1968) analytic 95% CI | Assumes independence — see the bootstrap below. |
| `slope_per_year` | conversion | `slope * 365.25`, when timestamps are present. |
| AR(1) ACF and p | OLS-residual ACF(1) | Triggers the correction when `p < test_alpha` (default 0.05). |
| Bootstrap SE / interval | moving-block bootstrap | 1,000 replicates by default; block length is the longer of `3 n^(1/3)` (Politis–Romano heuristic) and one calendar week for sub-daily records, so the weekly cycle stays inside a block. Deterministic under `seed`. |
| Wald p from the bootstrap SE | the autocorrelation-corrected trend test | The one to quote when the record is autocorrelated. |

The rule of thumb the results implement: **when the record is
autocorrelated, quote the bootstrap p and the bootstrap interval; the
classical quantities stay in the record as what the naive test would have
claimed.**

## `nm_mann_kendall` and `nm_theil_sen`

Either can be called on its own.

```r
mk <- nm_mann_kendall(df_emi, value_col = "emi_total", seasonal_period = 24)
mk$S; mk$varS; mk$z; mk$p; mk$n    # z < 0 reads as a decreasing trend

ts <- nm_theil_sen(df_emi, value_col = "emi_total")
ts$slope; ts$ci_low; ts$ci_high   # per day for a datetime-indexed series
```

The seasonal Mann-Kendall test (Sen 1968) groups the record into calendar
periods — `seasonal_period = 24` means *all hours recorded at 03:00, tested
against their own within-group order*, not "each week as a group". The cycle
then contributes only through *which values each slot holds*, not through its
rise-then-fall shape. The record must contain a whole number of periods after
missing values are dropped; a trailing partial week is refused rather than
tested on uneven groups. Grouping is by record position, so assume a
gap-free record: missing hours shift what lands in each slot.

## Choosing `seasonal_period`

| Record | `seasonal_period` |
|---|---|
| Hourly | `24` (diurnal cycle) |
| Daily | `7` (weekly cycle) |
| Monthly | `12` (annual cycle) |
| Demeaned / detrended first | leave as `NULL` |

The classical test remains available as `seasonal_period = NULL`; the module
does not decide which is right for a given record — that is a statement about
the data's structure, and a report should say which was used.

## When the trend changes: `nm_trend_breaks`

A single slope cannot say what happened on a record whose level or slope
changes part-way through — a policy year, a lockdown. Fit the whole record
with one line and the change is diluted into a muddier trend: the pre-event
segment drags the slope toward zero, the post-event segment drags it up, and
either significance statement or the slope itself is a statement about *both*
regimes mixed together. `nm_trend_breaks()` asks the question directly:
*where does the regime change, and what are the slopes of the regimes?*

```r
res <- nm_trend_breaks(
  df_emi,
  value_col    = "long-term",   # date_unix + emi_base, the separated drift
  name         = "MY1 NO2 emission",
  max_segments = 2               # one split (the default)
  # min_segment = NULL  -> the longer of 28 and 5 % of the record
  # alpha = 0.05, n_bootstrap = 500, seed = 7654321
)
print(res)      # n, segments, break, SSE reduction, per-segment slopes, p
summary(res)    # one row per segment: start, end, n, slope, interval
```

`value_col = "long-term"` is the emission decomposition's separated long-term
component: the `date_unix` contribution plus the constant `emi_base`, with the
recurring calendar cycles already taken into their own component columns. On
`"emi_total"` the segmentation runs on the full, cycled series instead.

### How the split is found, and why the gate exists

The search is a full O(n) grid: the two-segment OLS residual sum of squares
of *every* candidate position is O(1) from prefix sums, so the record is
scanned once, and the split that most reduces the SSE wins. A grid searched
over `n-1` positions, however, always finds *something* — pure noise contains
a split that cuts its SSE by some amount — so the candidate split passes two
gates before it is reported:

1. **BIC, per round.** Each split must beat the BIC of the current fit, so
   the extra slope + intercept earn their keep. This is the *stopping* rule
   for `max_segments > 2` (greedy forward segmentation).
2. **Block-bootstrap p for the search.** The observed SSE reduction of the
   final fit over the single-segment fit is compared with the *same search
   re-run on every moved-block resample* of the series. The resulting p is
   the probability that a record without a break — searched exactly as hard,
   with its autocorrelation preserved by the blocks — produces a reduction at
   least that large. It is the multiple-testing-corrected,
   autocorrelation-aware test; it is why a grid search can be honest.

If either gate fails, the series is reported as **one regime** and
`summary()` has a single row; the search is not hidden — the result keeps
where it wanted to cut and what the p was, so a report can say "a cut at X
lowers the SSE by Y % but the block-bootstrap p is Z, so it is not claimed as
a break."

The per-segment intervals are Sen intervals: compare adjacent segments
against *their* intervals rather than re-testing the split — the split itself
is what the p certifies.

### Performance

The search is O(n) and the bootstrap O(n · n_bootstrap) with an O(n) search
inside each replicate: a 5,793-hour record runs in about a second at the
default 500 replicates, and three years of hourly data (26,280 points) takes
about 20 seconds. The block length uses the same heuristic as `nm_trend()`
(longer of `3 n^(1/3)` and a calendar week for sub-daily records). For
multi-year hourly records prefer `max_segments = 2` and a smaller record
window when speed matters.

## In the window and the Assistant

The window runs the test as one of its steps. The **Trend analysis** box on
the Decompose page names the series (the decomposition's emission part, its
**separated long-term trend**, its weather part, or the observed target), the
seasonal period (`auto`, `none`, `24`, `7`, `12`), the **number of segments**
(`1` to `4`) and the bootstrap's replicates, and a *Run* button starts it;
with **Run after each emission decomposition** ticked (unticked by default), a
finished emission decomposition starts the test of its emission part under
those same settings.

- **1 segment** (the default) runs the single-slope test
  (`nm_trend()`): the series with its Theil-Sen line, and a verdict that
  says whether the trend is significant and *which p stands for it* — the
  block-bootstrap's where the record is autocorrelated, the classical
  Mann-Kendall's elsewhere.
- **2 to 4 segments** runs the segmented fit (`nm_trend_breaks()`): where the
  trend breaks, each segment with its own Theil-Sen slope and Sen interval,
  and the block-bootstrap **p of the search**. The separated **long-term
  trend** is the cleaner input for this.

The result opens on the **Trend** tab: the figure, a traffic-light verdict,
the test's notes, and its tidy summary (one row per segment for the segmented
fit, the two-column metric table for one), with its own CSV export and a
Command Log entry written as the R call that repeats it.

The window's **Assistant** runs the step for you: ask *is the emission
signal trending?* and it calls the `trend` tool (series `emission`, `met` or
`observed`; seasonal `auto` or named), returning the reading the tab shows,
with its notes on which p to quote. Ask *where does the trend break?* and it
calls `trend_breaks` (series `long-term` (the default), `emission`, `met` or
`observed`; segments `2` to `4`). The headless MCP server does the same in
place: `normet_trend(path, column = ...)` on a result table and
`normet_trend_breaks(path, column = ...)`, where `column = "long-term"` (the
default) is the separated long-term component and `"emission"` its
`emi_total`.

## Performance note

The S statistic is O(n²) in pairs, so runtime is set by the *record length*
of the classical (non-seasonal) test: a year of hourly data is about 38
million pairs (about a second), three years a second or two, and ten years
about 3.8 billion pairs (~10 seconds, measured). For multi-year hourly
records, the `seasonal_period` form is both faster and the right test, since
each group stays at most one year long. The block bootstrap is
O(n · n_bootstrap) and negligible by comparison.

## Relation to the rest of normet

`nm_trend()` is statistics on a series you already have. It does not resample
weather, train a model, or touch the `nm_prepare_data()` schema: pass it a
numeric vector (positional) or a data frame plus `value_col`.
`summary()` returns a two-column frame you can fold into your own report.
