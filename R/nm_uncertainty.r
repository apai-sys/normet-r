# Uncertainty decomposition: how much of the total spread is weather or model.
#
# Ported from Python normet analysis/uncertainty.py. De-weathering hands the
# analyst a deweathered estimate with a Monte-Carlo spread, and an ensemble of
# models a wider, model-form spread. The question neither of those numbers
# answers is the one a policy evaluation must settle: of the total band around a
# policy's estimated effect, how much is the met resampling and how much is the
# model-form uncertainty? If an effect is smaller than the band, whether it is
# "significant" depends on which error dominates, and the honest answer comes
# from attributing the variance to its source.
#
# nm_decompose_uncertainty() attributes the total per-date variance to its
# source by an orthogonal (two-way) decomposition of the full model-by-weather
# prediction matrix, exploiting the package's common-random-number discipline
# rather than adding a new source of randomness:
#
# - Every ensemble member is given the *same* n_samples met resamples. The
#   nm_normalise draws are seeded once -- the user's seed -- and are therefore
#   identical across models (the resample rows are a pure function of the seed),
#   which is the common-random-number anchor the package already relies on for
#   decompose's differences to be comparable. The models differ only by form:
#   member i is trained on its own seed.
# - For one timestamp the response is a matrix Z of shape n_models x
#   n_samples: the prediction of member i on met draw j. Its total variance
#   (over both factors, mean-centred) splits orthogonally into the
#   between-model main effect (the model-form variance), the between-draw main
#   effect (the weather variance), and the interaction (what is not additive --
#   a model that reacts differently to a met draw than the ensemble does). The
#   total is exactly the three summands, with every term non-negative. The
#   identity is pinned by a test, so a future change to the decomposition
#   cannot quietly break the additivity the attribution rests on.
#
# The per-date result is one row of var_weather / var_model /
# var_interaction / var_total and their pct_* shares; the result object carries
# the median share across the record in summary() and a stacked-variance-band
# figure in plot(). The cost is one prediction per (model, draw, timestamp) --
# the same total count as one normalise-ensemble run -- so the attribution
# costs no extra fits.

#' Attribute a de-weathered estimate's total spread to weather and model form
#'
#' Trains `n_models` members (each on its own seed, so they differ in form) and,
#' for each, predicts on the *same* `n_samples` met resamples shared across the
#' whole ensemble. The per-date variance of that (n_models, n_samples) response
#' is split orthogonally into the weather, model and interaction terms; see the
#' module comments for the construction and why the three summands sum to the
#' total exactly.
#'
#' Member seeds: Python derives them from `np.random.default_rng(c(seed, 1))`;
#' R derives them from the global stream after `set.seed(seed)` (the package's
#' seeding convention). Both are reproducible under `seed`, but the two
#' languages draw different members, so member-level numbers are not
#' cross-language comparable -- the decomposition's structure is.
#'
#' @param df Input dataset with a `date` column (datetime) and the target.
#' @param target The target column name.
#' @param backend The backend the ensemble members are trained with. `"lightgbm"`
#'   (the default) because `n_models` fits must each be fast; `"h2o"` for its
#'   own search.
#' @param covariates The model's feature set. Required and non-empty; it must be
#'   a superset of the model's actual features, as `nm_normalise()` enforces.
#' @param variables_resample Which covariates the met resampling draws. Defaults
#'   to all the non-time-feature covariates, as `nm_normalise()` does.
#' @param split_method Train/test split. `"ts"` (the default) so the training
#'   sets of the members are the same rows under different seeds -- only the
#'   model form varies, which is the quantity the decomposition isolates.
#' @param train_fraction Fraction of the record used to train. Default 0.75.
#' @param model_config Backend-specific model settings. With the lightgbm
#'   default, keep it small (the ensemble is `n_models` fits).
#' @param n_samples Met resamples per member -- the weather-draw factor.
#'   Default 300.
#' @param n_models Ensemble members -- the model-form factor. Default 10.
#' @param seed The *weather* seed: every member shares it, so the met draws are
#'   the common-random-number anchor and are reproducible. Member seeds are
#'   derived from it, so the whole decomposition is reproducible under `seed`.
#'   Default 7654321.
#' @param n_cores Forwarded to `nm_normalise()` for the resampling loop.
#' @param resample_df Optional pool to draw the met resamples from. Forwarded
#'   to `nm_normalise()`; defaults to the record itself.
#' @param verbose Verbose logging for the first member only.
#' @return An object of class `nm_unc_decomposition`: the per-date
#'   `var_weather` / `var_model` / `var_interaction` / `var_total` (the target's
#'   units squared, `var_total` their exact sum), the record's `date` index, and
#'   the run's provenance. Methods: `summary()` (per-source median variance and
#'   share), `as.data.frame()` (the per-date rows), `plot()` (the stacked
#'   bands), `print()`.
#' @export
nm_decompose_uncertainty <- function(df, target, backend = "lightgbm",
                                     covariates = NULL, variables_resample = NULL,
                                     split_method = "ts", train_fraction = 0.75,
                                     model_config = NULL, n_samples = 300,
                                     n_models = 10, seed = 7654321,
                                     n_cores = NULL, resample_df = NULL,
                                     verbose = FALSE) {
  if (n_samples < 2) {
    stop("`n_samples` must be at least 2: the weather factor needs a draw to vary.",
      call. = FALSE
    )
  }
  if (n_models < 2) {
    stop(
      "`n_models` must be at least 2: with one model there is no model-form variance to attribute (the spread is then all weather).",
      call. = FALSE
    )
  }
  if (is.null(covariates) || length(covariates) == 0) {
    stop("`covariates` must be provided and non-empty.", call. = FALSE)
  }
  covariates <- as.character(covariates)

  # The date features are added by nm_prepare_data itself: hand it the external
  # covariates only, as nm_build_model does (a caller such as the window names
  # the calendar columns with the met ones, and they are not in the raw table).
  known_time_vars <- c("date_unix", "day_julian", "weekday", "hour")
  covariates_for_prep <- setdiff(covariates, known_time_vars)
  if (length(covariates_for_prep) == 0) {
    stop(
      "`covariates` must name at least one column of the table, not calendar features alone.",
      call. = FALSE
    )
  }

  log <- nm_get_logger("analysis.uncertainty")
  df_prep <- nm_prepare_data(
    df = df,
    target = target,
    covariates = covariates_for_prep,
    split_method = split_method,
    train_fraction = train_fraction,
    seed = seed
  )
  missing_preds <- setdiff(covariates, colnames(df_prep))
  if (length(missing_preds) > 0) {
    stop(sprintf(
      "The following requested covariates are missing from prepared data: %s",
      paste(missing_preds, collapse = ", ")
    ), call. = FALSE)
  }
  # The member seeds, derived from the user's seed (R's stream, see the
  # function docs for the Python counterpart).
  set.seed(seed)
  member_seeds <- sample.int(1000000L, size = as.integer(n_models), replace = FALSE)
  if (verbose) {
    log$info(
      "decompose_uncertainty: %d members x %d met draws on %d timestamps (seed=%d)",
      n_models, n_samples, nrow(df_prep), seed
    )
  }

  n_dates <- nrow(df_prep)
  z <- array(NA_real_, dim = c(n_models, n_samples, n_dates))
  for (i in seq_len(n_models)) {
    ms <- member_seeds[i]
    model_i <- switch(
      as.character(backend),
      lightgbm = nm_train_lgb(
        df_prep, target = "value", covariates = covariates,
        model_config = model_config, seed = ms, verbose = verbose && i == 1L
      ),
      h2o = nm_train_h2o(
        df_prep, target = "value", covariates = covariates,
        model_config = model_config, seed = ms, verbose = verbose && i == 1L
      )
    )
    if (is.null(model_i)) {
      stop(sprintf("Unknown backend '%s' (use 'lightgbm' or 'h2o').", backend), call. = FALSE)
    }
    # All members see the same met draws: anchor the resampling on the user's
    # seed, not the member seed, so draw j is identical across i.
    wide <- nm_normalise(
      df_prep, model_i,
      resample_vars = variables_resample,
      n_samples = n_samples,
      aggregate = FALSE,
      seed = seed,
      n_cores = 1L,
      resample_df = resample_df,
      memory_save = FALSE,
      verbose = FALSE
    )
    z[i, , ] <- .nm_unc_met_matrix(wide, n_samples, n_dates, df_prep$date)
    if (verbose) log$info("member %d/%d done", i, n_models)
  }

  decomp <- .nm_unc_decompose(z)
  notes <- c(
    "Each source's variance is a two-way main effect; 'interaction' is what the models do not share about a met draw (a residual, not an independent draw).",
    "Shares are medians across the record; a single extreme day cannot re-weight them.",
    "All members share the same n_samples met resamples (common random numbers), so the total per-date variance equals the three summands exactly, to floating point."
  )
  structure(
    list(
      var_weather = decomp$var_weather,
      var_model = decomp$var_model,
      var_interaction = decomp$var_interaction,
      var_total = decomp$var_total,
      date = df_prep$date,
      target = as.character(target),
      n_models = as.integer(n_models),
      n_weather_draws = as.integer(n_samples),
      seed = as.integer(seed),
      notes = notes
    ),
    class = "nm_unc_decomposition"
  )
}

# ---------------------------------------------------------------------------
# The per-member met matrix and the two-way split
# ---------------------------------------------------------------------------

#' The wide per-draw table of one member as (n_samples, n_dates).
#'
#' The draw columns are ordered by their seed value, so draw j is the same met
#' resample across every member (common random numbers).
#' @noRd
.nm_unc_met_matrix <- function(wide, n_samples, n_dates, dates) {
  draw_cols <- setdiff(names(wide), c("date", "observed"))
  draw_cols <- draw_cols[order(as.numeric(draw_cols))]
  w <- as.data.frame(wide)
  ord <- order(w$date)
  m <- as.matrix(w[ord, draw_cols, drop = FALSE])
  if (nrow(m) != n_dates) {
    stop(
      sprintf("The met table has %d dates, the record %d.", nrow(m), n_dates),
      call. = FALSE
    )
  }
  t(m)
}

#' The two-way orthogonal split of the model-by-draw matrix, all timestamps at once.
#'
#' `z` is (n_models, n_samples, n_dates): the prediction of member i on met draw
#' j at each timestamp. At one timestamp the mean is removed once, then the
#' variance is partitioned by the two factors: the model mean (over draws) and
#' the draw mean (over models) are the two main effects, and what the two do not
#' account for jointly is the interaction. The partition is orthogonal, so the
#' total variance is exactly the three summands and each is a sum of squares
#' (hence non-negative).
#' @noRd
.nm_unc_decompose <- function(z) {
  I <- dim(z)[1]
  J <- dim(z)[2]
  T <- dim(z)[3]
  # (i - 1) * J + j, t: member i, draw j, timestamp t. R's column-major layout
  # makes the first index fastest, so the dimensions are permuted to (draw,
  # model, timestamp) before flattening: the rows read off as members' blocks
  # of draws and the columns are the timestamps.
  m <- matrix(as.vector(aperm(z, c(2L, 1L, 3L))), nrow = I * J, ncol = T)
  grand <- colMeans(m)
  per_model <- matrix(NA_real_, I, T)
  for (i in seq_len(I)) {
    per_model[i, ] <- colMeans(m[(i - 1L) * J + seq_len(J), , drop = FALSE])
  }
  per_draw <- matrix(NA_real_, J, T)
  for (j in seq_len(J)) {
    per_draw[j, ] <- colMeans(m[seq(j, I * J, by = J), , drop = FALSE])
  }
  gm <- matrix(grand, I, T, byrow = TRUE)
  gj <- matrix(grand, J, T, byrow = TRUE)
  gij <- matrix(grand, I * J, T, byrow = TRUE)
  var_model <- colMeans((per_model - gm)^2)
  var_weather <- colMeans((per_draw - gj)^2)
  interaction <- m -
    (per_model[rep(seq_len(I), each = J), , drop = FALSE] +
      per_draw[rep(seq_len(J), times = I), , drop = FALSE] - gij)
  var_interaction <- colMeans(interaction^2)
  var_total <- colMeans((m - gij)^2)
  list(
    var_weather = var_weather,
    var_model = var_model,
    var_interaction = var_interaction,
    var_total = var_total
  )
}

# ---------------------------------------------------------------------------
# The result object
# ---------------------------------------------------------------------------

#' The share of `var_total` a part carries, NA where the total is zero.
#' @noRd
.nm_unc_pct <- function(part, total) {
  ifelse(total > 0, part / ifelse(total > 0, total, 1), NA_real_)
}

#' The per-date rows as a data frame, report-ready and directly plottable.
#' @param x The result of \code{\link{nm_decompose_uncertainty}}.
#' @param ... Unused.
#' @export
as.data.frame.nm_unc_decomposition <- function(x, ...) {
  data.frame(
    date = x$date,
    var_weather = x$var_weather,
    var_model = x$var_model,
    var_interaction = x$var_interaction,
    var_total = x$var_total,
    pct_weather = .nm_unc_pct(x$var_weather, x$var_total),
    pct_model = .nm_unc_pct(x$var_model, x$var_total),
    pct_interaction = .nm_unc_pct(x$var_interaction, x$var_total),
    stringsAsFactors = FALSE
  )
}

#' The per-source median variance and its median share of the total.
#'
#' The shares are the headline of a policy evaluation ("of the band, this
#' fraction is weather, that one is model form"), so they are medians across the
#' record rather than means: a single extreme day does not re-weight the
#' attribution. `interaction` is the residual the other two do not explain,
#' reported like the others so its size is visible.
#' @param object The result of \code{\link{nm_decompose_uncertainty}}.
#' @param ... Unused.
#' @export
summary.nm_unc_decomposition <- function(object, ...) {
  data.frame(
    source = c("weather", "model", "interaction", "total"),
    var_median = c(
      stats::median(object$var_weather, na.rm = TRUE),
      stats::median(object$var_model, na.rm = TRUE),
      stats::median(object$var_interaction, na.rm = TRUE),
      stats::median(object$var_total, na.rm = TRUE)
    ),
    pct_median = c(
      stats::median(.nm_unc_pct(object$var_weather, object$var_total), na.rm = TRUE),
      stats::median(.nm_unc_pct(object$var_model, object$var_total), na.rm = TRUE),
      stats::median(.nm_unc_pct(object$var_interaction, object$var_total), na.rm = TRUE),
      1.0
    ),
    stringsAsFactors = FALSE
  )
}

#' A one-line reading of the decomposition (the median spread shares).
#' @param x The result of \code{\link{nm_decompose_uncertainty}}.
#' @param ... Unused.
#' @export
print.nm_unc_decomposition <- function(x, ...) {
  n <- length(x$date)
  med_w <- stats::median(.nm_unc_pct(x$var_weather, x$var_total), na.rm = TRUE)
  med_m <- stats::median(.nm_unc_pct(x$var_model, x$var_total), na.rm = TRUE)
  med_i <- stats::median(.nm_unc_pct(x$var_interaction, x$var_total), na.rm = TRUE)
  cat(sprintf(
    "%s: %d dates, %d models x %d met draws | median spread share: weather %.0f%%, model %.0f%%, interaction %.0f%%\n",
    x$target, n, x$n_models, x$n_weather_draws,
    100 * med_w, 100 * med_m, 100 * med_i
  ))
  invisible(x)
}

#' The stacked per-date variance bands (weather, model, interaction).
#'
#' The three sources stack to `var_total` on every date, so the height of the
#' stack is the total spread the model and the met resampling together carry,
#' and each band's height is that source's share. The figure is the
#' policy-evaluation deliverable: which band dominates the total, date by date
#' and in the median.
#' @param x The result of \code{\link{nm_decompose_uncertainty}}.
#' @param title Plot title. Default "Uncertainty: where the spread comes from".
#' @param ylabel The y-axis label.
#' @param ... Passed to the ggplot2 theme.
#' @export
plot.nm_unc_decomposition <- function(x, title = NULL,
                                      ylabel = "Variance (target units^2)", ...) {
  nm_require("ggplot2")
  long <- data.frame(
    date = rep(x$date, 3L),
    source = rep(c("weather", "model", "interaction"), each = length(x$date)),
    var = c(x$var_weather, x$var_model, x$var_interaction)
  )
  long$source <- factor(long$source, levels = c("weather", "model", "interaction"))
  total <- data.frame(date = x$date, var = x$var_total, source = "total")
  ggplot2::ggplot(long, ggplot2::aes(date, var, fill = source)) +
    ggplot2::geom_area(alpha = 0.85) +
    ggplot2::scale_fill_manual(
      name = NULL,
      values = c(
        weather = nm_palette[1],
        model = nm_palette[2],
        interaction = nm_palette[4]
      )
    ) +
    ggplot2::geom_line(
      data = total,
      mapping = ggplot2::aes(date, var, colour = source),
      inherit.aes = FALSE,
      linewidth = .pt_lw(0.8)
    ) +
    ggplot2::scale_colour_manual(name = NULL, values = c(total = nm_colours[["ink"]])) +
    ggplot2::labs(title = title %||% "Uncertainty: where the spread comes from",
      x = NULL, y = ylabel
    ) +
    nm_theme_normet() +
    ggplot2::theme(legend.position = "top")
}
