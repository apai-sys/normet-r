#' Prepare a Clean, Dense Panel for Synthetic Control
#'
#' @description
#' Real-world panels (sensor networks especially) are rarely complete: units
#' come online at different times, drop out, or report at irregular
#' intervals. \code{\link{nm_scm}} requires donors to have complete
#' pre-treatment data (any donor with a missing pre-period value is dropped
#' entirely), so a handful of sparse donors can silently shrink the usable
#' donor pool to almost nothing. \code{nm_prepare_panel} screens, densifies,
#' and reshapes a ragged long panel before it ever reaches \code{\link{nm_scm}},
#' \code{\link{nm_scm_all}}, or \code{\link{nm_placebo_in_time}}/\code{\link{nm_placebo_in_space}}:
#'
#' \enumerate{
#'   \item Pivots \code{df} to one row per timestamp, one column per unit
#'     (aggregating to \code{freq} first, so higher-frequency input is
#'     resampled rather than silently misaligned against the dense grid).
#'   \item Drops donor units that don't meet \code{min_coverage} in
#'     \strong{both} the pre- and post-cutoff windows (the treated unit is
#'     always kept).
#'   \item Linearly interpolates remaining small gaps (and fills edges via
#'     \code{rule = 2}) so the panel has no missing values; units still
#'     incomplete afterwards are dropped with a warning.
#'   \item Warns if the surviving donor count is large relative to the
#'     pre-period length — donor count approaching or exceeding the number
#'     of pre-period observations destabilises the ridge fit (symptoms
#'     include synthetic values outside the plausible range of the outcome,
#'     and placebo-in-time p-values that swing wildly with small donor
#'     changes).
#' }
#'
#' @param df Long data frame with columns for date, unit, and outcome.
#' @param date_col Name of the date column (coercible to POSIXct).
#' @param unit_col Name of the unit identifier column.
#' @param outcome_col Name of the outcome column.
#' @param cutoff_date The intervention cutoff date (character or Date); only
#'   used to split the pre/post coverage screen, not to fit anything here.
#' @param treated_unit Unit ID to always keep regardless of its coverage.
#'   Errors (via \code{\link{nm_error_data}}) if it's still incomplete after
#'   interpolation — silently dropping the treated unit would be worse than
#'   failing loudly. If \code{NULL}, all units are treated as donors for the
#'   coverage screen.
#' @param min_coverage Minimum fraction of non-missing observations a donor
#'   must have in \strong{both} the pre- and post-cutoff windows to be kept.
#'   Default 0.65.
#' @param date_from,date_to Bounds for the dense date grid (character or
#'   Date). Defaults to \code{range(df[[date_col]])}.
#' @param freq A string passed to \code{\link[lubridate]{floor_date}} /
#'   \code{seq.POSIXt}'s \code{by} argument (e.g. \code{"day"}, \code{"hour"},
#'   \code{"week"}). Default \code{"day"}.
#' @param max_donor_ratio Warn when \code{n_donors / n_pre_period_rows}
#'   exceeds this. Default 0.3.
#' @param verbose Logical; if TRUE, logs progress. Default TRUE.
#'
#' @return A long-format data frame \code{c(date_col, unit_col, outcome_col)}
#'   with no missing values, ready for \code{\link{nm_scm}}. Coverage and
#'   donor-ratio diagnostics are attached as attributes: \code{attr(out, "coverage")},
#'   \code{attr(out, "n_donors")}, \code{attr(out, "n_pre_period_rows")},
#'   \code{attr(out, "donor_ratio")}.
#'
#' @examples
#' set.seed(1)
#' dates <- seq(as.Date("2026-01-01"), as.Date("2026-03-01"), by = "day")
#' units <- paste0("donor_", 1:5)
#' grid <- expand.grid(date = dates, code = c(units, "treated"), stringsAsFactors = FALSE)
#' grid$value <- runif(nrow(grid))
#' panel <- nm_prepare_panel(
#'   grid, date_col = "date", unit_col = "code", outcome_col = "value",
#'   cutoff_date = "2026-02-15", treated_unit = "treated", verbose = FALSE
#' )
#' head(panel)
#'
#' @export
nm_prepare_panel <- function(df, date_col = "date", unit_col = "code", outcome_col = "value",
                              cutoff_date, treated_unit = NULL, min_coverage = 0.65,
                              date_from = NULL, date_to = NULL, freq = "day",
                              max_donor_ratio = 0.3, verbose = TRUE) {
  nm_require("data.table", hint = "install.packages('data.table')")
  nm_require("lubridate", hint = "install.packages('lubridate')")
  nm_require("zoo", hint = "install.packages('zoo')")
  log <- nm_get_logger("causal.panel")

  if (missing(cutoff_date) || is.null(cutoff_date)) {
    nm_error_config("`cutoff_date` must be provided.")
  }

  dt <- data.table::as.data.table(df[, c(date_col, unit_col, outcome_col)])
  data.table::setnames(dt, c(date_col, unit_col, outcome_col), c("date", "unit", "value"))
  dt[, date := as.POSIXct(date, tz = "UTC")]
  if (anyNA(dt$date)) nm_error_data(sprintf("Some rows have invalid `%s` values after coercion.", date_col))

  # Aggregate to the target frequency *before* reindexing onto the dense grid
  # below. Without this, higher-frequency input (e.g. hourly readings with
  # freq="day") only lines up with the grid at exact midnight timestamps, and
  # every other reading is misclassified as missing.
  dt[, date := lubridate::floor_date(date, unit = freq)]
  wide <- data.table::dcast(dt, date ~ unit, value.var = "value", fun.aggregate = mean, na.rm = TRUE)

  range_from <- if (!is.null(date_from)) as.POSIXct(date_from, tz = "UTC") else min(wide$date)
  range_to <- if (!is.null(date_to)) as.POSIXct(date_to, tz = "UTC") else max(wide$date)
  full_range <- seq(lubridate::floor_date(range_from, unit = freq), range_to, by = freq)

  wide <- merge(data.table::data.table(date = full_range), wide, by = "date", all.x = TRUE)
  data.table::setorder(wide, date)

  cutoff_ts <- as.POSIXct(cutoff_date, tz = "UTC")
  pre_mask <- wide$date < cutoff_ts
  post_mask <- wide$date >= cutoff_ts
  if (!any(pre_mask) || !any(post_mask)) {
    nm_error_data(sprintf(
      "`cutoff_date`=%s leaves an empty pre- or post-period within [%s, %s].",
      cutoff_date, format(min(wide$date)), format(max(wide$date))
    ))
  }

  unit_cols <- setdiff(names(wide), "date")
  if (!is.null(treated_unit) && !(treated_unit %in% unit_cols)) {
    nm_error_data(sprintf("`treated_unit`='%s' not found in `%s`.", treated_unit, unit_col))
  }

  pre_cov <- sapply(wide[pre_mask, unit_cols, with = FALSE], function(x) mean(!is.na(x)))
  post_cov <- sapply(wide[post_mask, unit_cols, with = FALSE], function(x) mean(!is.na(x)))
  coverage <- data.frame(unit = unit_cols, pre_coverage = pre_cov, post_coverage = post_cov)

  keep <- (pre_cov >= min_coverage) & (post_cov >= min_coverage)
  names(keep) <- unit_cols
  if (!is.null(treated_unit)) keep[treated_unit] <- TRUE

  n_dropped_coverage <- sum(!keep)
  if (n_dropped_coverage > 0 && verbose) {
    log$info("Dropping %d/%d units below min_coverage=%.0f%%.", n_dropped_coverage, length(keep), min_coverage * 100)
  }
  kept_cols <- names(keep)[keep]
  wide <- wide[, c("date", kept_cols), with = FALSE]

  # Fill sporadic per-unit gaps; nm_scm() requires donors with complete
  # pre-period data. `rule = 2` extends the nearest endpoint value so leading/
  # trailing NAs are also filled, not just interior gaps.
  for (col in kept_cols) {
    x <- wide[[col]]
    if (all(is.na(x))) next
    filled <- tryCatch(
      as.numeric(zoo::na.approx(zoo::zoo(x), rule = 2)),
      error = function(e) rep(NA_real_, length(x))
    )
    wide[[col]] <- filled
  }

  still_missing <- kept_cols[sapply(wide[, kept_cols, with = FALSE], function(x) anyNA(x) || all(is.na(x)))]
  if (!is.null(treated_unit) && treated_unit %in% still_missing) {
    nm_error_data(sprintf(
      "`treated_unit`='%s' still has missing values after interpolation; it has no usable data across the requested date range.",
      treated_unit
    ))
  }
  if (length(still_missing) > 0) {
    warning(sprintf(
      "nm_prepare_panel: dropping %d unit(s) still incomplete after interpolation: %s",
      length(still_missing), paste(still_missing, collapse = ", ")
    ))
    wide <- wide[, setdiff(names(wide), still_missing), with = FALSE]
  }

  n_pre <- sum(pre_mask)
  final_cols <- setdiff(names(wide), "date")
  n_donors <- length(final_cols) - (if (!is.null(treated_unit) && treated_unit %in% final_cols) 1L else 0L)
  donor_ratio <- if (n_pre > 0) n_donors / n_pre else Inf
  if (donor_ratio > max_donor_ratio) {
    warning(sprintf(
      paste0(
        "nm_prepare_panel: %d donors vs %d pre-period rows (ratio=%.2f > max_donor_ratio=%.2f). ",
        "A donor pool this large relative to the pre-period length can destabilise the ridge fit ",
        "in nm_scm() -- watch for synthetic values outside the plausible range of the outcome, and ",
        "validate with nm_placebo_in_time() before trusting the result. Consider raising min_coverage ",
        "or capping the donor pool (e.g., one or a few per region/group)."
      ),
      n_donors, n_pre, donor_ratio, max_donor_ratio
    ))
  }

  long_panel <- data.table::melt(
    wide, id.vars = "date", variable.name = "unit", value.name = "value", variable.factor = FALSE
  )
  data.table::setnames(long_panel, c("date", "unit", "value"), c(date_col, unit_col, outcome_col))
  long_panel <- as.data.frame(long_panel)

  attr(long_panel, "coverage") <- coverage
  attr(long_panel, "n_donors") <- n_donors
  attr(long_panel, "n_pre_period_rows") <- n_pre
  attr(long_panel, "donor_ratio") <- donor_ratio

  if (verbose) {
    log$info(
      "nm_prepare_panel: %d units (%d donors%s), %d rows/unit, donor_ratio=%.2f.",
      length(final_cols), n_donors,
      if (!is.null(treated_unit)) sprintf(" + treated '%s'", treated_unit) else "",
      nrow(wide), donor_ratio
    )
  }

  return(long_panel)
}
