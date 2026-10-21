# Plotting Helpers for normet Outputs
#
# Mirrors normet-py's plotting.py. Every function draws in nm_theme_normet()'s journal
# style: 7-8.5 pt text, thin axes with ticks outward, frameless legends, short date
# ticks, colours with one meaning each (observed blue, normalised/synthetic red, context
# grey), and chemical formulas set as chemistry writes them (nm_formula()). All
# functions accept optional ellipsis for ggplot2 customisation.

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
#' Wind-direction x wind-speed concentration polar plot ("openair" style), read as a
#' compass: north at the top, clockwise.
#'
#' @param df Data frame with wind speed, direction, and target columns.
#' @param target Character. Column to aggregate (e.g., concentration).
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
nm_plot_polar <- function(df, target = NULL, ws_col = "ws", wd_col = "wd",
                          statistic = "mean", n_bins_ws = 8, n_bins_wd = 36,
                          title = NULL, ...) {
  if (is.null(target)) stop("`target` column required.")
  for (col in c(target, ws_col, wd_col)) {
    if (!col %in% colnames(df)) stop("Column '", col, "' not in df.")
  }
  nm_require("ggplot2")

  sub <- df[is.finite(df[[ws_col]]) & is.finite(df[[wd_col]]) & is.finite(df[[target]]), , drop = FALSE]
  if (nrow(sub) == 0) stop("No valid rows.")

  ws_max <- stats::quantile(sub[[ws_col]], 0.99, na.rm = TRUE)
  if (!is.finite(ws_max) || ws_max <= 0) ws_max <- max(sub[[ws_col]], na.rm = TRUE)
  sub <- sub[sub[[ws_col]] <= ws_max, , drop = FALSE]

  ws_breaks <- seq(0, ws_max, length.out = n_bins_ws + 1)
  wd_breaks <- seq(0, 360, length.out = n_bins_wd + 1)
  sub$ws_bin <- cut(sub[[ws_col]], breaks = ws_breaks, include.lowest = TRUE, labels = FALSE)
  sub$wd_bin <- cut(sub[[wd_col]] %% 360, breaks = wd_breaks, include.lowest = TRUE, labels = FALSE)

  agg_fun <- if (grepl("^p\\d+$", statistic)) {
    qval <- as.numeric(substring(statistic, 2)) / 100
    function(x) stats::quantile(x, qval, na.rm = TRUE)
  } else {
    function(x) match.fun(statistic)(x, na.rm = TRUE)
  }

  grid <- stats::aggregate(sub[[target]], by = list(wd_bin = sub$wd_bin, ws_bin = sub$ws_bin),
                           FUN = agg_fun)
  names(grid)[3] <- "value"
  grid$theta <- (wd_breaks[grid$wd_bin] + wd_breaks[grid$wd_bin + 1]) / 2
  grid$r <- (ws_breaks[grid$ws_bin] + ws_breaks[grid$ws_bin + 1]) / 2

  ggplot2::ggplot(grid, ggplot2::aes(x = theta, y = r, fill = value)) +
    ggplot2::geom_tile(width = 360 / n_bins_wd, height = ws_max / n_bins_ws) +
    ggplot2::scale_fill_viridis_c(name = .fl(paste(statistic, target)),
                                  guide = ggplot2::guide_colourbar(barwidth = 0.5, barheight = 6)) +
    # North at the top, clockwise, as a compass reads.
    ggplot2::coord_polar(start = 0, direction = 1) +
    ggplot2::scale_x_continuous(limits = c(0, 360), breaks = c(0, 90, 180, 270),
                                labels = c("N", "E", "S", "W"), expand = c(0, 0)) +
    ggplot2::scale_y_continuous(limits = c(0, ws_max), expand = c(0, 0)) +
    ggplot2::labs(title = title %||% .fl(.say("{s0} by wind direction and speed", target)),
                  x = NULL, y = ws_col) +
    nm_theme_normet() +
    ggplot2::theme(panel.grid.major = ggplot2::element_line(colour = "white",
                                                            linewidth = .pt_lw(0.4)),
                   panel.border = ggplot2::element_blank())
}

#' PDP Grid Plot
#'
#' Faceted grid of partial-dependence curves. Where `data` (the table the model was
#' trained on) is given, each panel marks the variable's deciles along its x axis: a
#' curve where the data are few -- its ends -- is read with that in mind. A variable of
#' a few whole values (an hour, a weekday) is drawn as steps with a point at each value.
#'
#' @param pdp_df Data frame with columns \code{variable}, \code{value},
#'        \code{pdp_mean}, and optionally \code{pdp_std}.
#' @param cols Integer. Number of grid columns. Default 3.
#' @param sharey Logical. Share y-axis. Default FALSE.
#' @param title Character. Optional title.
#' @param ylabel Character. The prediction's label, once, beside the grid. Default
#'        "Partial dependence".
#' @param data Optional data.frame: the training table, for each variable's deciles.
#' @param ... Additional arguments passed to ggplot2 facet.
#'
#' @return A ggplot2 object.
#' @export
nm_plot_pdp_grid <- function(pdp_df, cols = 3, sharey = FALSE, title = NULL,
                             ylabel = "Partial dependence", data = NULL, ...) {
  for (col in c("variable", "value", "pdp_mean")) {
    if (!col %in% colnames(pdp_df)) stop("`pdp_df` missing column '", col, "'.")
  }
  nm_require("ggplot2")
  pdp_df <- as.data.frame(pdp_df)
  pdp_df$value <- suppressWarnings(as.numeric(as.character(pdp_df$value)))
  pdp_df <- pdp_df[order(pdp_df$variable, pdp_df$value), , drop = FALSE]
  variables <- unique(as.character(pdp_df$variable))
  if (length(variables) == 0) stop("No variables in pdp_df.")
  cols <- max(1, min(cols, length(variables)))
  pdp_df$variable <- factor(pdp_df$variable, levels = variables)

  # A few whole values -- an hour, a weekday: steps, a point on each.
  discrete <- vapply(split(pdp_df$value, pdp_df$variable), function(x) {
    length(x) <= 31 && all(is.finite(x)) && isTRUE(all.equal(x, round(x)))
  }, logical(1))
  pdp_df$.discrete <- discrete[as.character(pdp_df$variable)]
  colour <- nm_colours[["component"]]

  p <- ggplot2::ggplot(pdp_df, ggplot2::aes(x = value, y = pdp_mean))
  if ("pdp_std" %in% colnames(pdp_df) && any(is.finite(pdp_df$pdp_std))) {
    p <- p + ggplot2::geom_ribbon(
      ggplot2::aes(ymin = pdp_mean - pdp_std, ymax = pdp_mean + pdp_std),
      fill = colour, alpha = 0.15
    )
  }
  cont <- pdp_df[!pdp_df$.discrete, , drop = FALSE]
  disc <- pdp_df[pdp_df$.discrete, , drop = FALSE]
  if (nrow(cont)) p <- p + ggplot2::geom_line(data = cont, colour = colour, linewidth = .pt_lw(1.4))
  if (nrow(disc)) {
    p <- p +
      ggplot2::geom_step(data = disc, colour = colour, linewidth = .pt_lw(1.4), direction = "mid") +
      ggplot2::geom_point(data = disc, colour = colour, size = 0.8)
  }
  if (!is.null(data)) {
    dec <- do.call(rbind, lapply(intersect(variables, names(data)), function(v) {
      x <- suppressWarnings(as.numeric(data[[v]]))
      x <- x[is.finite(x)]
      if (!length(x)) return(NULL)
      data.frame(variable = v, value = unique(stats::quantile(x, seq(0.1, 0.9, 0.1), names = FALSE)))
    }))
    if (!is.null(dec) && nrow(dec)) {
      dec$variable <- factor(dec$variable, levels = variables)
      p <- p + ggplot2::geom_rug(data = dec, ggplot2::aes(x = value), inherit.aes = FALSE,
                                 sides = "b", colour = nm_colours[["ink"]],
                                 linewidth = .pt_lw(0.7), length = ggplot2::unit(4, "pt"))
    }
  }
  p + ggplot2::facet_wrap(~variable, ncol = cols, scales = if (sharey) "free_x" else "free") +
    ggplot2::labs(title = title, x = NULL, y = .say(ylabel %||% "")) +
    nm_theme_normet()
}

#' Decomposition Stack Plot
#'
#' Stacked-area visualisation of a decomposition output, contributions in
#' \code{\link{nm_palette}}'s colours and the observed series as a thin dark line.
#'
#' @param decomp_df Data frame indexed by date (or with a date column) with
#'        an \code{observed} column and one column per feature contribution.
#' @param observed_col Character. Observed series column. Default "observed".
#' @param exclude Character vector. Columns to skip. Default \code{NULL}: observed,
#'        model_pred, residual and base, and the total each of
#'        \code{\link{nm_decompose}}'s outputs is the sum of -- \code{emi_total} of the
#'        emission method's parts (\code{emi_base}, the time terms and \code{emi_noise}),
#'        \code{met_total} of the meteorology method's -- so that a part is not stacked
#'        twice.
#' @param title Character. Optional title.
#' @param ... Additional arguments passed to ggplot2.
#'
#' @return A ggplot2 object.
#' @export
nm_plot_decomposition_stack <- function(decomp_df, observed_col = "observed",
                                        exclude = NULL,
                                        title = NULL, ...) {
  decomp_df <- as.data.frame(decomp_df)
  if (is.null(exclude)) {
    # A total is the sum of the parts beside it: the meteorology method's observed is
    # emi_total plus met_total's parts, the emission method's emi_total its own parts.
    total <- if ("met_total" %in% colnames(decomp_df)) "met_total" else "emi_total"
    exclude <- c("observed", "model_pred", "residual", "base", total)
  }
  if (!"date" %in% colnames(decomp_df)) {
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
  contrib_cols <- contrib_cols[vapply(decomp_df[contrib_cols], is.numeric, logical(1))]
  if (length(contrib_cols) == 0) stop("No contribution columns found.")

  # Times kept as they are: a sub-daily record keeps its hours.
  decomp_df$date <- .as_time(decomp_df$date)
  long <- stats::reshape(
    decomp_df[, c("date", contrib_cols), drop = FALSE],
    varying = contrib_cols, v.names = "contribution",
    times = contrib_cols, direction = "long",
    timevar = "variable"
  )
  long$variable <- factor(long$variable, levels = contrib_cols)
  colours <- rep_len(nm_palette, length(contrib_cols))
  labels <- vapply(contrib_cols, function(c) nm_formula(c), character(1))

  ggplot2::ggplot(long, ggplot2::aes(x = date, y = contribution, fill = variable)) +
    ggplot2::geom_area(position = "stack", alpha = 0.85) +
    ggplot2::geom_line(data = decomp_df, ggplot2::aes(x = date, y = !!rlang::sym(observed_col)),
      colour = nm_colours[["ink"]], linewidth = .pt_lw(0.8), inherit.aes = FALSE) +
    ggplot2::scale_fill_manual(values = stats::setNames(colours, contrib_cols),
                               labels = labels, name = NULL) +
    .time_scale(decomp_df$date) +
    ggplot2::labs(title = title %||% .say("Decomposition"), x = NULL, y = .say("Contribution")) +
    nm_theme_normet() +
    ggplot2::theme(legend.position = "top", legend.justification = "right")
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
#' @param ylabel Character. The outcome's name, on the top panel's y axis. Default
#'        "Outcome".
#' @param ... Additional arguments passed to ggplot2.
#'
#' @return A ggplot2 object arranged with patchwork.
#' @export
nm_plot_scm_dashboard <- function(scm_result, cutoff_date, diagnostics = NULL, title = "SCM dashboard",
                                  ylabel = "Outcome", ...) {
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

  synth <- as.data.frame(synth)
  synth$date <- .as_time(synth$date)
  cutoff_ts <- .as_cutoff(cutoff_date, synth$date)
  col <- nm_colours

  p1 <- ggplot2::ggplot(synth, ggplot2::aes(x = date)) +
    ggplot2::geom_line(ggplot2::aes(y = observed, colour = "observed"), linewidth = .pt_lw(1.2)) +
    ggplot2::geom_line(ggplot2::aes(y = synthetic, colour = "synthetic"), linewidth = .pt_lw(1.2),
                       linetype = "dashed") +
    .cutoff_line(cutoff_ts) +
    ggplot2::scale_colour_manual(values = c(observed = col[["observed"]], synthetic = col[["modelled"]]),
                                 labels = c(observed = .say("observed"), synthetic = .say("synthetic"))) +
    .time_scale(synth$date) +
    ggplot2::labs(title = .say(title), x = NULL, y = .fl(.say(ylabel)), colour = NULL) +
    nm_theme_normet() +
    ggplot2::theme(axis.text.x = ggplot2::element_blank(), legend.position = c(0.01, 0.99),
                   legend.justification = c(0, 1))

  p2 <- ggplot2::ggplot(synth, ggplot2::aes(x = date, y = effect)) +
    .zero_line() +
    ggplot2::geom_line(colour = col[["modelled"]], linewidth = .pt_lw(1.2)) +
    .cutoff_line(cutoff_ts) +
    .time_scale(synth$date) +
    ggplot2::labs(x = NULL, y = .say("Effect (observed - synthetic)")) +
    nm_theme_normet()

  top <- diagnostics$top_donors
  if (!is.null(top) && length(top) > 0) {
    w_df <- if (is.data.frame(top)) {
      data.frame(donor = as.character(top[[1]]), weight = as.numeric(top[[2]]))
    } else {
      data.frame(donor = names(top), weight = as.numeric(top))
    }
  } else if (!is.null(weights) && length(weights) > 0) {
    w_df <- data.frame(donor = names(weights), weight = as.numeric(weights))
    w_df <- utils::head(w_df[order(abs(w_df$weight), decreasing = TRUE), ], 10)
  } else {
    w_df <- NULL
  }
  if (!is.null(w_df)) {
    w_df$donor <- factor(w_df$donor, levels = w_df$donor[order(w_df$weight)])
    hhi_text <- if (!is.null(diagnostics)) {
      .say("Top donors  |  HHI={s0}  |  effective_N={s1}",
           sprintf("%.3f", diagnostics$hhi %||% NA_real_),
           sprintf("%.1f", diagnostics$effective_n_donors %||% NA_real_))
    } else {
      .say("Top donor weights")
    }
    p3 <- ggplot2::ggplot(w_df, ggplot2::aes(x = weight, y = donor)) +
      ggplot2::geom_col(fill = col[["neutral"]], width = 0.6) +
      ggplot2::labs(title = hhi_text, x = .say("weight"), y = NULL) +
      nm_theme_normet() +
      ggplot2::theme(panel.grid.major.y = ggplot2::element_blank())
  } else {
    p3 <- ggplot2::ggplot(data.frame()) +
      ggplot2::annotate("text", x = 0, y = 0, label = .say("No donor weights available"),
                        colour = col[["neutral"]], size = 8 / ggplot2::.pt) +
      ggplot2::theme_void()
  }

  p1 / p2 / p3 + patchwork::plot_layout(heights = c(3, 2, 2))
}

#' Normalisation Result Plot
#'
#' Plot observed vs. normalised (deweathered) time series with optional
#' uncertainty band. Times are kept as they are, so a sub-daily record keeps its hours;
#' a dense record (hourly over months) is drawn in thin lines, a short or averaged one
#' fuller, and either is broken where the record has a gap rather than joined across it.
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
#'   covariates <- c("ws", "wd", "temp", "RH", "blh", "ssrd")
#'   predictors <- c(covariates, "date_unix", "day_julian", "weekday", "hour")
#'   build <- nm_build_model(
#'     my1[1:150, c("date", "NO2", covariates)],
#'     target = "NO2", covariates = predictors,
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
  result_df <- as.data.frame(result_df)

  if (!"date" %in% colnames(result_df)) {
    if (inherits(try(as.Date(rownames(result_df)), silent = TRUE), "Date")) {
      result_df$date <- as.Date(rownames(result_df))
    } else {
      stop("No 'date' column in result_df.")
    }
  }
  result_df$date <- .as_time(result_df$date)
  result_df <- nm_resample_mean(result_df, resample, date_col = "date")
  result_df <- result_df[order(result_df$date), , drop = FALSE]
  has_ci <- !is.null(ci_low) && !is.null(ci_high) &&
    ci_low %in% colnames(result_df) && ci_high %in% colnames(result_df)
  value_cols <- c(observed_col, normalised_col, if (has_ci) c(ci_low, ci_high))
  n <- nrow(result_df)
  df <- .break_at_gaps(result_df, "date", value_cols)
  dense <- n > 1500
  col <- nm_colours
  lab_obs <- .say("Observed")
  lab_norm <- .say("Normalised (deweathered)")
  lab_band <- .say("Uncertainty band")

  p <- ggplot2::ggplot(df, ggplot2::aes(x = date))
  p <- p + ggplot2::geom_line(ggplot2::aes(y = !!rlang::sym(observed_col), colour = lab_obs),
                              linewidth = .series_width(n), alpha = if (dense) 0.55 else 0.8,
                              na.rm = TRUE)
  if (has_ci) {
    p <- p + ggplot2::geom_ribbon(
      ggplot2::aes(ymin = !!rlang::sym(ci_low), ymax = !!rlang::sym(ci_high), fill = lab_band),
      alpha = 0.18 # NA rows kept: the band breaks at a gap as the lines do
    ) + ggplot2::scale_fill_manual(values = stats::setNames(col[["modelled"]], lab_band), name = NULL)
  }
  p + ggplot2::geom_line(ggplot2::aes(y = !!rlang::sym(normalised_col), colour = lab_norm),
                         linewidth = .series_width(n, emphasis = TRUE), na.rm = TRUE) +
    ggplot2::scale_colour_manual(values = stats::setNames(c(col[["observed"]], col[["modelled"]]),
                                                          c(lab_obs, lab_norm)),
                                 breaks = c(lab_obs, lab_norm)) +
    .time_scale(df$date) +
    ggplot2::labs(title = title %||% .say("Observed vs. Normalised concentration"), x = NULL,
                  y = .fl(.say(ylabel)), colour = NULL) +
    nm_theme_normet() +
    ggplot2::theme(legend.position = "top", legend.justification = "right")
}

#' Rolling Normalisation Plot
#'
#' The mean of \code{\link{nm_rolling}}'s windows, with a band of one standard
#' deviation across the windows where two or more overlap, over the observed series
#' when it is given -- the figure the normet window draws for a rolling run.
#'
#' @param rolled Data frame. \code{nm_rolling}'s output: \code{date} and one column per
#'        window (\code{window_01}, ...); an \code{observed} column, where it has one,
#'        is drawn behind.
#' @param data Optional data.frame with \code{date} and \code{value} (the table the
#'        model was trained on, \code{df_prep}): its values drawn as the observed series.
#' @param title Character. Optional title.
#' @param ylabel Character. Y-axis label. Default "Concentration".
#' @param ... Additional arguments passed to ggplot2.
#'
#' @return A ggplot2 object.
#'
#' @examples
#' \donttest{
#' if (requireNamespace("lightgbm", quietly = TRUE)) {
#'   covariates <- c("ws", "wd", "temp", "RH", "blh", "ssrd")
#'   predictors <- c(covariates, "date_unix", "day_julian", "weekday", "hour")
#'   build <- nm_build_model(
#'     my1[1:600, c("date", "NO2", covariates)],
#'     target = "NO2", covariates = predictors,
#'     model_config = list(n_trials = 1, cv_folds = 2, nrounds = 15,
#'                          num_leaves_min = 5, num_leaves_max = 15),
#'     seed = 42, verbose = FALSE
#'   )
#'   rolled <- nm_rolling(
#'     build$df_prep, model = build$model, covariates = predictors,
#'     resample_vars = covariates, window_days = 7, rolling_every = 3,
#'     n_samples = 3, n_cores = 1, verbose = FALSE
#'   )
#'   nm_plot_rolling(rolled, data = build$df_prep)
#' }
#' }
#'
#' @export
nm_plot_rolling <- function(rolled, data = NULL, title = NULL, ylabel = "Concentration", ...) {
  nm_require("ggplot2")
  rolled <- as.data.frame(rolled)
  if (!"date" %in% colnames(rolled)) stop("No 'date' column in rolled.")
  windows <- grep("^window_", colnames(rolled), value = TRUE)
  if (length(windows) == 0) stop("No window columns (window_01, ...) in rolled.")
  rolled$date <- .as_time(rolled$date)
  if (!"observed" %in% colnames(rolled) && !is.null(data) &&
      all(c("date", "value") %in% colnames(data))) {
    data <- as.data.frame(data)
    data$date <- .as_time(data$date)
    observed <- data[!duplicated(data$date), c("date", "value")]
    names(observed)[2] <- "observed"
    rolled <- merge(observed, rolled, by = "date", all.x = TRUE)
  }
  rolled <- rolled[order(rolled$date), , drop = FALSE]
  values <- as.matrix(rolled[windows])
  overlap <- rowSums(!is.na(values))
  rolled$rolling_mean <- ifelse(overlap > 0, rowMeans(values, na.rm = TRUE), NA_real_)
  sd <- apply(values, 1, function(v) if (sum(!is.na(v)) >= 2) stats::sd(v, na.rm = TRUE) else NA_real_)
  rolled$band_low <- rolled$rolling_mean - sd
  rolled$band_high <- rolled$rolling_mean + sd

  has_obs <- "observed" %in% colnames(rolled)
  n <- nrow(rolled)
  df <- .break_at_gaps(rolled, "date",
                       c("rolling_mean", "band_low", "band_high", if (has_obs) "observed"))
  col <- nm_colours
  lab_obs <- .say("observed")
  lab_mean <- .say("rolling mean")
  lab_band <- .say("±1 SD across overlapping windows")

  p <- ggplot2::ggplot(df, ggplot2::aes(x = date))
  if (has_obs) {
    p <- p + ggplot2::geom_line(ggplot2::aes(y = observed, colour = lab_obs),
                                linewidth = .series_width(n), alpha = 0.4, na.rm = TRUE)
  }
  if (any(!is.na(df$band_low))) {
    p <- p + ggplot2::geom_ribbon(
      ggplot2::aes(ymin = band_low, ymax = band_high, fill = lab_band), alpha = 0.18,
      na.rm = TRUE # no band where fewer than two windows overlap
    ) + ggplot2::scale_fill_manual(values = stats::setNames(col[["modelled"]], lab_band), name = NULL)
  }
  p + ggplot2::geom_line(ggplot2::aes(y = rolling_mean, colour = lab_mean),
                         linewidth = .series_width(n, emphasis = TRUE), na.rm = TRUE) +
    ggplot2::scale_colour_manual(values = stats::setNames(c(col[["neutral"]], col[["modelled"]]),
                                                          c(lab_obs, lab_mean)),
                                 breaks = c(if (has_obs) lab_obs, lab_mean)) +
    .time_scale(df$date) +
    ggplot2::labs(title = title %||% .say("Rolling normalisation — mean of {s0} windows",
                                          length(windows)),
                  x = NULL, y = .fl(.say(ylabel)), colour = NULL) +
    nm_theme_normet() +
    ggplot2::theme(legend.position = "top", legend.justification = "right")
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

  synth <- as.data.frame(synth)
  synth$date <- .as_time(synth$date)
  cutoff_ts <- .as_cutoff(cutoff_date, synth$date)
  col <- nm_colours
  band_label <- .say("credible band")
  lab_obs <- .say("Observed")
  lab_syn <- .say("Synthetic (posterior mean)")

  p1 <- ggplot2::ggplot(synth, ggplot2::aes(x = date))
  if ("synthetic_low" %in% colnames(synth) && "synthetic_high" %in% colnames(synth)) {
    p1 <- p1 + ggplot2::geom_ribbon(ggplot2::aes(ymin = synthetic_low, ymax = synthetic_high,
                                                 fill = band_label), alpha = 0.18) +
      ggplot2::scale_fill_manual(values = stats::setNames(col[["modelled"]], band_label), name = NULL)
  }
  p1 <- p1 +
    ggplot2::geom_line(ggplot2::aes(y = observed, colour = lab_obs), linewidth = .pt_lw(1.2)) +
    ggplot2::geom_line(ggplot2::aes(y = synthetic, colour = lab_syn),
                       linewidth = .pt_lw(1.2), linetype = "dashed") +
    .cutoff_line(cutoff_ts) +
    ggplot2::scale_colour_manual(values = stats::setNames(c(col[["observed"]], col[["modelled"]]),
                                                          c(lab_obs, lab_syn))) +
    .time_scale(synth$date) +
    ggplot2::labs(title = .say(title), x = NULL, y = .say("Outcome"), colour = NULL) +
    nm_theme_normet() +
    ggplot2::theme(axis.text.x = ggplot2::element_blank())

  p2 <- ggplot2::ggplot(synth, ggplot2::aes(x = date, y = effect))
  if ("effect_low" %in% colnames(synth) && "effect_high" %in% colnames(synth)) {
    p2 <- p2 + ggplot2::geom_ribbon(ggplot2::aes(ymin = effect_low, ymax = effect_high),
      fill = col[["modelled"]], alpha = 0.18)
  }
  p2 <- p2 + .zero_line() +
    ggplot2::geom_line(colour = col[["modelled"]], linewidth = .pt_lw(1.2)) +
    .cutoff_line(cutoff_ts) +
    .time_scale(synth$date) +
    ggplot2::labs(x = NULL, y = .say("Effect (observed - synthetic)")) +
    nm_theme_normet()

  p1 / p2
}

#' Generic Time Series Plot
#'
#' Plot a time series with optional confidence/uncertainty bands, broken where the
#' record has a gap.
#'
#' @param df Data frame with a date column.
#' @param target Character. Column to plot.
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
#' @param color Character. Line color. Default the style's observed blue
#'        (\code{nm_colours[["observed"]]}).
#' @param ... Additional arguments passed to ggplot2.
#'
#' @return A ggplot2 object.
#'
#' @examples
#' \donttest{
#' res <- nm_run_scm(
#'   df = scm, date_col = "date", unit_col = "code", outcome_col = "NO2_dw",
#'   treated_unit = "MY1", cutoff_date = "2019-04-01",
#'   scm_backend = "scm", verbose = FALSE
#' )
#' nm_plot_time_series(res, target = "effect", title = "ULEZ effect on normalised NO2")
#' }
#'
#' @export
nm_plot_time_series <- function(df, target = NULL, ci_low = NULL, ci_high = NULL,
                                resample = NULL,
                                title = NULL, ylabel = NULL, color = nm_colours[["observed"]], ...) {
  if (is.null(target) || !target %in% colnames(df)) stop("`target` column required.")
  nm_require("ggplot2")
  df <- as.data.frame(df)

  if (!"date" %in% colnames(df)) {
    if (inherits(try(as.Date(rownames(df)), silent = TRUE), "Date")) {
      df$date <- as.Date(rownames(df))
    } else {
      stop("No 'date' column.")
    }
  }
  df$date <- .as_time(df$date)
  df <- nm_resample_mean(df, resample, date_col = "date")
  df <- df[order(df$date), , drop = FALSE]
  has_ci <- !is.null(ci_low) && !is.null(ci_high) && ci_low %in% colnames(df) && ci_high %in% colnames(df)
  n <- nrow(df)
  df <- .break_at_gaps(df, "date", c(target, if (has_ci) c(ci_low, ci_high)))

  p <- ggplot2::ggplot(df, ggplot2::aes(x = date, y = !!rlang::sym(target)))
  if (has_ci) {
    p <- p + ggplot2::geom_ribbon(ggplot2::aes(ymin = !!rlang::sym(ci_low),
      ymax = !!rlang::sym(ci_high)), fill = color, alpha = 0.18)
  }
  p + ggplot2::geom_line(colour = color, linewidth = .series_width(n), na.rm = TRUE) +
    .time_scale(df$date) +
    ggplot2::labs(title = title %||% .fl(.say("Time series of {s0}", target)), x = NULL,
                  y = .fl(ylabel %||% target)) +
    nm_theme_normet()
}

# -- Diurnal, weekly and seasonal profiles (openair's timeVariation) -------------------

.CYCLE_XLAB <- c(hour = "Hour of day", weekday = "Day of week", month = "Month")
.WEEKDAYS <- c("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")

# The cycles a record of these times can show: the hour of day only when it is finer
# than daily, the day of the week when finer than weekly, the month when it spans two
# months or more.
.usable_cycles <- function(times) {
  t <- sort(as.numeric(.as_time(times)) * if (inherits(times, "Date")) 86400 else 1)
  t <- t[is.finite(t)]
  if (length(t) < 3) return(character(0))
  step <- stats::median(diff(t))
  span <- t[length(t)] - t[1]
  out <- character(0)
  if (step < 86400 * 0.99) out <- c(out, "hour")
  if (step < 7 * 86400 * 0.99) out <- c(out, "weekday")
  if (span >= 2 * 30 * 86400) out <- c(out, "month")
  out
}

# One series' mean over a cycle, with a band: "ci" the mean's 95% confidence interval,
# "iqr" the 25th-75th percentiles, or "none".
.cycle_profile <- function(times, values, cycle, band = "ci") {
  lt <- as.POSIXlt(.as_time(times), tz = "UTC")
  key <- switch(cycle,
    hour = lt$hour,
    weekday = (lt$wday + 6L) %% 7L, # Mon = 0
    month = lt$mon + 1L
  )
  bins <- switch(cycle, hour = 0:23, weekday = 0:6, month = 1:12)
  ok <- is.finite(values) & !is.na(key)
  g <- split(values[ok], factor(key[ok], levels = bins))
  n <- vapply(g, length, numeric(1))
  m <- vapply(g, function(v) if (length(v)) mean(v) else NA_real_, numeric(1))
  lo <- hi <- rep(NA_real_, length(bins))
  if (band == "iqr") {
    lo <- vapply(g, function(v) if (length(v)) stats::quantile(v, 0.25, names = FALSE) else NA_real_, numeric(1))
    hi <- vapply(g, function(v) if (length(v)) stats::quantile(v, 0.75, names = FALSE) else NA_real_, numeric(1))
  } else if (band == "ci") {
    se <- vapply(g, function(v) if (length(v) > 1) stats::sd(v) else NA_real_, numeric(1)) / sqrt(pmax(n, 1))
    lo <- m - 1.96 * se
    hi <- m + 1.96 * se
  }
  data.frame(cycle = cycle, bin = bins, mean = unname(m), low = unname(lo), high = unname(hi),
             n = unname(n))
}

#' Diurnal, weekly and seasonal profiles
#'
#' The mean of each column over the hour of the day, the day of the week and the month
#' -- a record's diurnal, weekly and seasonal cycles side by side, as openair's
#' `timeVariation` draws them -- with each mean's 95\% confidence interval.
#'
#' @param df A data.frame with a `date` column.
#' @param columns The series to average.
#' @param labels Their legend entries (the column names, formulas set, by default).
#' @param colors Their colours (\code{\link{nm_palette}} by default).
#' @param cycles Which of `"hour"`, `"weekday"`, `"month"` to draw; by default those
#'   the record can show: the hour only when it is finer than daily, the weekday when
#'   finer than weekly, the month when it spans two months or more.
#' @param band `"ci"` (the mean's 95\% confidence interval), `"iqr"` (25th-75th
#'   percentiles) or `"none"`.
#' @param ylabel The y label.
#' @return A ggplot2 object, one panel per cycle; its `data` is the profile table
#'   (`cycle`, `bin`, `series`, `mean`, `low`, `high`, `n`), weekdays numbered from
#'   Monday = 0.
#' @examples
#' p <- nm_cycle_profiles(my1, c("NO2", "temp"))
#' head(p$data)
#' @export
nm_cycle_profiles <- function(df, columns, labels = NULL, colors = NULL, cycles = NULL,
                              band = c("ci", "iqr", "none"), ylabel = NULL) {
  band <- match.arg(band)
  nm_require("ggplot2")
  if (!"date" %in% names(df)) stop("`df` needs a 'date' column.")
  missing_cols <- setdiff(columns, names(df))
  if (length(missing_cols)) stop("Column(s) not in df: ", paste(missing_cols, collapse = ", "))
  which <- cycles %||% .usable_cycles(df$date)
  bad <- setdiff(which, names(.CYCLE_XLAB))
  if (length(bad)) stop("Unknown cycle(s): ", paste(bad, collapse = ", "))
  if (!length(which)) stop("No cycle to draw: the record needs times finer than weekly or a span of two months.")
  labels <- labels %||% nm_formula(columns)
  colors <- rep_len(colors %||% nm_palette, length(columns))

  prof <- do.call(rbind, lapply(seq_along(columns), function(i) {
    do.call(rbind, lapply(which, function(cy) {
      out <- .cycle_profile(df$date, as.numeric(df[[columns[i]]]), cy, band = band)
      out$series <- labels[i]
      out
    }))
  }))
  prof$series <- factor(prof$series, levels = unique(labels))
  prof$cycle <- factor(prof$cycle, levels = which,
                       labels = vapply(.CYCLE_XLAB[which], .say, character(1)))
  prof <- prof[, c("cycle", "bin", "series", "mean", "low", "high", "n")]

  breaks_for <- function(lim) {
    if (lim[2] > 12.5) c(0, 6, 12, 18, 23) else if (lim[1] < 0.5) 0:6 else 1:12
  }
  labels_for <- function(b) {
    if (length(b) == 7 && all(b == 0:6, na.rm = TRUE)) {
      vapply(.WEEKDAYS, .say, character(1), USE.NAMES = FALSE)
    } else {
      as.character(b)
    }
  }
  p <- ggplot2::ggplot(prof, ggplot2::aes(x = bin, y = mean, colour = series, fill = series))
  if (band != "none") {
    p <- p + ggplot2::geom_ribbon(ggplot2::aes(ymin = low, ymax = high), colour = NA,
                                  alpha = 0.18, na.rm = TRUE)
  }
  p + ggplot2::geom_line(linewidth = .pt_lw(1.1), na.rm = TRUE) +
    ggplot2::geom_point(size = 0.8, na.rm = TRUE) +
    ggplot2::scale_colour_manual(values = stats::setNames(colors, levels(prof$series)), name = NULL) +
    ggplot2::scale_fill_manual(values = stats::setNames(colors, levels(prof$series)), name = NULL) +
    ggplot2::scale_x_continuous(breaks = breaks_for, labels = labels_for,
                                expand = ggplot2::expansion(add = 0.4)) +
    ggplot2::facet_wrap(~cycle, nrow = 1, scales = "free_x", strip.position = "bottom") +
    ggplot2::labs(x = NULL, y = .fl(ylabel %||% if (length(columns) == 1) columns else .say("Mean"))) +
    nm_theme_normet() +
    ggplot2::theme(strip.placement = "outside", strip.text = ggplot2::element_text(hjust = 0.5),
                   legend.position = if (length(columns) > 1) "top" else "none",
                   legend.justification = "left")
}
