#' @importFrom data.table := .N
#' @importFrom magrittr %>%
#' @importFrom foreach %dopar%
#' @importFrom ggplot2 ggplot aes geom_line geom_ribbon geom_vline labs theme_minimal
#' @importFrom stats sd median na.omit var aggregate complete.cases rnorm runif as.formula optim rgamma
#' @importFrom utils capture.output object.size head setTxtProgressBar txtProgressBar


utils::globalVariables(c(
  "..resample_vars", ".", ".N", ".data", "effect", "lower", "upper",
  "set", "s", "normalised", "p_value", "ref_band_event_time",
  "placebo_stats", "date_d", "var", "value", "sum_norm", "i.normalised",
  "n_total", "observed", "n_norm", "sum_obs", "n_obs", "pdp_mean",
  "variable", "code", "season_temp", "month_temp",
  "synthetic", "synthetic_low", "synthetic_high",
  "effect_low", "effect_high", "contribution", "pdp_std", "theta_rad", "r",
  "weight", "donor", "site", ".x"
))
