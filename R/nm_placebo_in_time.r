# Placebo-in-Time Test for Synthetic Control
#
# Ported from Python normet causal/placebo.py
# Tests the robustness of the SCM estimate by varying the cutoff date.

NULL

#' Placebo-in-Time Test
#'
#' Runs placebo-in-time tests by shifting the treatment cutoff date to
#' placebo positions before the true cutoff. The distribution of placebo
#' effects provides a p-value for the true estimate.
#'
#' @inheritParams nm_placebo_in_space
#' @param min_pre_period Integer. Minimum pre-period days before placebo
#'        cutoff. Default 30.
#' @param placebo_every Integer. Step size (in days) between placebo cutoffs.
#'        Default 7.
#' @param n_cores Number of CPU cores. For \code{scm_backend = "scm"}, the
#'        placebo cutoffs are run in parallel via \pkg{foreach}/\pkg{doSNOW}
#'        using this many workers (default: detected cores minus one). For
#'        \code{"mlscm"}, this instead sets the H2O cluster size and the
#'        placebo cutoffs are run sequentially.
#'
#' @return A list with \code{treated} (data.frame), \code{placebos} (list of
#'         data.frames), \code{p_value}, \code{ref_band_event_time}
#'         (data.frame of quantiles by event time \code{k}), and
#'         \code{placebo_stats} (named numeric).
#' @export
nm_placebo_in_time <- function(df, date_col = "date", unit_col = "code",
                               outcome_col = "poll", treated_unit = NULL,
                               cutoff_date = NULL, donors = NULL,
                               scm_backend = "scm", post_agg = "mean",
                               min_pre_period = 30, placebo_every = 7,
                               model_config = NULL,
                               n_cores = NULL, max_mem_size = NULL,
                               verbose = TRUE, ...) {
  log <- nm_get_logger("causal.placebo.time")

  df[[date_col]] <- as.Date(df[[date_col]])
  cutoff_ts <- as.Date(cutoff_date)

  if (is.null(treated_unit)) stop("`treated_unit` required.")
  all_units <- sort(unique(df[[unit_col]]))
  if (is.null(donors)) donors <- setdiff(all_units, treated_unit)

  # True treated run
  df_true <- nm_run_scm(df = df, date_col = date_col, unit_col = unit_col,
    outcome_col = outcome_col, treated_unit = treated_unit,
    cutoff_date = cutoff_ts, donors = donors,
    scm_backend = scm_backend,
    model_config = model_config,
    n_cores = n_cores, max_mem_size = max_mem_size,
    verbose = verbose, ...)

  # Determine placebo cutoff candidates
  treated_dates <- sort(unique(df[[date_col]][df[[unit_col]] == treated_unit]))
  post_len <- sum(df_true$date >= cutoff_ts)
  if (post_len == 0) stop("No post-period observations.")

  placebo_candidates <- c()
  for (i in seq(min_pre_period, length(treated_dates) - post_len)) {
    pc <- treated_dates[i]
    if (pc >= cutoff_ts) break
    idx_end <- i + post_len - 1
    if (idx_end <= length(treated_dates) && treated_dates[idx_end] < cutoff_ts) {
      placebo_candidates <- c(placebo_candidates, pc)
    }
  }
  if (placebo_every > 1 && length(placebo_candidates) > 1) {
    placebo_candidates <- placebo_candidates[seq(1, length(placebo_candidates), placebo_every)]
  }

  # `c()` strips the Date class from accumulated elements; restore it so
  # downstream `format()`/`nm_run_scm()` calls receive proper Date values.
  placebo_candidates <- as.Date(placebo_candidates, origin = "1970-01-01")

  if (length(placebo_candidates) == 0) {
    log$warn("No valid placebo cutoffs found.")
    return(list(treated = df_true, placebos = list(), p_value = NA_real_,
      ref_band_event_time = NULL, placebo_stats = numeric()))
  }

  # Run placebos
  placebo_dict <- list()
  placebo_stats <- numeric()
  agg_fun <- if (post_agg == "sum") sum else mean

  run_one_placebo <- function(pc) {
    tryCatch(
      {
        syn_pc <- nm_run_scm(df = df, date_col = date_col, unit_col = unit_col,
          outcome_col = outcome_col, treated_unit = treated_unit,
          cutoff_date = pc, donors = donors,
          scm_backend = scm_backend,
          model_config = model_config,
          n_cores = NULL, max_mem_size = NULL,
          verbose = FALSE, ...)
        # Align to treated dates
        eff_aligned <- syn_pc$effect[match(treated_dates, syn_pc$date)]
        start_idx <- which(treated_dates == pc)
        if (length(start_idx) == 0) return(NULL)
        seg <- eff_aligned[start_idx:(start_idx + post_len - 1)]
        if (length(seg) != post_len) return(NULL)

        list(
          pc_key = format(pc, "%Y-%m-%d"),
          seg_df = data.frame(date = treated_dates[start_idx:(start_idx + post_len - 1)],
            effect = seg,
            stringsAsFactors = FALSE),
          stat = agg_fun(seg, na.rm = TRUE)
        )
      },
      error = function(e) {
        log$debug("Placebo cutoff %s failed: %s", pc, e$message)
        NULL
      })
  }

  # Resolve worker count for the classic SCM backend (mirrors nm_scm_all)
  n_cores_eff <- n_cores
  if (is.null(n_cores_eff)) {
    if (Sys.getenv("_R_CHECK_LIMIT_CORES_", "") != "") {
      n_cores_eff <- 2
    } else {
      detected <- parallel::detectCores(logical = FALSE) - 1
      if (is.na(detected) || length(detected) == 0) {
        detected <- parallel::detectCores(logical = TRUE) - 1
      }
      n_cores_eff <- max(1, detected)
    }
  }
  if (Sys.getenv("_R_CHECK_LIMIT_CORES_", "") != "") {
    n_cores_eff <- min(n_cores_eff, 2)
  }
  n_cores_eff <- max(1, n_cores_eff)

  use_parallel <- scm_backend == "scm" && n_cores_eff > 1 && length(placebo_candidates) > 1 &&
    requireNamespace("foreach", quietly = TRUE) && requireNamespace("doSNOW", quietly = TRUE)

  if (use_parallel) {
    if (verbose) log$info("Running %d placebo-in-time cutoffs using %d parallel cores.", length(placebo_candidates), n_cores_eff)

    cl <- parallel::makeCluster(n_cores_eff)
    .nm_propagate_libpaths(cl)
    doSNOW::registerDoSNOW(cl)
    on.exit(parallel::stopCluster(cl), add = TRUE)

    opts <- list()
    if (requireNamespace("progress", quietly = TRUE)) {
      pb <- progress::progress_bar$new(total = length(placebo_candidates), format = "  Placebo-in-time [:bar] :percent :eta", width = 60)
      opts <- list(progress = function(n) pb$tick())
    }

    results <- foreach::foreach(
      pc = placebo_candidates,
      .packages = c("glmnet", "quadprog", "stats"),
      .export = c("nm_run_scm", "nm_scm", "run_one_placebo"),
      .options.snow = opts
    ) %dopar% run_one_placebo(pc)
  } else {
    if (verbose && length(placebo_candidates) > 1) log$info("Running %d placebo-in-time cutoffs sequentially.", length(placebo_candidates))
    results <- lapply(placebo_candidates, run_one_placebo)
  }

  for (res in results) {
    if (is.null(res)) next
    placebo_dict[[res$pc_key]] <- res$seg_df
    placebo_stats[res$pc_key] <- res$stat
  }

  if (length(placebo_dict) == 0) {
    return(list(treated = df_true, placebos = list(), p_value = NA_real_,
      ref_band_event_time = NULL, placebo_stats = numeric()))
  }

  # P-value
  obs_stat <- agg_fun(df_true$effect[df_true$date >= cutoff_ts], na.rm = TRUE)
  p_value <- (sum(abs(placebo_stats) >= abs(obs_stat), na.rm = TRUE) + 1) /
    (length(placebo_stats) + 1)

  # Event-time reference band
  M <- do.call(cbind, lapply(placebo_dict, `[[`, "effect"))
  k_index <- seq_len(nrow(M)) - 1
  ref_band <- data.frame(
    event_time = k_index,
    p10 = apply(M, 1, quantile, 0.10, na.rm = TRUE),
    p90 = apply(M, 1, quantile, 0.90, na.rm = TRUE),
    ci_lo = apply(M, 1, quantile, 0.025, na.rm = TRUE),
    ci_hi = apply(M, 1, quantile, 0.975, na.rm = TRUE),
    std = apply(M, 1, sd, na.rm = TRUE)
  )

  list(treated = df_true, placebos = placebo_dict, p_value = p_value,
    ref_band_event_time = ref_band, placebo_stats = placebo_stats)
}
