# Plotting

`normet`'s plotting functions produce publication-style figures from the
package's own result shapes. They return `ggplot2` objects, so you can add
layers, retheme, and save them like any other ggplot. Sections 3–5 continue
from the quick start's `results`, `met_vars` and `predictors`.

## 1. Wind analysis with polar plots

Polar plots display concentrations as a function of wind speed and wind
direction, helping identify local vs. regional emission sources.

```r
library(normet)
library(ggplot2)

set.seed(42)
n <- 500
df_wind <- data.frame(
  ws  = rgamma(n, 2, 2),
  wd  = runif(n, 0, 360),
  val = runif(n, 5.0, 45.0)
)

# An emission source from the north-east at high wind speeds
mask <- df_wind$wd > 30 & df_wind$wd < 60 & df_wind$ws > 4
df_wind$val[mask] <- df_wind$val[mask] + 25

nm_plot_polar(
  df_wind,
  target    = "val",
  ws_col    = "ws",
  wd_col    = "wd",
  statistic = "mean",     # "mean" | "median" | "max" | "sum" | "p95"
  title     = "London PM2.5 polar plot"
)
ggsave("polar_plot.png", width = 6, height = 6, dpi = 150)
```

## 2. Time series with uncertainty bands

A general-purpose series plot supporting confidence/quantile bands and an
optional resampling rule.

```r
set.seed(42)
dates <- seq(as.Date("2024-01-01"), by = "day", length.out = 100)
df_ts <- data.frame(
  date     = dates,
  observed = sin(seq(0, 10, length.out = 100)) * 5 + 15 + rnorm(100, 0, 1),
  low      = sin(seq(0, 10, length.out = 100)) * 5 + 12,
  high     = sin(seq(0, 10, length.out = 100)) * 5 + 18
)

nm_plot_time_series(
  df_ts,
  target   = "observed",
  ci_low   = "low",
  ci_high  = "high",
  resample = "W",          # average to weekly
  title    = "Weekly averaged concentration with uncertainty bands",
  ylabel   = expression(PM[2.5]~"("*mu*g~m^-3*")")
)
ggsave("time_series_uncertainty.png", width = 10, height = 5, dpi = 150)
```

## 3. Weather-normalisation trends

Compare observed concentrations with de-weathered trends, with the band from
the quantile columns `nm_normalise()` produces with `return_quantiles =`.

```r
out <- nm_normalise(
  df               = results$df_prep,
  model            = results$model,
  resample_vars    = met_vars,
  n_samples        = 300,
  return_quantiles = c(0.025, 0.975)
)

nm_plot_normalise(
  out,
  ci_low  = "q025",
  ci_high = "q975",
  title   = "PM2.5 observed vs. weather-normalised trend",
  ylabel  = expression(PM[2.5]~"("*mu*g~m^-3*")")
)
ggsave("normalisation_trend.png", width = 10, height = 5, dpi = 150)
```

## 4. Partial-dependence profiles

Display the isolated response of the concentration to individual
meteorological features. `nm_pdp()` returns the long-format frame that
`nm_plot_pdp()` (one panel per variable) and `nm_plot_pdp_grid()` (a faceted
grid) consume.

```r
pdp <- nm_pdp(results$df_prep, results$model, var_list = c("temp", "ws"))

nm_plot_pdp(pdp)                              # one panel per variable
nm_plot_pdp_grid(pdp, cols = 2,
                 title = "Partial dependence profiles")

ggsave("pdp_grid.png", width = 8, height = 5, dpi = 150)
```

## 5. Decomposition stack

Stacked-area view of an additive decomposition. The function plots every
column except the observed series and any names in `exclude`, so it pairs
naturally with the output of `nm_decompose()`.

```r
df_emi <- nm_decompose(
  method = "emission", df = results$df_prep,
  model = results$model, covariates = predictors
)

nm_plot_decomposition_stack(
  df_emi,
  exclude = c("observed", "emi_noise"),
  title   = "Emission-driven decomposition of NO2"
)
ggsave("decomposition_stack.png", width = 10, height = 8, dpi = 150)
```

## 6. Cycles and the house style

Diurnal, weekly and seasonal profiles in one figure:

```r
nm_cycle_profiles(my1, c("NO2", "temp"))
```

The package's palette, formula formatting and ggplot2 theme keep every figure
consistent (7–8.5 pt text, Okabe–Ito colours, formulas set as NO₂):

```r
nm_colours
nm_formula(c("NO2", "PM2.5", "SO42-", "ws"))

ggplot(my1, aes(date, NO2)) +
  geom_line(colour = nm_colours[["observed"]]) +
  nm_theme_normet()
```

Other plot helpers: `nm_plot_rolling()` for rolling normalisation,
`nm_plot_scm_dashboard()` for an SCM fit (needs `patchwork`),
`nm_plot_effect_with_bands()` and `nm_plot_uncertainty_bands()` for SCM
bands, `nm_plot_event_study()` for the pre-trend event study,
`nm_plot_embedding_diagnostics()` for site embeddings, and
`nm_plot_bayesian_scm()` for the Bayesian SCM.
