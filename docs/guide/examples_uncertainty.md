# Uncertainty decomposition

A de-weathered estimate is not a single line but a *band*: `nm_normalise()`
returns a Monte-Carlo spread over the weather it resamples, and an ensemble of
models (`nm_do_all_unc()`) carries a wider spread still. Either band answers
"how uncertain is this estimate?" but neither answers the question a policy
evaluation has to settle next: **of the total band, how much is the met
resampling and how much is the uncertainty about which model is right?** If a
ULEZ or a lockdown's estimated effect is smaller than the band, whether it is
"significant" depends on which error dominates, and the honest answer is the
one `nm_decompose_uncertainty()` gives — the variance, attributed to its
source.

## How the attribution is computed

`nm_decompose_uncertainty()` attributes the **total per-date variance** by an
orthogonal (two-way) decomposition of the full *model-by-weather* prediction
matrix, exploiting the package's common-random-number discipline rather than
adding a new source of randomness:

- The **members differ in form**: `n_models` models are each trained on their
  own seed, so they genuinely disagree about the relationship to be learned.
- The **draws are shared**: every member predicts on the *same* `n_samples`
  met resamples (the normalise draw is anchored on the user's one `seed`, not
  the member's), so the met variation is a *common random number* across the
  ensemble.

At one timestamp the response is an `n_models × n_samples` matrix of
predictions, and its total variance (over both factors, mean-centred) splits
orthogonally into:

| term | reads as |
|---|---|
| `var_model` | the average squared distance of a member's mean from the grand mean across the ensemble — the **model-form** variance |
| `var_weather` | the average squared distance of a met draw's (model-averaged) value from the grand mean — the **weather** (resampling) variance |
| `var_interaction` | what the two main effects do not jointly account for — a model reacting differently to one met draw than the ensemble does (a residual, not an independent draw) |
| `var_total` | the total per-date variance, **exactly** the three above (every term a sum of squares, hence non-negative) |

The three main effects and their interaction are the classical two-way ANOVA
split, with the grand mean centred once — that is *why* the total equals the
three summands precisely. The `pct_*` shares are each term's fraction of
`var_total`.

The cost is one prediction per `(member, draw, timestamp)` — the **same total
count as one `nm_do_all_unc()` run** — so attributing the spread costs no
extra fits, and the whole thing is reproducible under `seed` (the member
seeds are derived from it).

## The entry point: `nm_decompose_uncertainty`

The meteorological predictors are the quick start's `predictors` and
`met_vars`; `my1` is the bundled hourly record.

```r
library(normet)

res <- nm_decompose_uncertainty(
  df                  = my1,
  target              = "NO2",
  backend             = "lightgbm",   # n_models fits are cheap
  covariates          = predictors,
  variables_resample  = met_vars,
  split_method        = "ts",         # same training rows, different seeds
  train_fraction      = 0.75,
  n_samples           = 200,          # the weather-draw factor (shared)
  n_models            = 10,           # the model-form factor
  seed                = 7654321       # the shared weather seed
)
print(res)
# NO2: <n> dates, 10 models x 200 met draws | median spread share:
# weather ...%, model ...%, interaction ...%
```

With `backend = "lightgbm"` keep `model_config` small — the ensemble is
`n_models` fits — e.g. `list(n_trials = 5, cv_folds = 3, nrounds = 200)`.

## Reading the result

The result (`nm_unc_decomposition`) is a per-date record, not a single number:

```r
summary(res)        # per-source median variance and share (report-ready)
as.data.frame(res)  # one row per date: var_weather, var_model,
                    # var_interaction, var_total, and their pct_* shares
plot(res)           # the stacked-variance-band figure
```

`summary()` reports the **median** share per source across the record: the
shares are the headline of a policy evaluation ("of the band, this fraction
is weather, that one is model form"), and medians rather than means so that a
single extreme day cannot re-weight the attribution. `plot()` stacks the three
per-date terms, so the stack's height is the total spread on each date and
each band is that source's share — the figure that answers "which band
dominates, date by date and in the median".

## When the interaction is the point

`var_interaction` is not a nuisance to hide; it is *what the model form does
beyond the average model on a given met draw*. A small interaction means the
ensemble members largely agree on *how* to react to a met condition (the
spread is additive — add the weather term to the model term). A large
interaction means the members disagree about the *response* to the same
meteorology, which the weather and model main effects alone would under-state:
the total is larger than their sum. The decomposition keeps it as a
first-class third band rather than folding it into either source, so a report
can say what it is.

## Performance note

The work is `n_models` model fits plus `n_models × n_samples` predictions on
a record of the full length, exactly the arithmetic of one `nm_do_all_unc()`
run reading per-draw predictions. For multi-year hourly records, drop
`n_samples` first (the weather factor is usually the larger term and 100–300
draws stabilise its per-date variance) before dropping `n_models`, and keep
the LightGBM search small. The per-date arithmetic is O(`n_models ×
n_samples`), so the model and the resampling dominate the cost.

## Relation to the rest of normet

`nm_decompose_uncertainty()` builds on the same resampling machinery as
`nm_normalise()` (it calls it once per member, on the same record and the same
shared draws, reading the per-draw predictions) and on the same
common-random-number discipline that `nm_decompose()` relies on. It differs
from `nm_do_all_unc()` in what it returns: a per-date *attribution* of the
spread to its source, rather than an ensemble band. That is the analysis that
turns the band a de-weathered estimate or an ensemble carries into an answer a
policy evaluation can act on: which error dominates, and therefore whether an
effect smaller than the band is separable from it at all.
