# The evidence a normet analysis is judged by, written out as text
#
# Ported from Python normet agent/readings.py. An analyst chooses the target and
# its predictors from the table, judges a model by how well it predicts the rows
# it was not trained on, and reads a normalised series against the observed one.
# The window shows these as figures; a language model needs them as numbers.
# These functions say what is there and stop: no predictor is chosen and no
# result is judged here. Every number an assistant quotes should come from one
# of these readings (see nm_mcp_server()).

NULL

#' Column names read as meteorological predictors (as the GUI preselects them).
#' @noRd
.NM_MET_NAMES <- c(
  "u10", "v10", "d2m", "t2m", "blh", "sp", "ssrd", "tcc", "tp", "rh2m",
  "ws", "wd", "temp", "rh", "pressure", "atmos_pres"
)

#' Column names read as pollutants.
#' @noRd
.NM_POLLUTANTS <- c("PM2.5", "PM25", "PM10", "NO2", "NO", "NOX", "O3", "SO2", "CO", "NH3", "BC", "OX")

#' Time features normet adds to every model.
#' @noRd
.NM_TIME_FEATURES <- c("date_unix", "day_julian", "weekday", "hour")

#' A number as text: `digits` significant figures, an em dash for missing.
#' @noRd
.nm_num <- function(x, digits = 4) {
  if (is.null(x) || length(x) != 1) return(paste(format(x), collapse = ", "))
  if (is.character(x) || is.factor(x)) return(as.character(x))
  v <- suppressWarnings(as.numeric(x))
  if (is.na(v) || !is.finite(v)) return("\u2014")
  if (v == 0) return("0")
  if (abs(v) >= 10^(digits + 2) || abs(v) < 10^-(digits - 1)) {
    return(sprintf(paste0("%.", digits - 1, "e"), v))
  }
  sprintf(paste0("%.", digits, "g"), v)
}

#' A whole number with thousands separators.
#' @noRd
.nm_count <- function(n) formatC(as.numeric(n), format = "d", big.mark = ",")

#' Rows as an aligned plain-text table: `rows` a list of lists (or vectors).
#' @noRd
.nm_text_table <- function(header, rows) {
  cell <- function(c) if (is.character(c)) c else .nm_num(c)
  cells <- c(list(as.character(header)), lapply(rows, function(r) vapply(as.list(r), cell, "")))
  widths <- vapply(seq_along(header), function(i) max(nchar(vapply(cells, `[`, "", i))), 0)
  # Padded by characters (formatC pads by bytes, and a dash or a superscript is two).
  pad <- function(r) paste0(r, strrep(" ", widths - nchar(r)))
  line <- function(r) sub("\\s+$", "", paste(pad(r), collapse = "  "))
  lines <- vapply(cells, line, "")
  dashes <- paste(strrep("-", widths), collapse = "  ")
  paste(c(lines[1], dashes, lines[-1]), collapse = "\n")
}

#' What a column's name says it is: "pollutant", "met" or "other".
#' @noRd
.nm_role <- function(column) {
  if (toupper(column) %in% .NM_POLLUTANTS) return("pollutant")
  if (column %in% .NM_MET_NAMES || tolower(column) %in% .NM_MET_NAMES) return("met")
  "other"
}

.nm_reading_dates <- function(df) {
  if (!"date" %in% names(df)) return(NULL)
  d <- df$date
  if (inherits(d, "Date")) d <- as.POSIXct(d, tz = "UTC")
  if (!inherits(d, "POSIXct")) d <- suppressWarnings(as.POSIXct(d, tz = "UTC"))
  d
}

.nm_stamp <- function(t) format(t, "%Y-%m-%d %H:%M:%S")

#' The usual time step, in seconds: the median difference of the sorted dates.
#' @noRd
.nm_reading_step <- function(dates) {
  stamps <- sort(unique(as.numeric(dates[!is.na(dates)])))
  if (length(stamps) < 2) return(NULL)
  stats::median(diff(stamps))
}

#' A time step as one says it: "1h", "30min", "1 day", "7 days".
#' @noRd
.nm_human_step <- function(secs) {
  secs <- as.integer(round(secs))
  if (secs %% 86400 == 0) {
    days <- secs %/% 86400
    return(paste0(days, " day", if (days != 1) "s" else ""))
  }
  if (secs %% 3600 == 0) return(paste0(secs %/% 3600, "h"))
  if (secs %% 60 == 0) return(paste0(secs %/% 60, "min"))
  paste0(secs, "s")
}

#' The column naming units if `df` is a panel (dates repeated, one row per unit
#' and date), with how many units; NULL for a single series.
#' @noRd
.nm_panel_units <- function(df) {
  dates <- .nm_reading_dates(df)
  if (is.null(dates) || !anyDuplicated(dates)) return(NULL)
  for (col in names(df)) {
    if (col == "date" || is.numeric(df[[col]])) next
    n <- length(unique(df[[col]]))
    if (n > 1 && n < nrow(df) && !anyDuplicated(data.frame(d = dates, u = df[[col]]))) {
      return(list(column = col, n = n))
    }
  }
  NULL
}

.nm_safe_stat <- function(f, x) {
  x <- x[!is.na(x)]
  if (!length(x)) NA_real_ else f(x)
}

#' A table before anything is fitted: its size and span, the time step and gaps,
#' and each numeric column's role, missing values and range -- with `target`, each
#' column's correlation with it.
#' @noRd
.nm_data_reading <- function(df, target = NULL, name = "the table") {
  df <- as.data.frame(df)
  lines <- sprintf("%s: %s rows \u00d7 %d columns.", name, .nm_count(nrow(df)), ncol(df))
  dates <- .nm_reading_dates(df)
  panel <- .nm_panel_units(df)
  if (is.null(dates)) {
    lines <- c(lines, "No 'date' column: normet needs one, with the timestamp of each row.")
  } else {
    bad <- sum(is.na(dates))
    ok <- dates[!is.na(dates)]
    lines <- c(lines, paste0(
      "Dates ", .nm_stamp(min(ok)), " to ", .nm_stamp(max(ok)),
      if (bad) sprintf("; %d unreadable.", bad) else "."
    ))
    if (!is.null(panel)) {
      lines <- c(lines, sprintf(
        "A panel: %d units in column '%s', one row per unit and date (a synthetic-control layout: the SCM tools, not do-all).",
        panel$n, panel$column
      ))
    } else {
      step <- .nm_reading_step(dates)
      if (!is.null(step) && step > 0) {
        span <- as.numeric(max(ok)) - as.numeric(min(ok))
        expected <- floor(span / step) + 1
        present <- length(unique(ok))
        dup <- sum(duplicated(dates))
        lines <- c(lines, paste0(
          "Usual step ", .nm_human_step(step), "; ", .nm_count(present), " of ",
          .nm_count(expected), " timestamps at that step present (",
          .nm_count(expected - present), " missing)",
          if (dup) sprintf("; %d duplicated.", dup) else "."
        ))
      }
    }
  }
  numeric <- names(df)[vapply(df, is.numeric, TRUE) & names(df) != "date"]
  if (!is.null(target) && !target %in% names(df)) {
    lines <- c(lines, sprintf("No column '%s'.", target))
    target <- NULL
  }
  rows <- lapply(numeric, function(c) {
    s <- df[[c]]
    miss <- sum(is.na(s))
    row <- list(
      c,
      paste0(.nm_role(c), if (identical(c, target)) " (target)" else ""),
      sprintf("%s (%.1f%%)", .nm_count(miss), 100 * miss / max(length(s), 1)),
      .nm_safe_stat(min, s), .nm_safe_stat(stats::median, s), .nm_safe_stat(max, s)
    )
    if (!is.null(target)) {
      row <- c(row, list(if (identical(c, target)) "" else
        suppressWarnings(stats::cor(s, df[[target]], use = "pairwise.complete.obs"))))
    }
    row
  })
  header <- c("column", "role", "missing", "min", "median", "max")
  if (!is.null(target)) header <- c(header, paste("r with", target))
  if (length(rows)) lines <- c(lines, "", .nm_text_table(header, rows))
  other <- setdiff(names(df), c("date", numeric))
  if (length(other)) lines <- c(lines, paste0("\nNot numeric: ", paste(other, collapse = ", "), "."))
  lines <- c(lines, paste0(
    "\nRoles are read from the column names only. normet adds the time features (",
    paste(.NM_TIME_FEATURES, collapse = ", "), ") to every model itself."
  ))
  paste(lines, collapse = "\n")
}

#' modStats' columns an assistant is shown, in this order.
#' @noRd
.NM_READING_STATS <- c("n", "R2", "r", "RMSE", "MB", "NMB", "FAC2", "COE", "IOA")

#' How well a trained model predicts: nm_modStats() on the rows it was trained
#' on, the rows held out, and all -- and its features' importance.
#' @noRd
.nm_model_reading <- function(df_prep, model) {
  stats <- nm_modStats(df_prep, model)
  cols <- intersect(.NM_READING_STATS, names(stats))
  order <- c(testing = 0, training = 1, all = 2)
  rank <- unname(order[as.character(stats$set)])
  stats <- stats[order(ifelse(is.na(rank), 9, rank)), , drop = FALSE]
  rows <- lapply(seq_len(nrow(stats)), function(i) {
    c(list(as.character(stats$set[i])), lapply(cols, function(c) stats[[c]][i]))
  })
  lines <- c(
    "Model fit (nm_modStats; 'testing' is the rows held out of training):",
    "",
    .nm_text_table(c("set", cols), rows)
  )
  fi <- tryCatch(nm_feature_importance(model), error = function(e) NULL)
  if (is.data.frame(fi) && nrow(fi) && all(c("variable", "relative_importance") %in% names(fi))) {
    vals <- as.numeric(fi$relative_importance)
    total <- sum(vals)
    if (!is.finite(total) || total == 0) total <- 1
    top <- order(-vals)[seq_len(min(12, length(vals)))]
    lines <- c(
      lines, "",
      "Feature importance (the model's own, as a share of its total):",
      "",
      .nm_text_table(c("feature", "share"), lapply(top, function(i) {
        list(as.character(fi$variable[i]), sprintf("%.1f%%", 100 * vals[i] / total))
      }))
    )
  }
  paste(lines, collapse = "\n")
}

.nm_reading_dated <- function(result) {
  df <- as.data.frame(result)
  if (!"date" %in% names(df)) {
    stop("a result needs a 'date' column", call. = FALSE)
  }
  df$date <- .nm_reading_dates(df)
  df[order(df$date), , drop = FALSE]
}

#' A normalised series against the observed one: their means overall and by year
#' (or month, for a short record), and the meteorological part (observed -
#' normalised).
#' @noRd
.nm_normalised_reading <- function(result) {
  df <- .nm_reading_dated(result)
  if (!all(c("observed", "normalised") %in% names(df))) {
    stop("expected 'observed' and 'normalised' columns, found ",
         paste(names(df), collapse = ", "), call. = FALSE)
  }
  obs <- df$observed
  norm <- df$normalised
  met <- obs - norm
  m <- function(x) mean(x, na.rm = TRUE)
  s <- function(x) stats::sd(x, na.rm = TRUE)
  lines <- c(
    sprintf("%s rows, %s to %s.", .nm_count(nrow(df)), .nm_stamp(min(df$date, na.rm = TRUE)),
            .nm_stamp(max(df$date, na.rm = TRUE))),
    sprintf(paste0("Mean observed %s, mean normalised %s; meteorological part (observed \u2212 ",
                   "normalised): mean %s, standard deviation %s."),
            .nm_num(m(obs)), .nm_num(m(norm)), .nm_num(m(met)), .nm_num(s(met))),
    sprintf("Standard deviation: observed %s, normalised %s.", .nm_num(s(obs)), .nm_num(s(norm)))
  )
  years <- length(unique(format(df$date, "%Y")))
  word <- if (years >= 3) "year" else "month"
  key <- format(df$date, if (word == "year") "%Y" else "%Y-%m")
  periods <- sort(unique(key[!is.na(key)]))
  rows <- lapply(periods, function(p) {
    o <- m(obs[key %in% p])
    n <- m(norm[key %in% p])
    list(p, o, n, o - n)
  })
  lines <- c(lines, "", sprintf("Means by %s:", word), "",
             .nm_text_table(c(word, "observed", "normalised", "met part"), rows))
  other <- setdiff(names(df), c("date", "observed", "normalised"))
  if (length(other)) lines <- c(lines, paste0("\nAlso in the result: ", paste(other, collapse = ", "), "."))
  paste(lines, collapse = "\n")
}

#' Each component of a decomposition: its mean, spread and range.
#' @noRd
.nm_decomposition_reading <- function(result) {
  df <- as.data.frame(result)
  df$date <- NULL
  cols <- names(df)[vapply(df, is.numeric, TRUE)]
  rows <- lapply(cols, function(c) {
    x <- df[[c]]
    list(c, mean(x, na.rm = TRUE), stats::sd(x, na.rm = TRUE),
         .nm_safe_stat(min, x), .nm_safe_stat(max, x))
  })
  paste(c(
    sprintf("%s rows; %d components.", .nm_count(nrow(df)), length(cols)),
    "",
    .nm_text_table(c("component", "mean", "std", "min", "max"), rows)
  ), collapse = "\n")
}

#' A synthetic-control fit (nm_scm_diagnostics()): how closely the synthetic
#' unit follows the treated one before `cutoff`, and the effect after.
#' @noRd
.nm_scm_reading <- function(result, cutoff) {
  df <- .nm_reading_dated(result)
  d <- nm_scm_diagnostics(df, cutoff)
  get <- function(k) if (is.null(d[[k]])) NA else d[[k]]
  rows <- list(
    list("pre-period points", get("pre_n")),
    list("pre-period RMSE", get("pre_rmse")),
    list("pre-period MAE", get("pre_mae")),
    list("pre-period R\u00b2", get("pre_r2")),
    list("post-period points", get("post_n")),
    list("ATT (mean effect after the cutoff)", get("att")),
    list("cumulative effect", get("att_cum")),
    list("post-period RMSE", get("post_rmse"))
  )
  if (isTRUE(get("n_donors") > 0)) {
    rows <- c(rows, list(
      list("donors with weight", get("n_donors")),
      list("effective number of donors", get("effective_n_donors")),
      list("largest donor share", get("top_donor_share"))
    ))
  }
  cut <- as.POSIXct(as.character(cutoff), tz = "UTC")
  rows <- c(rows, list(list("treated unit's pre-period mean",
                            mean(df$observed[df$date < cut], na.rm = TRUE))))
  pt <- d[["pre_trend"]]
  if (is.null(pt)) pt <- list()
  rows <- c(rows, list(
    list("pre-trend p-value (slope)", if (is.null(pt$p_slope)) NA else pt$p_slope),
    list("pre-trend drift (final third vs rest)", if (is.null(pt$rmpe_drift)) NA else pt$rmpe_drift)
  ))
  lines <- c(
    sprintf("Synthetic control, cutoff %s (nm_scm_diagnostics):", cutoff),
    "",
    .nm_text_table(c("", "value"), rows)
  )
  if (!is.null(pt$verdict) && !is.na(pt$verdict) && nzchar(pt$verdict)) {
    lines <- c(lines, "", sprintf("pre-trend: %s", pt$verdict))
  }
  paste(lines, collapse = "\n")
}

#' A time-series cross-validation's scores, fold by fold, with their means.
#' @noRd
.nm_cv_reading <- function(scores) {
  df <- as.data.frame(scores)
  df$date <- NULL
  for (c in names(df)) {
    if (inherits(df[[c]], c("POSIXct", "Date"))) df[[c]] <- .nm_stamp(df[[c]])
    if (is.factor(df[[c]])) df[[c]] <- as.character(df[[c]])
  }
  numeric <- names(df)[vapply(df, is.numeric, TRUE)]
  rows <- lapply(seq_len(nrow(df)), function(i) lapply(df, `[[`, i))
  lines <- c(sprintf("%d folds.", nrow(df)), "", .nm_text_table(names(df), rows))
  means <- setdiff(numeric, "fold")
  if (length(means)) {
    lines <- c(lines, "", paste0("Means over the folds: ", paste(
      vapply(means, function(c) paste(c, .nm_num(mean(df[[c]], na.rm = TRUE))), ""),
      collapse = ", "
    ), "."))
  }
  paste(lines, collapse = "\n")
}

#' A trend test on a series (nm_trend result): its direction and the
#' Mann-Kendall test, the slope with its interval, and -- where the record is
#' autocorrelated -- the block-bootstrap interval and Wald p, which is the one
#' to quote (the classical MK p is anti-conservative there and says so).
#' @noRd
.nm_trend_reading <- function(res, name = "series") {
  t <- res$test
  s <- res$slope
  unit <- if (s$time_unit == "day") "per day" else "per step"
  rows <- list(
    c("series", res$name),
    c("rows used", res$n)
  )
  if (res$n_dropped) rows <- c(rows, list(c("missing dropped", res$n_dropped)))
  rows <- c(rows, list(
    c("direction (5%)", .nm_trend_direction(t)),
    c("Mann-Kendall S", t$S),
    c("MK z", .nm_num(t$z, 3)),
    c("MK p (two-sided, classical)", .nm_num(t$p, 4)),
    c(paste0("slope (", unit, ")"), .nm_num(s$slope, 4)),
    c(
      paste0("slope 95% CI (", unit, ")"),
      paste0("[", .nm_num(s$ci_low, 4), ", ", .nm_num(s$ci_high, 4), "]")
    )
  ))
  if (!is.null(s$slope_per_year)) {
    rows <- c(rows, list(c("slope per year", .nm_num(s$slope_per_year, 4))))
  }
  rows <- c(rows, list(
    c("AR(1) residual acf", .nm_num(res$ar1_acf, 3)),
    c("AR(1) p", .nm_num(res$ar1_p, 4))
  ))
  if (res$ar_autocorrelated) {
    if (!is.null(res$boot_slope_se)) {
      rows <- c(rows, list(
        c("bootstrap SE (block)", .nm_num(res$boot_slope_se, 4)),
        c(
          paste0("bootstrap 95% CI (", unit, ")"),
          paste0("[", .nm_num(res$boot_ci_low, 4), ", ", .nm_num(res$boot_ci_high, 4), "]")
        ),
        c("p (Wald on block bootstrap)", .nm_num(res$p_wald_boot, 4)),
        c("block length", res$block_length),
        c("bootstrap replicates", res$n_bootstrap)
      ))
      rows <- c(rows, list(c(
        "quote",
        paste0(
          res$name, ": ", .nm_trend_direction(t), " at 5%, slope ", .nm_num(s$slope, 4), " ", unit,
          " (bootstrap CI [", .nm_num(res$boot_ci_low, 4), ", ", .nm_num(res$boot_ci_high, 4), "], ",
          "p_wald ", .nm_num(res$p_wald_boot, 4), ")"
        )
      )))
    } else {
      rows <- c(rows, list(
        c("quote", "AR(1) detected but the block bootstrap was unavailable \u2014 see the notes")
      ))
    }
  }
  lines <- c(paste0("Trend test on ", name, " (nm_trend):"), "")
  lines <- c(lines, .nm_text_table(c("", "value"), rows))
  if (length(res$notes)) lines <- c(lines, "", res$notes)
  paste(lines, collapse = "\n")
}

#' A segmented trend test on a series (nm_trend_breaks result): where the trend
#' breaks, each segment with its own Theil-Sen slope and Sen (1968) interval,
#' and the block-bootstrap p of the search over every candidate position -- the
#' multiple-testing-corrected, autocorrelation-aware one to quote; the record's
#' reason for staying one regime where the gates refused a split.
#' @noRd
.nm_trend_breaks_reading <- function(res, name = "series") {
  unit <- if (res$time_unit == "day") "per day" else "per step"
  rows <- list(
    c("series", res$name),
    c("rows used", res$n),
    c("segments", res$n_segments)
  )
  if (res$n_dropped) rows <- c(rows, list(c("missing dropped", res$n_dropped)))
  header <- c("start", "end", "n", paste0("slope (", unit, ")"), "slope 95% CI", "slope per year")
  seg_rows <- lapply(seq_along(res$segments), function(i) {
    seg <- res$segments[[i]]
    c(
      .nm_fmt_index(res$starts[i]),
      .nm_fmt_index(res$ends[i]),
      seg$n,
      .nm_num(seg$slope, 4),
      paste0("[", .nm_num(seg$ci_low, 4), ", ", .nm_num(seg$ci_high, 4), "]"),
      if (!is.null(seg$slope_per_year)) .nm_num(seg$slope_per_year, 3) else "n/a"
    )
  })
  lines <- c(paste0("Segmented trend test on ", name, " (nm_trend_breaks):"), "")
  if (res$n_segments > 1L) {
    breaks <- paste(vapply(res$starts[-1L], .nm_fmt_index, ""), collapse = ", ")
    rows <- c(rows, list(
      c("break(s)", breaks),
      c("single-slope SSE", .nm_num(res$sse_single, 6)),
      c("segmented SSE", .nm_num(res$sse_segmented, 6)),
      c("SSE improvement", paste0(.nm_num(res$improvement_pct, 1), " %")),
      c("BIC (single / segmented)", paste0(" ", .nm_num(res$bic_single, 6), " / ", .nm_num(res$bic_segmented, 6))),
      c("p (block bootstrap of the search)", .nm_num(res$p_value, 4)),
      c("alpha", res$alpha)
    ))
    if (!is.null(res$n_bootstrap)) {
      rows <- c(rows, list(
        c("bootstrap replicates", res$n_bootstrap),
        c("block length", res$block_length)
      ))
    }
    lines <- c(lines, .nm_text_table(c("", "value"), rows))
    lines <- c(lines, "", .nm_text_table(header, seg_rows))
    lines <- c(lines, "", paste0(
      "Quote: ", res$n_segments, " segments, break(s) at ", breaks, "; ",
      "p=", .nm_num(res$p_value, 4), " (block bootstrap over ", res$n_bootstrap, " resamples ",
      "is the multiple-testing-corrected, autocorrelation-aware test -- the one ",
      "to quote). Each segment's Theil-Sen slope above, with its interval; ",
      "compare adjacent segments against their Sen intervals, do not re-test."
    ))
  } else {
    rows <- c(rows, list(
      c("single-slope SSE", .nm_num(res$sse_single, 6)),
      c("BIC (single / searched)", paste0(" ", .nm_num(res$bic_single, 6), " / ", .nm_num(res$bic_segmented, 6)))
    ))
    if (!is.null(res$p_value)) {
      rows <- c(rows, list(
        c("best candidate cut", if (!is.null(res$best_break)) .nm_fmt_index(res$best_break) else "n/a"),
        c("best candidate SSE improvement", paste0(.nm_num(res$best_split_pct, 1), " %")),
        c("p (block bootstrap of the search)", .nm_num(res$p_value, 4))
      ))
    }
    lines <- c(lines, .nm_text_table(c("", "value"), rows))
    # the notes say where the search wanted to cut and why it was refused
  }
  if (length(res$notes)) lines <- c(lines, "", res$notes)
  paste(lines, collapse = "\n")
}
