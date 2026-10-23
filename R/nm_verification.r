# Skill scores for probabilistic forecasts: CRPS and its pinball components
#
# Ported from Python normet analysis/verification.py. Point forecasts are verified
# by nm_Stats (FAC2, RMSE, ...). The question those cannot answer is the one every
# comparison with a baseline must settle: how much better is the forecast, in the
# spread it carries, than the climatology or persistence it is up against? The
# Continuous Ranked Probability Score (CRPS) scores a forecast's whole distribution
# against the observation; it is non-negative, in the same units as the quantity,
# and is the standard skill score for probabilistic forecasts (Gneiting and
# Raftery, 2005, Journal of the American Statistical Association 100:724).
#
# - nm_pinball_loss        : the quantile (pinball) loss at one quantile level --
#                            the elementary score the others are built from.
# - nm_crps_from_quantiles : the CRPS of a quantile forecast, by exact
#                            integration; the qNNN columns a normalise run returns
#                            (with quantiles) are its direct input.
# - nm_crps_from_samples   : the CRPS of ensemble samples, each sample carrying its
#                            rank as a quantile level. The wide table a normalise
#                            run returns with aggregate = FALSE is its direct input.
# - nm_crps_observed       : the point forecast's reference on a skill table: its
#                            MAE read as a normal's own MAE (sigma * sqrt(2/pi)), so
#                            the score is the sigma that would carry it -- the MAE
#                            times sqrt(pi/2) ~= 1.253 -- which puts model and
#                            baseline on one scale.
#
# The first three scores are comparable on equal records with the same units;
# nm_crps_observed is the reference a point forecast carries on the same record.

#' A point forecast's MAE read as a normal's own MAE (sigma * sqrt(2/pi)),
#' multiplied back to the sigma that would carry it: sqrt(pi/2).
.NM_POINT_MASS_FACTOR <- sqrt(pi / 2.0)

#' Validate a quantile level and return it in (0, 1).
#' @noRd
.nm_quantile_level <- function(q, what = "quantile level") {
  level <- suppressWarnings(as.numeric(q))
  if (length(level) != 1L || is.na(level)) {
    stop(sprintf("%s %s is not a number.", what, deparse(q)), call. = FALSE)
  }
  if (!(level > 0 && level < 1)) {
    stop(sprintf("%s must be in (0, 1): got %s", what, deparse(level)), call. = FALSE)
  }
  level
}

#' The level a quantile column names: q025 -> 0.025, else itself.
#' @noRd
.nm_column_level <- function(name) {
  s <- as.character(name)
  if (grepl("^q[0-9]+$", s)) {
    return(as.integer(sub("^q", "", s)) / 1000)
  }
  .nm_quantile_level(name, sprintf("the quantile label '%s'", s))
}

#' The observation as a one-dimensional numeric vector.
#' @noRd
.nm_obs_array <- function(obs) {
  o <- if (is.data.frame(obs) || data.table::is.data.table(obs)) {
    if (ncol(obs) != 1L) stop("The observation must be one value per row.", call. = FALSE)
    as.numeric(obs[[1L]])
  } else {
    as.numeric(obs)
  }
  if (length(dim(o)) > 1L) {
    stop("The observation must be one value per row.", call. = FALSE)
  }
  o
}

#' One value per row, one column where a frame is passed.
#' @noRd
.nm_single_column <- function(x, what) {
  if (is.data.frame(x) || data.table::is.data.table(x)) {
    if (ncol(x) != 1L) {
      stop(sprintf("%s must be one value per row.", what), call. = FALSE)
    }
    return(as.numeric(x[[1L]]))
  }
  v <- as.numeric(x)
  if (length(dim(v)) > 1L) {
    stop(sprintf("%s must be one value per row.", what), call. = FALSE)
  }
  v
}

#' The quantile forecast as a (rows, levels) numeric matrix and its levels.
#'
#' A frame carries one column per level: its qNNN columns where quantiles is left
#' out, else the named columns. A matrix's columns are the levels, and then
#' quantiles must be given. One level is a point prediction, not a distribution to
#' score.
#' @noRd
.nm_levels_and_values <- function(preds, quantiles) {
  if (is.data.frame(preds) || data.table::is.data.table(preds)) {
    frame <- as.data.frame(preds)
    if (is.null(quantiles)) {
      names_ <- sort(grep("^q[0-9]+$", names(frame), value = TRUE))
      if (length(names_) < 2L) {
        stop(
          "A quantile frame needs its levels labelled qNNN (e.g. q025, q500, q975): ",
          "pass quantiles = to name them.",
          call. = FALSE
        )
      }
    } else {
      names_ <- as.character(quantiles)
      missing_ <- setdiff(names_, names(frame))
      if (length(missing_)) {
        stop(sprintf("No such column(s) in the frame: %s", paste(missing_, collapse = ", ")),
          call. = FALSE
        )
      }
    }
    levels_ <- vapply(names_, .nm_column_level, numeric(1))
    p <- as.matrix(frame[, names_, drop = FALSE])
  } else {
    # A bare vector is one level: a point prediction, not a distribution. (As a
    # matrix it would read as n rows of one level and ask for the levels it
    # cannot know; the vector case is the point-prediction error, as py's.)
    if (is.null(dim(preds))) {
      stop("One level is a point prediction: score it with nm_crps_observed.", call. = FALSE)
    }
    p <- as.matrix(preds)
    if (nrow(p) > 0 && ncol(p) == 0L) {
      stop("One level is a point prediction: score it with nm_crps_observed.", call. = FALSE)
    }
    if (length(dim(p)) != 2L) {
      stop("A quantile array needs a shape (rows, levels).", call. = FALSE)
    }
    if (is.null(quantiles)) {
      stop("An array of quantiles needs quantiles = to say what level each is.", call. = FALSE)
    }
    if (length(quantiles) != ncol(p)) {
      stop(sprintf("%d levels for a table of %d levels.", length(quantiles), ncol(p)),
        call. = FALSE
      )
    }
    levels_ <- vapply(quantiles, .nm_quantile_level, numeric(1))
  }
  if (nrow(p) == 0L) {
    stop("Nothing to score: the record is empty.", call. = FALSE)
  }
  if (length(unique(levels_)) != length(levels_)) {
    stop("The quantile levels repeat.", call. = FALSE)
  }
  list(p = p, levels = levels_)
}

#' One row's CRPS, exactly.
#'
#' The CDF is the piecewise-linear curve through the row's quantile points
#' (value, level): flat 0 below the smallest value, flat 1 above the largest, a
#' repeated value a vertical piece of measure zero, and the score is the integral
#' of (F - 1{x >= y})^2. On the break-point grid of the distinct values and y the
#' integrand is a quadratic per interval -- the indicator is constant on each,
#' since y is one of the break points -- and the pieces are integrated exactly,
#' tails and off-span observations included.
#' @noRd
.nm_row_crps <- function(vs, tv, y) {
  ord <- order(vs, method = "radix")  # stable, as numpy's kind = "stable"
  vs <- vs[ord]
  tv <- tv[ord]
  v <- unique(vs)  # the distinct values, in order
  inv <- match(vs, v)
  m <- length(v)
  u <- as.numeric(tapply(tv, inv, max))  # a value group's level: its highest
  grid <- sort(unique(c(v, y)))
  pos <- findInterval(grid, v)  # the largest v <= grid, 1-based (0 below all)
  if (m >= 2L) {
    i <- pmin(pmax(pos, 1L), m - 1L)
    denom <- v[i + 1L] - v[i]
    t <- ifelse(denom > 0, (grid - v[i]) / ifelse(denom > 0, denom, 1), 0)
    base <- u[i] + t * (u[i + 1L] - u[i])
  } else {
    base <- numeric(length(grid))
  }
  fr <- ifelse(
    grid >= v[m],
    1.0,
    ifelse(grid == v[1L], u[1L], ifelse(grid > v[1L], base, 0.0))
  )
  fl <- ifelse(grid <= v[1L], 0.0, ifelse(grid > v[m], 1.0, base))
  a <- fr[-length(fr)]  # each interval's CDF at its left end
  b <- fl[-1L]  # and its right end
  d <- diff(grid)
  ind <- as.numeric(grid[-length(grid)] >= y)  # 1{x >= y} on the interval
  c_ <- a - ind
  slope <- ifelse(d > 0, (b - a) / ifelse(d > 0, d, 1), 0.0)
  seg <- c_ * c_ * d + c_ * slope * d * d + (slope * slope * d * d * d) / 3.0
  sum(seg)
}

#' The CRPS of quantile forecasts p (rows x levels matrix) at levels against y
#' (one per row): the mean of the rows' exact scores.
#' @noRd
.nm_crps_rows <- function(p, levels, y) {
  n <- nrow(p)
  total <- 0.0
  for (i in seq_len(n)) {
    total <- total + .nm_row_crps(p[i, ], levels, y[i])
  }
  total / n
}

#' The quantile (pinball) loss of a forecast against the observation at one level
#'
#' For the residual r = obs - pred the loss is max(q r, (q-1) r): an under-forecast
#' costs q per unit short, an over-forecast 1 - q; the mean is lowest when the
#' forecast is the true q-quantile, and at q = 0.5 it is half the mean absolute
#' error. Non-finite rows are dropped, as the rest of the package scores them.
#'
#' @param preds The forecast's quantile column (or one sample of it); one value per
#'   row. A vector, or a one-column data frame.
#' @param obs The observation; one value per row, the same rows.
#' @param q The quantile level, in (0, 1), that preds forecasts.
#' @return The mean pinball loss over the finite rows, in the data's units.
#' @export
nm_pinball_loss <- function(preds, obs, q) {
  level <- .nm_quantile_level(q)
  p <- .nm_single_column(preds, "A single quantile's forecast")
  o <- .nm_obs_array(obs)
  if (length(p) != length(o)) {
    stop(sprintf("The forecast has %d rows and the observation %d.", length(p), length(o)),
      call. = FALSE
    )
  }
  mask <- is.finite(p) & is.finite(o)
  if (!any(mask)) {
    stop("Nothing to score: no finite forecast-observation row.", call. = FALSE)
  }
  r <- o[mask] - p[mask]
  mean(pmax(level * r, (level - 1) * r))
}

#' The CRPS of a quantile forecast against the observation
#'
#' The forecast's distribution is the CDF linearly interpolated through its
#' quantile points, and the score is the squared distance of that CDF from the
#' observation's, integrated exactly -- the continuous form the pinball sum is a
#' trapezoidal rule for (Gneiting and Raftery 2005, in the quantile form). A
#' frame's qNNN columns are its levels; a matrix's columns are the levels, named
#' by quantiles. With few levels the interpolation is coarse and the score reads
#' high: pass the levels the forecast actually carries.
#'
#' @param preds One value per level and per row, in any column order: a data frame
#'   (its qNNN columns the levels, or the columns named by quantiles), or a
#'   (rows, levels) matrix.
#' @param obs The observation, one per row of preds.
#' @param quantiles The levels the frame's columns (or the matrix's columns) carry,
#'   for when the frame's columns are not its qNNN names. Required for a matrix.
#' @return The CRPS over the finite rows, in the data's units.
#' @export
nm_crps_from_quantiles <- function(preds, obs, quantiles = NULL) {
  lv <- .nm_levels_and_values(preds, quantiles)
  p <- lv$p
  o <- .nm_obs_array(obs)
  if (nrow(p) != length(o)) {
    stop(sprintf("The quantiles have %d rows and the observation %d.", nrow(p), length(o)),
      call. = FALSE
    )
  }
  mask <- rowSums(!is.finite(p)) == 0 & is.finite(o)
  if (!any(mask)) {
    stop("Nothing to score: no finite forecast-observation row.", call. = FALSE)
  }
  .nm_crps_rows(p[mask, , drop = FALSE], lv$levels, o[mask])
}

#' The CRPS of ensemble samples against the observation
#'
#' Each sample carries its rank as a quantile level: a row's sorted samples stand
#' at the levels 1/(K+1), ..., K/(K+1), and the score is the same integral the
#' quantile one is. A frame's columns are the samples -- the wide table a
#' normalise run returns with aggregate = FALSE is its direct input; a matrix's
#' columns are the samples.
#'
#' @param samples The ensemble, one value per sample and per row: a data frame or a
#'   (rows, K) matrix.
#' @param obs The observation, one per row.
#' @return The CRPS over the finite rows, in the data's units.
#' @export
nm_crps_from_samples <- function(samples, obs) {
  if (is.data.frame(samples) || data.table::is.data.table(samples)) {
    s <- as.matrix(as.data.frame(samples))
  } else {
    s <- as.matrix(samples)
    if (is.null(dim(s))) s <- matrix(s, ncol = 1L)
  }
  if (length(dim(s)) != 2L) {
    stop("The ensemble needs a shape (rows, samples).", call. = FALSE)
  }
  if (ncol(s) < 2L) {
    stop("One sample is a point prediction: score it with nm_crps_observed.", call. = FALSE)
  }
  o <- .nm_obs_array(obs)
  if (nrow(s) != length(o)) {
    stop(sprintf("The samples have %d rows and the observation %d.", nrow(s), length(o)),
      call. = FALSE
    )
  }
  k <- ncol(s)
  levels_ <- (seq_len(k)) / (k + 1L)
  mask <- rowSums(!is.finite(s)) == 0 & is.finite(o)
  if (!any(mask)) {
    stop("Nothing to score: no finite sample-observation row.", call. = FALSE)
  }
  s <- s[mask, , drop = FALSE]
  s[] <- t(apply(s, 1, sort, method = "radix"))  # the rank is the order
  .nm_crps_rows(s, levels_, o[mask])
}

#' The CRPS reference for a point forecast: sqrt(pi/2) times its MAE
#'
#' A point forecast carries no distribution, so there is no ensemble score to
#' compute for it; what is needed on a skill table is a reference value on the same
#' scale as a spread score. The convention is to read the forecast's mean absolute
#' error as the normal distribution's own MAE -- a Gaussian of standard deviation
#' sigma has MAE sigma * sqrt(2/pi) -- and return the sigma that would carry it,
#' which is the MAE times sqrt(pi/2) ~= 1.253. Quote it as the point forecast's
#' CRPS: it reads about 25 % above its MAE, and a spread forecast's score against
#' it answers "is the spread worth its cost?" -- the value of the spread the spread
#' forecast actually carries, not an error in either number. (A point mass's own
#' CRPS is its MAE exactly; the factor is the normal-scale convention, not the
#' degenerate integral.)
#'
#' @param y_pred The point forecast; one value per row.
#' @param y_true The observation; one value per row, the same rows.
#' @return The point forecast's CRPS reference = sqrt(pi/2) * MAE over the finite
#'   rows, in the data's units.
#' @export
nm_crps_observed <- function(y_pred, y_true) {
  p <- .nm_single_column(y_pred, "The point forecast")
  o <- .nm_obs_array(y_true)
  if (length(p) != length(o)) {
    stop(sprintf("The forecast has %d rows and the observation %d.", length(p), length(o)),
      call. = FALSE
    )
  }
  mask <- is.finite(p) & is.finite(o)
  if (!any(mask)) {
    stop("Nothing to score: no finite forecast-observation row.", call. = FALSE)
  }
  .NM_POINT_MASS_FACTOR * mean(abs(o[mask] - p[mask]))
}
