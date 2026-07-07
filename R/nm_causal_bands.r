#' Build Uncertainty Bands from Placebo-in-Space Results
#'
#' \code{nm_effect_bands_space} constructs the uncertainty or significance bands
#' derived from the distribution of placebo effects (donor units treated as placebos).
#'
#' @details
#' This function calculates the range of effects observed in the donor pool.
#' \itemize{
#'   \item **Method "quantile"**: Calculates the empirical quantiles (e.g., 2.5% and 97.5%) of the placebo effects at each time point.
#'   \item **Method "std"**: Calculates the mean +/- z * SD of the placebo effects.
#' }
#' Typically, if the observed effect for the treated unit falls outside these bands
#' during the post-treatment period, the effect is considered statistically significant.
#'
#' @param placebo_space_out The list returned by `nm_placebo_in_space`.
#' @param level Numeric; the confidence level for the bands (default 0.95).
#' @param method Character; method for band construction: "quantile" (default) or "std".
#' @param verbose Logical; should the function print log messages? Default is TRUE.
#'
#' @return A data frame containing:
#' \itemize{
#'   \item `date`: Timestamp.
#'   \item `effect`: The observed effect (Treatment - Synthetic).
#'   \item `lower`: The lower bound of the placebo distribution.
#'   \item `upper`: The upper bound of the placebo distribution.
#'   \item `plc_q_low`, `plc_q_high`: (method = "quantile") raw placebo
#'     quantiles at `alpha`/`1 - alpha` (identical to `lower`/`upper`).
#'   \item `plc_p10`, `plc_p90`: (method = "quantile") 10th/90th percentiles
#'     of the placebo distribution at each date.
#'   \item `plc_mean`, `plc_std`, `z`: (method = "std") placebo mean,
#'     standard deviation, and the normal critical value used for the bands.
#' }
#'
#' @export
nm_effect_bands_space <- function(placebo_space_out, level = 0.95, method = "quantile", verbose = TRUE) {

  log <- nm_get_logger("analysis.bands.space")

  if (verbose) log$info("Building effect bands from placebo-in-space results (method: %s)...", method)

  # --- 1. Validate Treated Unit Data ---
  df_true <- placebo_space_out$treated
  if (is.null(df_true) || !"effect" %in% colnames(df_true)) {
    stop("`placebo_space_out$treated` must be a data frame with an 'effect' column.")
  }

  # Initialize output with master dates and original effect
  out <- df_true[, c("date", "effect")]

  # --- 2. Process Placebos ---
  plc_list <- placebo_space_out$placebos

  # Handle empty placebo list gracefully
  if (length(plc_list) == 0) {
    if (verbose) log$warn("No placebo series available; returning effect with NA bands.")
    out$lower <- NA_real_
    out$upper <- NA_real_
    return(out)
  }

  # Combine all placebo dataframes (Base R equivalent of bind_rows)
  flat_plc <- do.call(rbind, plc_list)

  # Validate columns
  if (!all(c("unit", "effect", "date") %in% names(flat_plc))) {
    stop("Placebo results must contain 'unit', 'date', and 'effect' columns.")
  }

  # Aggregate to ensure unique unit-date pairs (equivalent to pivot_wider's values_fn=mean)
  # This handles potential rare duplicates safely
  flat_plc_agg <- aggregate(effect ~ date + unit, data = flat_plc, FUN = mean)

  # --- 3. Construct Matrix (Base R approach for pivot_wider + left_join) ---
  # Target dimensions
  target_dates <- out$date
  unique_units <- sort(unique(flat_plc_agg$unit))

  # Initialize matrix with NAs
  plc_mat <- matrix(NA, nrow = length(target_dates), ncol = length(unique_units))
  rownames(plc_mat) <- as.character(target_dates)
  colnames(plc_mat) <- unique_units

  # Map data to matrix coordinates
  # match() finds the row index for each placebo date in the master date vector
  row_idx <- match(flat_plc_agg$date, target_dates)
  col_idx <- match(flat_plc_agg$unit, unique_units)

  # Only fill if the date exists in the target dataframe
  valid_mask <- !is.na(row_idx)

  if (any(valid_mask)) {
    plc_mat[cbind(row_idx[valid_mask], col_idx[valid_mask])] <- flat_plc_agg$effect[valid_mask]
  }

  # Check if matrix is effectively empty
  if (ncol(plc_mat) == 0 || all(is.na(plc_mat))) {
    log$warn("Placebo matrix is empty after alignment.")
    out$lower <- NA_real_
    out$upper <- NA_real_
    return(out)
  }

  # --- 4. Compute Bands ---
  if (method == "quantile") {
    alpha <- (1.0 - level) / 2.0

    # Calculate empirical quantiles row-wise (per date)
    out$lower <- apply(plc_mat, 1, quantile, probs = alpha, na.rm = TRUE)
    out$upper <- apply(plc_mat, 1, quantile, probs = 1.0 - alpha, na.rm = TRUE)

    # Diagnostics: raw placebo-distribution quantiles (lower/upper *are*
    # these quantiles in R's band definition; named here for parity with
    # the Python `effect_bands_space` output schema).
    out$plc_q_low <- out$lower
    out$plc_q_high <- out$upper
    out$plc_p10 <- apply(plc_mat, 1, quantile, probs = 0.10, na.rm = TRUE)
    out$plc_p90 <- apply(plc_mat, 1, quantile, probs = 0.90, na.rm = TRUE)

  } else if (method == "std") {
    z <- stats::qnorm(0.5 + level / 2.0)

    # Calculate Mean and SD row-wise
    mu <- rowMeans(plc_mat, na.rm = TRUE)
    sd_val <- apply(plc_mat, 1, sd, na.rm = TRUE)

    # Parametric bands: Mean +/- Z * SD
    out$lower <- mu - (z * sd_val)
    out$upper <- mu + (z * sd_val)

    # Diagnostics: placebo-distribution mean/sd and the critical value used.
    out$plc_mean <- mu
    out$plc_std <- sd_val
    out$z <- z

  } else {
    stop("`method` must be 'quantile' or 'std'.")
  }

  return(out)
}


#' Build Event-Time Uncertainty Bands from Placebo-in-Time Results
#'
#' Constructs uncertainty bands aligned to event time (k = 0, 1, ..., K-1)
#' from the output of \code{nm_placebo_in_time}. Each placebo segment is
#' aligned to its own cutoff and truncated to a common horizon K.
#'
#' @param placebo_time_out List returned by \code{nm_placebo_in_time}.
#' @param level Numeric; confidence level for the bands (default 0.95).
#' @param method Character; \code{"quantile"} (default) or \code{"std"}.
#' @param horizon Integer or NULL; event-time window length K. If NULL,
#'        uses the minimum segment length across all placebos.
#' @param return_segments Logical; if TRUE, also return the aligned
#'        placebo segments matrix (default FALSE).
#'
#' @return A list with:
#' \itemize{
#'   \item \code{bands}: data.frame indexed by \code{event_time} (0..K-1).
#'         For \code{"quantile"}: columns \code{lower, upper, p10, p90}.
#'         For \code{"std"}: columns \code{mean, std, lower, upper}.
#'   \item \code{segments}: data.frame (K x P) or NULL.
#'   \item \code{cutoffs}: character vector of placebo cutoff labels.
#' }
#' @export
nm_effect_bands_time <- function(placebo_time_out, level = 0.95,
                                 method = "quantile", horizon = NULL,
                                 return_segments = FALSE) {
  plc_dict <- placebo_time_out[["placebos"]]
  if (!is.list(plc_dict) || length(plc_dict) == 0) {
    stop("`placebo_time_out$placebos` must be a non-empty named list.")
  }

  segments <- list()
  labels   <- character()
  lengths  <- integer()

  for (key in names(plc_dict)) {
    df_eff <- plc_dict[[key]]
    if (!is.data.frame(df_eff) || nrow(df_eff) == 0) next
    seg <- if ("effect" %in% colnames(df_eff)) df_eff[["effect"]] else df_eff[[1]]
    seg <- as.numeric(seg)
    if (length(seg) < 2) next
    segments <- c(segments, list(seg))
    labels   <- c(labels, key)
    lengths  <- c(lengths, length(seg))
  }

  if (length(segments) == 0) {
    stop("No valid placebo segments in `placebo_time_out`.")
  }

  K <- if (is.null(horizon)) min(lengths) else {
    if (!is.numeric(horizon) || horizon <= 0) stop("`horizon` must be a positive integer.")
    as.integer(horizon)
  }

  P <- length(segments)
  M <- matrix(NA_real_, nrow = K, ncol = P,
              dimnames = list(NULL, labels))
  for (j in seq_len(P)) {
    M[, j] <- segments[[j]][seq_len(K)]
  }

  bands <- data.frame(event_time = seq(0L, K - 1L))

  if (method == "quantile") {
    alpha        <- (1.0 - level) / 2.0
    bands$lower  <- apply(M, 1, quantile, probs = alpha,       na.rm = TRUE)
    bands$upper  <- apply(M, 1, quantile, probs = 1.0 - alpha, na.rm = TRUE)
    bands$p10    <- apply(M, 1, quantile, probs = 0.10,        na.rm = TRUE)
    bands$p90    <- apply(M, 1, quantile, probs = 0.90,        na.rm = TRUE)
  } else if (method == "std") {
    z            <- stats::qnorm(0.5 + level / 2.0)
    mu           <- rowMeans(M, na.rm = TRUE)
    sd_val       <- apply(M, 1, sd, na.rm = TRUE)
    bands$mean   <- mu
    bands$std    <- sd_val
    bands$lower  <- mu - z * sd_val
    bands$upper  <- mu + z * sd_val
  } else {
    stop("`method` must be 'quantile' or 'std'.")
  }

  seg_df <- if (return_segments) as.data.frame(M) else NULL

  list(bands = bands, segments = seg_df, cutoffs = labels)
}


#' Build Uncertainty Bands from Bootstrap or Jackknife Results
#'
#' @description
#' Construct confidence bands for the treatment effect using either
#' nonparametric bootstrap or leave-one-donor-out jackknife methods.
#'
#' @details
#' **Robustness & Resource Management (Auto-Recovery):**
#' This function implements a defensive "Auto-Recovery" strategy for the `mlscm` (H2O) backend.
#' It defines an internal helper `ensure_h2o_alive()` that runs before the global initialization,
#' before the reference run, and before *every* iteration of the bootstrap/jackknife loops.
#'
#' If the H2O cluster is found to be inactive, crashed, or unreachable (e.g., due to
#' "Empty reply from server" errors), the function automatically attempts to restart the
#' cluster using the provided `n_cores` and `max_mem_size`. This prevents long-running
#' jobs from failing completely due to intermittent connection drops.
#'
#' @param df A long-format panel data frame containing the data.
#' @param date_col The name of the date column.
#' @param unit_col The name of the unit identifier column.
#' @param outcome_col The name of the outcome variable column.
#' @param treated_unit The identifier of the treated unit.
#' @param cutoff_date The intervention date (in "YYYY-MM-DD" format or Date object).
#' @param donors Optional character vector of donor units. If NULL, all units other than
#'   the treated unit are used.
#' @param scm_backend The synthetic control backend to use: \code{"scm"} (Classic) or
#'   \code{"mlscm"} (Machine Learning/H2O).
#' @param method The uncertainty estimation method: \code{"bootstrap"} or \code{"jackknife"}.
#' @param B Integer; the number of bootstrap replications (only used if \code{method = "bootstrap"}).
#'   Default is 200.
#' @param seed Integer; random seed for reproducibility (only used if \code{method = "bootstrap"}).
#' @param donor_frac Numeric; the fraction of donors to sample in each bootstrap replication.
#'   Default is 0.8.
#' @param time_block_days Integer; the size of time blocks (in days) for block bootstrap resampling.
#'   If NULL, simple random sampling is used.
#' @param ci_level Numeric; the confidence interval level (e.g., 0.95 for 95 percent bands).
#' @param verbose Logical; should the function print INFO/WARN log messages? Default is \code{TRUE}.
#' @param n_cores Integer; number of CPU cores to use for the H2O cluster (only for `mlscm`).
#'   If NULL, defaults to auto-detection.
#' @param max_mem_size Character; maximum memory allocation for H2O (e.g., "4g", "16g").
#'   Strongly recommended for `mlscm` to prevent crashes.
#' @param shutdown_on_exit Logical; if TRUE, shuts down the H2O cluster when the function finishes.
#'   Set to FALSE if you plan to run multiple uncertainty analyses sequentially to save startup time.
#'   Default is TRUE.
#' @param ... Additional arguments passed to the underlying SCM runner (\code{nm_run_scm}).
#'
#' @return A list containing:
#' \describe{
#'   \item{treated}{A data frame with the original observed and synthetic paths for the treated unit.}
#'   \item{low}{A named numeric vector representing the lower bound of the uncertainty band.}
#'   \item{high}{A named numeric vector representing the upper bound of the uncertainty band.}
#'   \item{jackknife_effects}{(Optional) If \code{method = "jackknife"}, a data frame containing the effect paths from each jackknife run.}
#' }
#'
#' @importFrom stats qnorm quantile setNames
#' @export
nm_uncertainty_bands <- function(df, date_col, unit_col, outcome_col, treated_unit, cutoff_date,
                                 donors = NULL, scm_backend = "scm", method = "jackknife",
                                 B = 200, seed = 7654321, donor_frac = 0.8,
                                 time_block_days = NULL, ci_level = 0.95, verbose = TRUE,
                                 n_cores = NULL, max_mem_size = NULL,
                                 shutdown_on_exit = TRUE, # New parameter for smart lifecycle
                                 ...) {
  # --- 0. Initial Setup ---
  log <- nm_get_logger("causal.uncertainty")
  scm_backend <- tolower(scm_backend)

  # Ensure date column is Date type and parse cutoff date
  df[[date_col]] <- as.Date(df[[date_col]])
  cutoff_ts <- as.Date(cutoff_date)

  # [DEFENSIVE HELPER]: Ensure H2O is alive; restart if dead.
  ensure_h2o_alive <- function() {
    if (scm_backend == "mlscm") {
      # 1. Check status safely (handle case where clusterIsUp throws error)
      is_up <- tryCatch(
        {
          h2o::h2o.clusterIsUp()
        },
        error = function(e) FALSE)

      # 2. If down, force init
      if (!is_up) {
        if (verbose) log$warn("H2O cluster is inactive or unreachable. Starting new instance...")

        # Attempt 1: Use package wrapper
        tryCatch(
          {
            nm_init_h2o(n_cores = n_cores, max_mem_size = max_mem_size, verbose = FALSE)
          },
          error = function(e) {
            # Attempt 2: Fallback to raw h2o.init if wrapper fails
            if (verbose) log$warn("nm_init_h2o failed, falling back to raw h2o.init()...")
            h2o::h2o.init(nthreads = if (is.null(n_cores)) -1 else n_cores,
              max_mem_size = max_mem_size)
          })

        # 3. Final Verification
        if (!tryCatch(h2o::h2o.clusterIsUp(), error = function(e) FALSE)) {
          stop("Fatal Error: Failed to start H2O cluster after multiple attempts.")
        }
      }
    }
  }

  # --- 1. Global H2O Initialization ---
  if (scm_backend == "mlscm") {
    ensure_h2o_alive() # Ensure alive BEFORE calling no_progress
    try(h2o::h2o.no_progress(), silent = TRUE)

    # [Smart Lifecycle]: Only shutdown if requested
    if (shutdown_on_exit) {
      on.exit(
        {
          if (verbose) log$info("Shutting down H2O cluster (shutdown_on_exit=TRUE)...")
          try(nm_stop_h2o(quiet = TRUE), silent = TRUE)
        },
        add = TRUE)
    } else {
      if (verbose) log$info("H2O cluster kept alive for future runs (shutdown_on_exit=FALSE).")
    }
  }

  # --- 2. Build and Validate Donor Pool ---
  all_units <- sort(unique(df[[unit_col]]))
  base_donors <- if (is.null(donors)) {
    setdiff(all_units, treated_unit)
  } else {
    intersect(donors, setdiff(all_units, treated_unit))
  }
  if (length(base_donors) < 3) stop("Need at least 3 donors in the pool.")

  # --- 3. Reference SCM Run (point estimate) ---
  if (verbose) log$info("Running baseline SCM...")

  # Ensure alive again before critical step
  ensure_h2o_alive()

  df_true <- nm_run_scm(
    df = df,
    date_col = date_col,
    unit_col = unit_col,
    outcome_col = outcome_col,
    treated_unit = treated_unit,
    cutoff_date = cutoff_date,
    donors = base_donors,
    scm_backend = scm_backend,
    n_cores = NULL,      # Reuse existing cluster
    max_mem_size = NULL, # Reuse existing cluster
    ...,
    verbose = FALSE
  )
  effect_index <- df_true$date
  effect_series <- df_true$effect

  # --- 4. Bootstrap Method ---
  if (tolower(method) == "bootstrap") {
    set.seed(seed)
    eff_paths <- list()

    pre_dates <- unique(df[[date_col]][df[[date_col]] < cutoff_ts])
    pre_days <- sort(unique(as.Date(pre_dates)))

    if (!requireNamespace("progress", quietly = TRUE)) stop("Package 'progress' is required.")
    pb <- progress::progress_bar$new(format = "  Bootstrap [:bar] :percent :eta", total = B, clear = FALSE, width = 60)

    for (b in seq_len(B)) {
      # [Robustness] Check before every iteration
      ensure_h2o_alive()

      # Resample
      k <- max(3, round(length(base_donors) * donor_frac))
      k <- min(k, length(base_donors))
      sub_donors <- sample(base_donors, size = k, replace = (k > length(base_donors)))

      # Block Bootstrap
      df_b <- df
      if (!is.null(time_block_days) && time_block_days > 0 && length(pre_days) >= time_block_days) {
        n_blocks <- max(1, floor(length(pre_days) / time_block_days))
        starts <- sample(0:(length(pre_days) - time_block_days), size = n_blocks, replace = TRUE)
        boot_days <- unlist(lapply(starts, function(s) pre_days[(s + 1):(s + time_block_days)]))
        boot_days <- as.Date(boot_days)
        is_pre <- df_b[[date_col]] < cutoff_ts
        keep_pre <- as.Date(df_b[[date_col]]) %in% boot_days
        df_b <- rbind(df_b[is_pre & keep_pre, ], df_b[!is_pre, ])
      }

      tryCatch(
        {
          out_b <- nm_run_scm(
            df = df_b, date_col = date_col, unit_col = unit_col, outcome_col = outcome_col,
            treated_unit = treated_unit, cutoff_date = cutoff_date, donors = sub_donors,
            scm_backend = scm_backend,
            n_cores = NULL, max_mem_size = NULL, # Pass NULL to attach to existing
            ..., verbose = FALSE
          )
          eff_paths[[length(eff_paths) + 1]] <- out_b$effect
        },
        error = function(e) {
          # [Robustness] Handle connection crash
          msg <- e$message
          if (grepl("connect", msg, ignore.case = TRUE) || grepl("empty reply", msg, ignore.case = TRUE)) {
            if (verbose) log$warn("Bootstrap crash on iter %d. Hard restarting H2O...", b)
            # Kill the zombie process so ensure_h2o_alive() restarts a fresh one next loop
            try(h2o::h2o.shutdown(prompt = FALSE), silent = TRUE)
          } else {
            if (verbose) log$warn("Bootstrap replicate failed: %s", msg)
          }
        })

      # Periodic GC
      if (scm_backend == "mlscm" && b %% 50 == 0) try(
        {
          h2o::h2o.removeAll()
          gc(verbose = FALSE)
        },
        silent = TRUE)
      pb$tick()
    }

    if (length(eff_paths) == 0) return(list(treated = df_true, low = NA, high = NA))

    M <- do.call(rbind, eff_paths)
    alpha <- (1 - ci_level) / 2
    q_low <- apply(M, 2, stats::quantile, probs = alpha, na.rm = TRUE)
    q_high <- apply(M, 2, stats::quantile, probs = 1 - alpha, na.rm = TRUE)

    return(list(
      treated = df_true,
      low = stats::setNames(q_low, effect_index),
      high = stats::setNames(q_high, effect_index)
    ))
  }

  # --- 5. Jackknife Method ---
  if (tolower(method) == "jackknife") {
    n <- length(base_donors)
    jackknife_paths <- list()

    if (!requireNamespace("progress", quietly = TRUE)) stop("Package 'progress' is required.")
    pb <- progress::progress_bar$new(format = "  Jackknife [:bar] :percent :eta", total = n, clear = FALSE, width = 60)

    for (d in base_donors) {
      # [Robustness] Check before every iteration
      ensure_h2o_alive()

      donors_jk <- setdiff(base_donors, d)
      tryCatch(
        {
          out_jk <- nm_run_scm(
            df = df, date_col = date_col, unit_col = unit_col, outcome_col = outcome_col,
            treated_unit = treated_unit, cutoff_date = cutoff_date, donors = donors_jk,
            scm_backend = scm_backend,
            n_cores = NULL, max_mem_size = NULL, # Pass NULL to attach to existing
            ..., verbose = FALSE
          )
          jackknife_paths[[length(jackknife_paths) + 1]] <- out_jk$effect
        },
        error = function(e) {
          # [Robustness] Handle connection crash
          msg <- e$message
          if (grepl("connect", msg, ignore.case = TRUE) || grepl("empty reply", msg, ignore.case = TRUE)) {
            if (verbose) log$warn("Jackknife crash on unit %s. Hard restarting H2O...", d)
            try(h2o::h2o.shutdown(prompt = FALSE), silent = TRUE)
          } else {
            if (verbose) log$warn("Jackknife failed for donor %s: %s", d, msg)
          }
        })

      # Periodic GC
      if (scm_backend == "mlscm") try(
        {
          h2o::h2o.removeAll()
          gc(verbose = FALSE)
        },
        silent = TRUE)
      pb$tick()
    }

    if (length(jackknife_paths) == 0) return(list(treated = df_true, low = NA, high = NA))

    jack_df <- do.call(cbind, jackknife_paths)
    theta_dot <- rowMeans(jack_df, na.rm = TRUE)
    diffs <- sweep(jack_df, 1, theta_dot, FUN = "-")
    se <- sqrt(((n - 1) / n) * rowSums(diffs^2, na.rm = TRUE))
    z <- stats::qnorm(0.5 + ci_level / 2)
    low <- effect_series - z * se
    high <- effect_series + z * se

    return(list(
      treated = df_true,
      low = stats::setNames(low, effect_index),
      high = stats::setNames(high, effect_index),
      jackknife_effects = as.data.frame(jack_df)
    ))
  }

  stop("`method` must be either 'bootstrap' or 'jackknife'")
}


#' Plot Treatment Effect with Uncertainty Bands
#'
#' @description
#' `nm_plot_effect_with_bands` creates a ggplot visualization of a treatment
#' effect and its corresponding uncertainty bands. Supports output from both
#' [nm_effect_bands_space()] (date-indexed) and event-time bands derived from
#' [nm_effect_bands_time()] (an `event_time` column), provided an `effect`
#' column has been attached.
#'
#' @param bands_df A data frame containing an `effect` column and either a
#'   `date` or `event_time` column. Band columns may be named `lower`/`upper`
#'   or `low`/`high`; if neither pair is present, only the effect line is drawn.
#' @param cutoff_date Optional. Vertical reference line marking the
#'   intervention. A string/Date when `bands_df` has a `date` column, or an
#'   integer (e.g. `0`) when it has an `event_time` column.
#' @param title The title for the plot.
#' @param band_label Character; legend label for the shaded band (default
#'   `"placebo band"`). Used by [nm_plot_uncertainty_bands()] to distinguish
#'   "jackknife band" / "bootstrap band".
#'
#' @return A ggplot object.
#' @export
nm_plot_effect_with_bands <- function(bands_df, cutoff_date = NULL,
                                       title = "Effect with Placebo Bands",
                                       band_label = "placebo band") {
  if (!"effect" %in% colnames(bands_df)) {
    stop("bands_df must contain an 'effect' column.")
  }

  # Resolve x-axis: datetime ('date') or event-time ('event_time')
  if ("date" %in% colnames(bands_df)) {
    bands_df$.x <- as.Date(bands_df$date)
    x_label <- "Date"
    is_event_time <- FALSE
  } else if ("event_time" %in% colnames(bands_df)) {
    bands_df$.x <- bands_df$event_time
    x_label <- "Event time"
    is_event_time <- TRUE
  } else {
    stop("bands_df must contain a 'date' or 'event_time' column.")
  }

  # Accept either naming convention for the band columns
  lower_col <- if ("lower" %in% colnames(bands_df)) "lower" else if ("low" %in% colnames(bands_df)) "low" else NULL
  upper_col <- if ("upper" %in% colnames(bands_df)) "upper" else if ("high" %in% colnames(bands_df)) "high" else NULL

  # Ensure ggplot2 is available
  nm_require("ggplot2")

  p <- ggplot2::ggplot(bands_df, ggplot2::aes(x = .x))

  if (!is.null(lower_col) && !is.null(upper_col)) {
    p <- p +
      ggplot2::geom_ribbon(
        ggplot2::aes(ymin = !!rlang::sym(lower_col), ymax = !!rlang::sym(upper_col), fill = band_label),
        alpha = 0.5
      ) +
      ggplot2::scale_fill_manual(name = NULL, values = stats::setNames("grey80", band_label))
  }

  p <- p +
    # Updated: use linewidth instead of size
    ggplot2::geom_line(ggplot2::aes(y = effect), color = "blue", linewidth = 1) +
    ggplot2::geom_hline(yintercept = 0, linetype = "dotted", color = "black") +
    ggplot2::labs(title = title, x = x_label, y = "Effect") +
    ggplot2::theme_minimal()

  # Optional cutoff line
  if (!is.null(cutoff_date)) {
    cutoff_x <- if (is_event_time) as.numeric(cutoff_date) else as.Date(cutoff_date)
    p <- p + ggplot2::geom_vline(xintercept = cutoff_x, linetype = "dashed", color = "red")
  }

  return(p)
}


#' Plot treatment effect with uncertainty bands
#'
#' @description
#' A wrapper around `nm_plot_effect_with_bands` that accepts the list output
#' from `nm_uncertainty_bands`. The shaded band is labelled "jackknife band"
#' if `band_result` contains `jackknife_effects`, "bootstrap band" if `title`
#' mentions "bootstrap", or "uncertainty band" otherwise.
#'
#' @param band_result A list returned by `nm_uncertainty_bands()`, containing:
#'   - treated: data.frame with columns "date" and "effect"
#'   - low: named numeric vector of lower bounds
#'   - high: named numeric vector of upper bounds
#'   - jackknife_effects: (optional) data.frame, present iff method = "jackknife"
#' @param cutoff_date Optional string in "YYYY-MM-DD" format to mark intervention time.
#' @param title Plot title.
#'
#' @return A ggplot object showing effect curve and confidence bands.
#' @export
nm_plot_uncertainty_bands <- function(band_result, cutoff_date = NULL, title = "Treatment Effect with Uncertainty Bands") {
  # --- 1. Validate input structure ---
  if (!all(c("treated", "low", "high") %in% names(band_result))) {
    stop("Input must be a list with 'treated', 'low', and 'high'.")
  }

  df <- band_result$treated
  low <- band_result$low
  high <- band_result$high

  # --- 2. Check required columns in treated data ---
  if (!("date" %in% colnames(df)) || !("effect" %in% colnames(df))) {
    stop("`treated` must contain 'date' and 'effect' columns.")
  }

  # --- 3. Assemble plotting data frame ---
  plot_df <- df[, c("date", "effect")]
  plot_df$date <- as.Date(plot_df$date)  # Ensure date format

  # Match lower and upper bounds by date
  # Use as.character ensures we match dates correctly even if indices are slightly different types
  date_keys <- as.character(plot_df$date)

  # Handle cases where dates in df might not strictly match names in low/high
  # (Though they usually should if coming from nm_uncertainty_bands)
  plot_df$lower <- as.numeric(low[date_keys])
  plot_df$upper <- as.numeric(high[date_keys])

  # --- 4. Label the band by estimation method ---
  band_label <- "uncertainty band"
  if ("jackknife_effects" %in% names(band_result)) {
    band_label <- "jackknife band"
  } else if (grepl("bootstrap", title, ignore.case = TRUE)) {
    band_label <- "bootstrap band"
  }

  # --- 5. Delegate to the main plotting function ---
  p <- nm_plot_effect_with_bands(
    bands_df = plot_df,
    cutoff_date = cutoff_date,
    title = title,
    band_label = band_label
  )

  return(p)
}
