# Example: Bayesian synthetic control

This guide demonstrates the Bayesian SCM workflow in `normet`: a simplex SCM
with a Dirichlet prior on the donor weights, posterior credible bands for the
effect, and a contrast against the deterministic Abadie fit. The R
implementation is self-contained — no PyMC or other probabilistic language is
needed.

## 1. A causal panel

Build a synthetic daily panel with one treated unit ("Beijing") and three
donor stations. Under regular conditions Beijing is a linear combination of
the donors; from a set date an intervention cuts its concentration.

```r
set.seed(42)

dates  <- seq(as.Date("2024-01-01"), by = "day", length.out = 60)
donors <- c("Tianjin", "Shanghai", "Guangzhou")

rows <- lapply(dates, function(d) {
  tj <- rnorm(1, 12.0, 1.5)
  sh <- rnorm(1, 8.0, 1.0)
  gz <- rnorm(1, 6.5, 1.0)
  bj <- 0.5 * tj + 0.3 * sh + 0.2 * gz + rnorm(1, 0, 0.2)
  if (d >= as.Date("2024-02-10")) bj <- bj - 3.5

  data.frame(
    date = rep(d, 4),
    code = c("Beijing", donors),
    poll = c(bj, tj, sh, gz)
  )
})
df_panel <- do.call(rbind, rows)
```

## 2. Fit the Bayesian SCM

```r
library(normet)

result <- nm_bayesian_scm(
  df           = df_panel,
  date_col     = "date",
  unit_col     = "code",
  outcome_col  = "poll",
  treated_unit = "Beijing",
  donors       = donors,
  cutoff_date  = "2024-02-10",
  dirichlet_alpha = 1,     # < 1 favours sparse weights; > 1 diffuse weights
  draws        = 2000,
  burnin       = 1000,
  ci_level     = 0.95
)
```

`auto_cutoff = TRUE` with `cutoff_date = NULL` detects the cutoff from the
treated unit's anomaly events (`nm_detect_events()`) instead of taking a date.
If no anomaly is found, the call errors with a message; supply the known
intervention date in that case.

## 3. Donor weights and credible intervals

The fit returns the posterior mean weight of each donor with its credible
interval:

```r
result$weights_summary
#             mean  hdi_low hdi_high
# Tianjin    0.50     0.44     0.56
# Shanghai   0.30     0.23     0.36
# Guangzhou  0.20     0.14     0.26
```

`result$weights` holds the mean weights as a named vector, and
`result$synthetic` is the per-date frame: `observed`, `synthetic`,
`synthetic_low`, `synthetic_high`, `effect`, `effect_low`, `effect_high`.

## 4. Visualising outcomes and bands

```r
nm_plot_bayesian_scm(
  result,
  cutoff_date = "2024-02-10",
  title = "Beijing PM2.5 intervention analysis"
)
```

The figure shows the observed and synthetic counterfactual curves with their
credible band, and the treatment-effect path beneath.

## 5. Contrast with the deterministic Abadie SCM

Cross-check the Bayesian fit against the classic simplex SCM on the same
panel:

```r
classic <- nm_run_scm(
  df = df_panel, date_col = "date", unit_col = "code", outcome_col = "poll",
  treated_unit = "Beijing", donors = donors,
  cutoff_date = "2024-02-10",
  scm_backend = "abadie"
)
head(classic)    # date | observed | synthetic | effect
```

`nm_run_scm()` dispatches to the same Bayesian fit with
`scm_backend = "bayesian"`; calling `nm_bayesian_scm()` directly is the way to
set the prior and MCMC controls. For donor weights and fit diagnostics (HHI,
effective donor count, top donors), call the backend directly —
`nm_scm()`, `nm_scm_abadie()`, `nm_scm_mcnnm()` and `nm_scm_robust()` return
a list with the `synthetic` series and the fitted `weights` — and pass that
list to `nm_scm_diagnostics()`. `nm_mlscm()` returns only the series: it
produces no interpretable donor weights.

See [Synthetic-control modelling](examples_scm_guide.md) for diagnostics,
placebo tests and the other backends.
