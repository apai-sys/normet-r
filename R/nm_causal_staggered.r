# Staggered Synthetic Controls
#
# Ported from Python normet causal/batch.py (run_scm_staggered).
# Several treated units, each with its own cutoff: every unit gets its own
# nm_run_scm fit on its own pre- and post-period, with the other treated
# units excluded from every run's donor pool, so one unit's intervention
# cannot leak into another unit's synthetic control.

NULL

#' Staggered Synthetic Controls
#'
#' Fit a staggered design: several treated units, each with its own cutoff.
#'
#' Every treated unit gets its own \code{\link{nm_run_scm}} fit — on its own
#' pre-period and its own post-period — with the \emph{other treated units
#' excluded from every run's donor pool}, so one unit's intervention cannot
#' leak into another unit's synthetic control (the same exclusion
#' \code{nm_placebo_in_space} applies to the single treated unit).
#'
#' Each unit's effect is the post-cutoff mean (or sum) of its effect path,
#' and each unit is ranked against its own placebo-in-space distribution:
#' every donor in turn takes the unit's role at the unit's own cutoff, and the
#' permutation \code{p_value} is the usual \code{(count + 1) / (n + 1)}. Each
#' placebo fit needs a valid pool of its own — with the default \code{"scm"}
#' backend that is at least three donors (its ridge-augmented path), so a
#' smaller pool yields NA p-values while the effects are still read.
#'
#' The summary rows aggregate the units' effects (mean and median). The
#' \code{mean} row's \code{p_value} is the cross-unit permutation test: each
#' donor in turn is assigned every treated unit's role (the full set of
#' cutoffs) and its pseudo-effects are averaged the same way the real units'
#' are; a donor with no intervention is a clean draw from the null, while the
#' real treated units are deliberately \emph{not} permuted into the reference
#' — their data already carries the intervention, and giving one of them a
#' later cutoff would pour its real effect into its own ``pre-period''. The
#' reference is therefore donor-only, which keeps the null honest in a
#' staggered design where permuting treated identities is contaminated.
#'
#' Typical use: a scheme that rolls out city by city (the UK ULEZ 2021
#' expansion, staggered driving restrictions across cities) — one row per
#' adopting city, one pooled reading for the programme as a whole.
#'
#' @param df A long-format data.frame with at least the \code{date_col},
#'   \code{unit_col} and \code{outcome_col} columns.
#' @param date_col, unit_col, outcome_col Column names in the panel.
#' @param treated_units Character vector: the units that received the
#'   intervention, in the order the summary rows are read.
#' @param cutoff_dates Character vector: the cutoff of each treated unit.
#'   Named, it is read as a mapping \code{unit -> "YYYY-MM-DD"}; unnamed, it
#'   must align with \code{treated_units}.
#' @param donors Optional character vector: the donor pool. If NULL, every
#'   unit that is not treated. Treated units in an explicit list are an
#'   error; units absent from the panel are dropped (as in
#'   \code{nm_placebo_in_space}).
#' @param scm_backend Backend forwarded to \code{nm_run_scm} (default
#'   \code{"scm"}).
#' @param post_agg \code{"mean"} or \code{"sum"}: how a unit's post-cutoff
#'   effect path is read into its effect (and how the units' effects are
#'   aggregated in the summary rows).
#' @param n_cores Number of CPU cores. The real and placebo runs share one
#'   pool, as in normet-py; NULL takes all cores minus one, capped at the
#'   number of runs.
#' @param verbose Whether to print INFO log messages. Default TRUE.
#' @param ... Additional arguments passed to \code{nm_run_scm}.
#'
#' @return A data.frame with one row per treated unit — \code{unit},
#'   \code{cutoff_date}, \code{n_pre}, \code{n_post}, \code{pre_r2} (the
#'   pre-period fit of that unit), \code{effect} (post-cutoff
#'   \code{post_agg} of the effect path) and \code{p_value} (that unit's
#'   placebo-in-space permutation) — followed by two summary rows,
#'   \code{"mean"} and \code{"median"}, of the units' effects. The
#'   \code{mean} row carries the cross-unit permutation \code{p_value}; the
#'   \code{median} row's is NA, as the test is stated on the mean.
#'
#' @details The \code{"scm"} backend runs its pool of real and placebo fits
#'   on a parallel R cluster, as \code{nm_scm_all} does; the other backends
#'   run the same jobs in order (their H2O lifecycle does not cross workers).
#'
#' @export
nm_run_scm_staggered <- function(df,
                                 date_col,
                                 unit_col,
                                 outcome_col,
                                 treated_units,
                                 cutoff_dates,
                                 donors = NULL,
                                 scm_backend = "scm",
                                 post_agg = "mean",
                                 n_cores = NULL,
                                 verbose = TRUE,
                                 ...) {
  log <- nm_get_logger("causal.staggered")

  # --- Guards ---------------------------------------------------------------
  if (is.null(treated_units) || length(treated_units) == 0) {
    stop("treated_units must not be empty.", call. = FALSE)
  }
  if (length(unique(treated_units)) != length(treated_units)) {
    stop("treated_units must be unique.", call. = FALSE)
  }
  d <- df
  d[[date_col]] <- as.Date(as.character(d[[date_col]]))
  all_units <- sort(unique(d[[unit_col]]))
  missing <- setdiff(treated_units, all_units)
  if (length(missing) > 0) {
    stop("treated units not in the panel: ", paste(missing, collapse = ", "), call. = FALSE)
  }

  # --- The cutoffs: a named mapping, or a list aligned with the units -------
  if (!(is.vector(cutoff_dates) && !is.list(cutoff_dates))) {
    stop(
      "cutoff_dates must be a character vector aligned with treated_units, ",
      "or a named vector mapping unit to cutoff date.",
      call. = FALSE
    )
  }
  if (is.null(names(cutoff_dates)) || !all(nzchar(names(cutoff_dates)))) {
    if (length(cutoff_dates) != length(treated_units)) {
      stop(
        "cutoff_dates as a list must align with treated_units ",
        paste0("(", length(cutoff_dates), " != ", length(treated_units), ")."),
        call. = FALSE
      )
    }
    dates <- as.Date(as.character(cutoff_dates))
  } else {
    missing_cut <- setdiff(treated_units, names(cutoff_dates))
    if (length(missing_cut) > 0) {
      stop(
        "cutoff_dates is missing entries for treated units: ",
        paste(missing_cut, collapse = ", "),
        call. = FALSE
      )
    }
    dates <- as.Date(as.character(cutoff_dates[treated_units]))
  }
  treated_set <- unique(treated_units)

  # --- The donor pool --------------------------------------------------------
  if (!is.null(donors)) {
    overlap <- sort(intersect(donors, treated_set))
    if (length(overlap) > 0) {
      stop("donors must not include treated units: ", paste(overlap, collapse = ", "), call. = FALSE)
    }
    donor_pool <- sort(intersect(donors, all_units))
  } else {
    donor_pool <- setdiff(all_units, treated_set)
  }
  if (length(donor_pool) == 0) {
    stop("No donor units left after excluding the treated units.", call. = FALSE)
  }

  post_agg <- tolower(post_agg %||% "mean")
  if (!post_agg %in% c("mean", "sum")) {
    log$warn("Invalid post_agg=%s; falling back to 'mean'.", post_agg)
    post_agg <- "mean"
  }

  # A treated unit whose cutoff falls after its last observation has no
  # post-period to measure: say so before any fit is spent.
  unit_dates <- lapply(split(d[[date_col]], d[[unit_col]]), sort)
  has_post <- vapply(
    seq_along(treated_units),
    function(i) any(unit_dates[[treated_units[i]]] >= dates[i]),
    logical(1)
  )
  if (any(!has_post)) {
    bad <- which(!has_post)
    stop(
      "No post-cutoff observations at/after the cutoff for treated units: ",
      paste(sprintf("%s (%s)", treated_units[bad], format(dates[bad])), collapse = ", "),
      call. = FALSE
    )
  }

  scm_backend <- tolower(scm_backend)
  dots <- list(...)

  # One pool for the real runs and for every donor taking every treated unit's
  # role — the cross-unit reference, and the material of each unit's own
  # placebo-in-space test.
  jobs <- lapply(seq_along(treated_units), function(i) {
    list(
      unit = treated_units[i], cutoff = format(dates[i], "%Y-%m-%d"),
      pool = donor_pool, kind = "real"
    )
  })
  for (u in donor_pool) {
    for (i in seq_along(treated_units)) {
      jobs[[length(jobs) + 1]] <- list(
        unit = u, cutoff = format(dates[i], "%Y-%m-%d"),
        pool = setdiff(donor_pool, u), kind = "placebo"
      )
    }
  }

  n_cores_eff <- .nm_resolve_cores(n_cores, n_tasks = length(jobs))
  if (verbose) {
    log$info(
      "nm_run_scm_staggered: scm_backend=%s | treated=%d | donors=%d | post_agg=%s | n_cores=%d",
      scm_backend, length(treated_units), length(donor_pool), post_agg, n_cores_eff
    )
  }

  # --- One fit, read back: the effect statistic, the period lengths, and the
  #     pre-period fit (real runs only). A failed fit comes back flagged, not
  #     as NULL, so the caller can say which run gave out.
  .one <- function(job) {
    base_args <- list(
      df = d, date_col = date_col, unit_col = unit_col, outcome_col = outcome_col,
      treated_unit = job$unit, cutoff_date = job$cutoff, donors = job$pool,
      scm_backend = scm_backend, verbose = FALSE
    )
    syn <- tryCatch(
      do.call(nm_run_scm, utils::modifyList(dots, base_args)),
      error = function(e) {
        structure(
          list(unit = job$unit, cutoff = job$cutoff, kind = job$kind,
               msg = conditionMessage(e)),
          class = "nm_stag_fail"
        )
      }
    )
    if (inherits(syn, "nm_stag_fail")) return(syn)
    c_ts <- as.Date(job$cutoff)
    post <- syn[syn[[date_col]] >= c_ts, , drop = FALSE]
    pre <- syn[syn[[date_col]] < c_ts, , drop = FALSE]
    stat <- if (post_agg == "mean") mean(post$effect) else sum(post$effect)
    pre_r2 <- NA_real_
    if (job$kind == "real" && nrow(pre) >= 2) {
      y <- pre$observed; x <- pre$synthetic
      ss_res <- sum((y - x)^2); ss_tot <- sum((y - mean(y))^2)
      pre_r2 <- if (ss_tot > 0) 1 - ss_res / ss_tot else NA_real_
    }
    list(unit = job$unit, cutoff = job$cutoff, stat = stat, pre_r2 = pre_r2,
         n_pre = nrow(pre), n_post = nrow(post))
  }

  if (scm_backend == "scm") {
    # The classic backend: one parallel pool for the whole job list, as in
    # nm_scm_all (the other backends run the same jobs in order: their H2O
    # lifecycle does not cross workers).
    cl <- parallel::makeCluster(n_cores_eff)
    .nm_propagate_libpaths(cl)
    doSNOW::registerDoSNOW(cl)
    on.exit(parallel::stopCluster(cl), add = TRUE)
    results <- foreach::foreach(
      i = seq_along(jobs),
      .packages = c("quadprog", "stats"),
      .export = c("nm_run_scm")
    ) %dopar% {
      .one(jobs[[i]])
    }
  } else {
    results <- lapply(jobs, .one)
  }

  real <- list()
  placebo <- list()
  for (r in results) {
    if (inherits(r, "nm_stag_fail")) {
      log$warn("Staggered %s run failed for unit %s (cutoff %s): %s",
        r$kind, r$unit, r$cutoff, r$msg)
      next
    }
    if (r$unit %in% treated_set) {
      real[[r$unit]] <- r
    } else {
      placebo[[paste(r$unit, r$cutoff, sep = "|")]] <- r$stat
    }
  }
  failed <- setdiff(treated_units, names(real))
  if (length(failed) > 0) {
    stop("Staggered fits failed for treated units: ", paste(failed, collapse = ", "), call. = FALSE)
  }

  slot_dates <- vapply(dates, format, character(1), "%Y-%m-%d")

  # The permutation p: the share of the reference at least as extreme as the
  # observation, with the +1 that keeps the minimum at 1/(n + 1).
  .perm_p <- function(obs, refs) {
    refs <- refs[is.finite(refs)]
    if (length(refs) == 0 || !is.finite(obs)) return(NA_real_)
    (sum(abs(refs) >= abs(obs)) + 1) / (length(refs) + 1)
  }

  rows <- vector("list", length(treated_units) + 2)
  unit_stats <- numeric(length(treated_units))
  for (i in seq_along(treated_units)) {
    u <- treated_units[i]
    r <- real[[u]]
    dates_u <- unit_dates[[u]]
    refs <- unlist(lapply(donor_pool, function(x) placebo[[paste(x, r$cutoff, sep = "|")]]))
    rows[[i]] <- data.frame(
      unit = u,
      cutoff_date = r$cutoff,
      n_pre = as.integer(sum(dates_u < dates[i])),
      n_post = as.integer(sum(dates_u >= dates[i])),
      pre_r2 = r$pre_r2,
      effect = r$stat,
      p_value = .perm_p(r$stat, refs),
      stringsAsFactors = FALSE
    )
    unit_stats[i] <- r$stat
  }
  stat_obs <- if (post_agg == "mean") mean(unit_stats) else sum(unit_stats)
  pooled <- numeric(0)
  for (u in donor_pool) {
    refs_u <- unlist(lapply(slot_dates, function(s) placebo[[paste(u, s, sep = "|")]]))
    refs_u <- refs_u[!is.na(refs_u)]
    if (length(refs_u) > 0) {
      pooled <- c(pooled, if (post_agg == "mean") mean(refs_u) else sum(refs_u))
    }
  }
  rows[[length(treated_units) + 1]] <- data.frame(
    unit = "mean", cutoff_date = NA_character_, n_pre = NA_integer_, n_post = NA_integer_,
    pre_r2 = NA_real_, effect = stat_obs, p_value = .perm_p(stat_obs, pooled),
    stringsAsFactors = FALSE
  )
  rows[[length(treated_units) + 2]] <- data.frame(
    unit = "median", cutoff_date = NA_character_, n_pre = NA_integer_, n_post = NA_integer_,
    pre_r2 = NA_real_, effect = median(unit_stats), p_value = NA_real_,
    stringsAsFactors = FALSE
  )
  do.call(rbind, rows)
}
