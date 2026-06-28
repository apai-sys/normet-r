# Plotting Helpers for normet Outputs
#
# Ported from Python normet plotting.py
# All functions accept optional ellipsis for ggplot2 customisation.

NULL

#' Resample a Data Frame to a Coarser Time Frequency by Averaging
#'
#' Internal helper mirroring Python's `df.resample(rule).mean()` used by the
#' plotting functions. Accepts pandas-style frequency codes
#' (\code{"D"}, \code{"W"}, \code{"M"}/\code{"MS"}, \code{"Q"}/\code{"QS"},
#' \code{"Y"}/\code{"A"}/\code{"YS"}, \code{"H"}) as well as
#' \code{\link[lubridate:floor_date]{lubridate::floor_date}} unit strings
#' (e.g. \code{"day"}, \code{"week"}, \code{"month"}).
#'
#' @param df Data frame containing \code{date_col}.
#' @param resample Character. Resampling rule, or \code{NULL} to skip.
#' @param date_col Character. Name of the date/datetime column. Default "date".
#'
#' @return The resampled data frame, with numeric columns averaged
#'   (\code{na.rm = TRUE}) within each period and \code{date_col} set to the
#'   floored period start, sorted by \code{date_col}. Non-numeric columns
#'   are dropped. If \code{resample} is \code{NULL}, \code{df} is returned
#'   unchanged.
#' @keywords internal
nm_resample_mean <- function(df, resample, date_col = "date") {
  if (is.null(resample)) return(df)

  unit <- switch(toupper(resample),
    "D" = "day",
    "W" = "week",
    "M" = ,
    "MS" = "month",
    "Q" = ,
    "QS" = "quarter",
    "Y" = ,
    "A" = ,
    "YS" = "year",
    "H" = "hour",
    tolower(resample)
  )

  df[[date_col]] <- lubridate::floor_date(df[[date_col]], unit = unit)
  num_cols <- setdiff(names(df)[vapply(df, is.numeric, logical(1))], date_col)
  if (length(num_cols) == 0) return(df)

  agg <- stats::aggregate(df[num_cols], by = stats::setNames(list(df[[date_col]]), date_col),
    FUN = mean, na.rm = TRUE)
  agg[order(agg[[date_col]]), , drop = FALSE]
}

#' Polar / Wind-Rose Plot
#'
#' Wind-direction x wind-speed concentration polar plot ("openair" style).
#'
#' @param df Data frame with wind speed, direction, and value columns.
#' @param value Character. Column to aggregate (e.g., concentration).
#' @param ws_col Character. Wind speed column. Default "ws".
#' @param wd_col Character. Wind direction column (degrees). Default "wd".
#' @param statistic Character. Aggregation: "mean", "median", "max", "sum",
#'        or "p<NN>" e.g. "p95". Default "mean".
#' @param n_bins_ws Integer. Speed bins. Default 8.
#' @param n_bins_wd Integer. Direction bins. Default 36.
#' @param title Character. Optional title.
#' @param ... Additional arguments passed to ggplot2.
#'
#' @return A ggplot2 object.
#' @export
nm_plot_polar <- function(df, value = NULL, ws_col = "ws", wd_col = "wd",
                          statistic = "mean", n_bins_ws = 8, n_bins_wd = 36,
                          title = NULL, ...) {
  if (is.null(value)) stop("`value` column required.")
  for (col in c(value, ws_col, wd_col)) {
    if (!col %in% colnames(df)) stop("Column '", col, "' not in df.")
  }
  nm_require("ggplot2")

  sub <- df[is.finite(df[[ws_col]]) & is.finite(df[[wd_col]]) & is.finite(df[[value]]), , drop = FALSE]
  if (nrow(sub) == 0) stop("No valid rows.")

  ws_max <- quantile(sub[[ws_col]], 0.99, na.rm = TRUE)
  if (!is.finite(ws_max) || ws_max <= 0) ws_max <- max(sub[[ws_col]], na.rm = TRUE)

  sub$ws_bin <- cut(sub[[ws_col]], breaks = seq(0, ws_max, length.out = n_bins_ws + 1),
    include.lowest = TRUE)
  sub$wd_bin <- cut(sub[[wd_col]] %% 360, breaks = seq(0, 360, length.out = n_bins_wd + 1),
    include.lowest = TRUE)

  agg_fun <- if (grepl("^p\\d+$", statistic)) {
    qval <- as.numeric(substring(statistic, 2)) / 100
    function(x) quantile(x, qval, na.rm = TRUE)
  } else {
    function(x) match.fun(statistic)(x, na.rm = TRUE)
  }

  grid <- aggregate(as.formula(paste0("`", value, "` ~ wd_bin + ws_bin")),
    data = sub, FUN = agg_fun)

  # Compute bin midpoints for polar coordinates
  wd_mid <- function(b) mean(as.numeric(gsub("\\(|\\]|\\[", "", strsplit(gsub(" ", "", b), ",")[[1]])))
  ws_mid <- function(b) mean(as.numeric(gsub("\\(|\\]|\\[", "", strsplit(gsub(" ", "", b), ",")[[1]])))
  grid$theta <- sapply(as.character(grid$wd_bin), wd_mid)
  grid$r <- sapply(as.character(grid$ws_bin), ws_mid)
  grid$theta_rad <- grid$theta * pi / 180

  ggplot2::ggplot(grid, ggplot2::aes(x = theta_rad, y = r, fill = !!rlang::sym(value))) +
    ggplot2::geom_tile(width = 2 * pi / n_bins_wd, height = ws_max / n_bins_ws) +
    ggplot2::scale_fill_viridis_c() +
    ggplot2::coord_polar(start = -pi / 2, direction = 1) +
    ggplot2::scale_x_continuous(labels = c("N", "NE", "E", "SE", "S", "SW", "W", "NW"),
      breaks = seq(0, 7 * pi / 4, pi / 4)) +
    ggplot2::labs(title = title %||% paste(value, "by wind direction x speed"),
      fill = paste0(statistic, "(", value, ")")) +
    ggplot2::theme_minimal()
}

#' PDP Grid Plot
#'
#' Faceted grid of partial-dependence curves.
#'
#' @param pdp_df Data frame with columns \code{variable}, \code{value},
#'        \code{pdp_mean}, and optionally \code{pdp_std}.
#' @param cols Integer. Number of grid columns. Default 3.
#' @param sharey Logical. Share y-axis. Default FALSE.
#' @param title Character. Optional title.
#' @param ... Additional arguments passed to ggplot2 facet.
#'
#' @return A ggplot2 object.
#' @export
nm_plot_pdp_grid <- function(pdp_df, cols = 3, sharey = FALSE, title = NULL, ...) {
  for (col in c("variable", "value", "pdp_mean")) {
    if (!col %in% colnames(pdp_df)) stop("`pdp_df` missing column '", col, "'.")
  }
  nm_require("ggplot2")

  has_std <- "pdp_std" %in% colnames(pdp_df)
  p <- ggplot2::ggplot(pdp_df, ggplot2::aes(x = value, y = pdp_mean)) +
    ggplot2::geom_line(color = "#1f77b4", linewidth = 1)
  if (has_std) {
    p <- p + ggplot2::geom_ribbon(
      ggplot2::aes(ymin = pdp_mean - pdp_std, ymax = pdp_mean + pdp_std),
      fill = "#1f77b4", alpha = 0.18
    )
  }
  p <- p + ggplot2::facet_wrap(~variable, ncol = cols, scales = if (sharey) "fixed" else "free_y") +
    ggplot2::theme_minimal() + ggplot2::labs(title = title)
  p
}

#' Decomposition Stack Plot
#'
#' Stacked-area visualisation of a decomposition output.
#'
#' @param decomp_df Data frame indexed by date (or with a date column) with
#'        an \code{observed} column and one column per feature contribution.
#' @param observed_col Character. Observed series column. Default "observed".
#' @param exclude Character vector. Columns to skip. Default excludes
#'        observed, model_pred, residual, base.
#' @param title Character. Optional title.
#' @param ... Additional arguments passed to ggplot2.
#'
#' @return A ggplot2 object.
#' @export
nm_plot_decomposition_stack <- function(decomp_df, observed_col = "observed",
                                        exclude = c("observed", "model_pred", "residual", "base"),
                                        title = NULL, ...) {
  if (!"date" %in% colnames(decomp_df) && !"date" %in% names(decomp_df)) {
    # Check if rownames are dates
    if (inherits(try(as.Date(rownames(decomp_df)), silent = TRUE), "Date")) {
      decomp_df$date <- as.Date(rownames(decomp_df))
    } else {
      stop("`decomp_df` must have a 'date' column or Date rownames.")
    }
  }
  if (!observed_col %in% colnames(decomp_df)) {
    stop("`", observed_col, "` not in decomp_df.")
  }
  nm_require("ggplot2")

  contrib_cols <- setdiff(colnames(decomp_df), c("date", exclude))
  if (length(contrib_cols) == 0) stop("No contribution columns found.")

  # Reshape to long format for stacking
  long <- stats::reshape(
    decomp_df[, c("date", contrib_cols), drop = FALSE],
    varying = contrib_cols, v.names = "contribution",
    times = contrib_cols, direction = "long",
    timevar = "variable"
  )
  long$variable <- factor(long$variable, levels = contrib_cols)

  # Ensure date is numeric for stackplot (convert to numeric for ordering)
  long$date <- as.Date(long$date)

  p <- ggplot2::ggplot(long, ggplot2::aes(x = date, y = contribution, fill = variable)) +
    ggplot2::geom_area(position = "stack", alpha = 0.85) +
    ggplot2::geom_line(data = decomp_df, ggplot2::aes(x = as.Date(date), y = !!rlang::sym(observed_col)),
      color = "black", linewidth = 1.2, inherit.aes = FALSE) +
    ggplot2::scale_fill_viridis_d() +
    ggplot2::labs(title = title %||% "Decomposition", y = "Contribution") +
    ggplot2::theme_minimal()
  p
}

#' SCM Dashboard
#'
#' Three-panel summary of a synthetic-control fit: observed vs. synthetic,
#' effect path, and top donor weights.
#'
#' @param scm_result List or data.frame. Output of SCM backends.
#' @param cutoff_date Character or Date. Treatment cutoff.
#' @param diagnostics List. Optional output of \code{nm_scm_diagnostics}.
#' @param title Character. Plot title.
#' @param ... Additional arguments passed to ggplot2.
#'
#' @return A ggplot2 object arranged with patchwork.
#' @export
nm_plot_scm_dashboard <- function(scm_result, cutoff_date, diagnostics = NULL, title = "SCM dashboard", ...) {
  if (is.data.frame(scm_result)) {
    synth <- scm_result
    weights <- NULL
  } else {
    synth <- scm_result[["synthetic"]]
    weights <- scm_result[["weights"]]
  }
  if (is.null(synth) || !"effect" %in% colnames(synth)) {
    stop("`scm_result` must have a synthetic data.frame with 'effect'.")
  }
  nm_require("ggplot2")
  nm_require("patchwork", hint = "install.packages('patchwork')")

  cutoff_ts <- as.Date(cutoff_date)
  synth$date <- as.Date(synth$date)

  p1 <- ggplot2::ggplot(synth, ggplot2::aes(x = date)) +
    ggplot2::geom_line(ggplot2::aes(y = observed, color = "Observed"), linewidth = 1) +
    ggplot2::geom_line(ggplot2::aes(y = synthetic, color = "Synthetic"), linewidth = 1, linetype = "dashed") +
    ggplot2::geom_vline(xintercept = cutoff_ts, linetype = "dotted") +
    ggplot2::labs(title = title, y = "Outcome", color = NULL) +
    ggplot2::theme_minimal()

  p2 <- ggplot2::ggplot(synth, ggplot2::aes(x = date, y = effect)) +
    ggplot2::geom_line(color = "red", linewidth = 1) +
    ggplot2::geom_hline(yintercept = 0, linewidth = 0.5) +
    ggplot2::geom_vline(xintercept = cutoff_ts, linetype = "dotted") +
    ggplot2::labs(y = "Effect") +
    ggplot2::theme_minimal()

  if (!is.null(weights) && length(weights) > 0) {
    w_df <- data.frame(
      donor = names(weights),
      weight = as.numeric(weights)
    )
    w_df <- w_df[order(abs(w_df$weight), decreasing = TRUE), ]
    w_df <- head(w_df, 10)
    w_df$donor <- factor(w_df$donor, levels = w_df$donor[order(w_df$weight)])

    hhi_text <- ""
    if (!is.null(diagnostics)) {
      hhi_text <- paste0("  HHI=", round(diagnostics$hhi, 3),
        "  eff_N=", round(diagnostics$effective_n_donors, 1))
    }
    p3 <- ggplot2::ggplot(w_df, ggplot2::aes(x = weight, y = donor)) +
      ggplot2::geom_col(fill = "#1f77b4") +
      ggplot2::labs(title = paste0("Top donors", hhi_text), x = "weight", y = NULL) +
      ggplot2::theme_minimal()
  } else {
    p3 <- ggplot2::ggplot(data.frame()) +
      ggplot2::annotate("text", x = 0, y = 0, label = "No donor weights available") +
      ggplot2::theme_void()
  }

  p1 / p2 / p3 + patchwork::plot_layout(heights = c(3, 2, 2))
}

#' Normalisation Result Plot
#'
#' Plot observed vs. normalised (deweathered) time series with optional
#' uncertainty band.
#'
#' @param result_df Data frame with \code{date}, \code{observed},
#'        \code{normalised} columns, and optionally quantile columns.
#' @param observed_col Character. Observed column. Default "observed".
#' @param normalised_col Character. Normalised column. Default "normalised".
#' @param ci_low Character. Lower bound column (e.g. "q025").
#' @param ci_high Character. Upper bound column (e.g. "q975").
#' @param resample Character. Pandas-style resample rule (e.g. \code{"D"} for
#'        daily, \code{"W"} for weekly) or a
#'        \code{\link[lubridate:floor_date]{lubridate::floor_date}} unit
#'        (e.g. \code{"day"}, \code{"week"}). If given, the series are
#'        averaged to this frequency before plotting. Default \code{NULL}
#'        (no resampling).
#' @param title Character. Optional title.
#' @param ylabel Character. Y-axis label. Default "Concentration".
#' @param ... Additional arguments passed to ggplot2.
#'
#' @return A ggplot2 object.
#'
#' @examples
#' \donttest{
#' if (requireNamespace("lightgbm", quietly = TRUE)) {
#'   covariates <- c("u10", "v10", "d2m", "t2m", "blh", "ssrd")
#'   predictors <- c(covariates, "date_unix", "day_julian", "weekday", "hour")
#'   build <- nm_build_model(
#'     my1[1:150, c("date", "NO2", covariates)],
#'     value = "NO2", predictors = predictors,
#'     model_config = list(n_trials = 1, cv_folds = 2, nrounds = 15,
#'                          num_leaves_min = 5, num_leaves_max = 15),
#'     seed = 42, verbose = FALSE
#'   )
#'   norm <- nm_normalise(
#'     build$df_prep, build$model,
#'     resample_vars = covariates, n_samples = 5, n_cores = 1, verbose = FALSE
#'   )
#'   nm_plot_normalise(norm)
#' }
#' }
#'
#' @export
nm_plot_normalise <- function(result_df, observed_col = "observed",
                              normalised_col = "normalised",
                              ci_low = NULL, ci_high = NULL,
                              resample = NULL,
                              title = NULL, ylabel = "Concentration", ...) {
  for (col in c(observed_col, normalised_col)) {
    if (!col %in% colnames(result_df)) stop("Column '", col, "' not found.")
  }
  nm_require("ggplot2")

  if (!"date" %in% colnames(result_df)) {
    if (inherits(try(as.Date(rownames(result_df)), silent = TRUE), "Date")) {
      result_df$date <- as.Date(rownames(result_df))
    } else {
      stop("No 'date' column in result_df.")
    }
  }
  result_df$date <- as.Date(result_df$date)
  result_df <- nm_resample_mean(result_df, resample, date_col = "date")

  p <- ggplot2::ggplot(result_df, ggplot2::aes(x = date)) +
    ggplot2::geom_line(ggplot2::aes(y = !!rlang::sym(observed_col), color = "Observed"),
      linewidth = 0.8, alpha = 0.7) +
    ggplot2::geom_line(ggplot2::aes(y = !!rlang::sym(normalised_col), color = "Normalised"),
      linewidth = 1.5)

  if (!is.null(ci_low) && !is.null(ci_high) &&
    ci_low %in% colnames(result_df) && ci_high %in% colnames(result_df)) {
    p <- p + ggplot2::geom_ribbon(
      ggplot2::aes(ymin = !!rlang::sym(ci_low), ymax = !!rlang::sym(ci_high)),
      fill = "#d7191c", alpha = 0.15
    )
  }

  p + ggplot2::scale_color_manual(values = c(Observed = "#2c7bb6", Normalised = "#d7191c")) +
    ggplot2::labs(title = title %||% "Observed vs. Normalised", y = ylabel, color = NULL) +
    ggplot2::theme_minimal()
}

#' Bayesian SCM Posterior Band Plot
#'
#' Plot a Bayesian SCM fit with posterior credible bands.
#'
#' @param result List. Output of Bayesian SCM with \code{synthetic} data.frame
#'        having \code{observed}, \code{synthetic}, \code{effect}, and
#'        optionally \code{synthetic_low}, \code{synthetic_high},
#'        \code{effect_low}, \code{effect_high}.
#' @param cutoff_date Character or Date. Treatment cutoff.
#' @param title Character. Plot title.
#' @param ... Additional arguments passed to ggplot2.
#'
#' @return A ggplot2 object.
#' @export
nm_plot_bayesian_scm <- function(result, cutoff_date,
                                 title = "Bayesian SCM", ...) {
  if (is.data.frame(result)) synth <- result
  else synth <- result[["synthetic"]]
  if (is.null(synth)) stop("No 'synthetic' data found.")

  for (col in c("observed", "synthetic", "effect")) {
    if (!col %in% colnames(synth)) stop("'synthetic' missing column '", col, "'.")
  }
  nm_require("ggplot2")
  nm_require("patchwork")

  synth$date <- as.Date(synth$date)
  cutoff_ts <- as.Date(cutoff_date)

  p1 <- ggplot2::ggplot(synth, ggplot2::aes(x = date)) +
    ggplot2::geom_line(ggplot2::aes(y = observed, color = "Observed"), linewidth = 1) +
    ggplot2::geom_line(ggplot2::aes(y = synthetic, color = "Synthetic"), linewidth = 1, linetype = "dashed")

  if ("synthetic_low" %in% colnames(synth) && "synthetic_high" %in% colnames(synth)) {
    p1 <- p1 + ggplot2::geom_ribbon(ggplot2::aes(ymin = synthetic_low, ymax = synthetic_high),
      fill = "#d7191c", alpha = 0.15)
  }
  p1 <- p1 + ggplot2::geom_vline(xintercept = cutoff_ts, linetype = "dotted") +
    ggplot2::scale_color_manual(values = c(Observed = "#2c7bb6", Synthetic = "#d7191c")) +
    ggplot2::labs(title = title, y = "Outcome", color = NULL) +
    ggplot2::theme_minimal()

  p2 <- ggplot2::ggplot(synth, ggplot2::aes(x = date, y = effect)) +
    ggplot2::geom_line(color = "orange", linewidth = 1) +
    ggplot2::geom_hline(yintercept = 0, linewidth = 0.5) +
    ggplot2::geom_vline(xintercept = cutoff_ts, linetype = "dotted")
  if ("effect_low" %in% colnames(synth) && "effect_high" %in% colnames(synth)) {
    p2 <- p2 + ggplot2::geom_ribbon(ggplot2::aes(ymin = effect_low, ymax = effect_high),
      fill = "orange", alpha = 0.2)
  }
  p2 <- p2 + ggplot2::labs(y = "Effect") + ggplot2::xlab("Date") +
    ggplot2::theme_minimal()

  p1 / p2
}

#' Generic Time Series Plot
#'
#' Plot a time series with optional confidence/uncertainty bands.
#'
#' @param df Data frame with a date column.
#' @param value Character. Column to plot.
#' @param ci_low Character. Lower bound column.
#' @param ci_high Character. Upper bound column.
#' @param resample Character. Pandas-style resample rule (e.g. \code{"D"} for
#'        daily, \code{"W"} for weekly) or a
#'        \code{\link[lubridate:floor_date]{lubridate::floor_date}} unit
#'        (e.g. \code{"day"}, \code{"week"}). If given, the series is
#'        averaged to this frequency before plotting. Default \code{NULL}
#'        (no resampling).
#' @param title Character. Optional title.
#' @param ylabel Character. Y-axis label.
#' @param color Character. Line color. Default "#2c7bb6".
#' @param ... Additional arguments passed to ggplot2.
#'
#' @return A ggplot2 object.
#'
#' @examples
#' \donttest{
#' res <- nm_run_scm(
#'   df = scm, date_col = "date", unit_col = "ID", outcome_col = "NO2",
#'   treated_unit = "2+26 cities", cutoff_date = "2015-12-01",
#'   scm_backend = "scm", verbose = FALSE
#' )
#' nm_plot_time_series(res, value = "effect", title = "SCM effect on NO2")
#' }
#'
#' @export
nm_plot_time_series <- function(df, value = NULL, ci_low = NULL, ci_high = NULL,
                                resample = NULL,
                                title = NULL, ylabel = NULL, color = "#2c7bb6", ...) {
  if (is.null(value) || !value %in% colnames(df)) stop("`value` column required.")
  nm_require("ggplot2")

  if (!"date" %in% colnames(df)) {
    if (inherits(try(as.Date(rownames(df)), silent = TRUE), "Date")) {
      df$date <- as.Date(rownames(df))
    } else {
      stop("No 'date' column.")
    }
  }
  df$date <- as.Date(df$date)
  df <- nm_resample_mean(df, resample, date_col = "date")

  p <- ggplot2::ggplot(df, ggplot2::aes(x = date, y = !!rlang::sym(value))) +
    ggplot2::geom_line(color = color, linewidth = 1)

  if (!is.null(ci_low) && !is.null(ci_high) &&
    ci_low %in% colnames(df) && ci_high %in% colnames(df)) {
    p <- p + ggplot2::geom_ribbon(ggplot2::aes(ymin = !!rlang::sym(ci_low),
      ymax = !!rlang::sym(ci_high)),
    fill = color, alpha = 0.15)
  }

  p + ggplot2::labs(title = title %||% paste("Time series of", value),
    y = ylabel %||% value) +
    ggplot2::theme_minimal()
}
