# Worker script executed by the normet-r GUI.
#
# Usage:
#   Rscript bridge.R <task> <session_dir> key=value [key=value ...]
#
# File protocol (all inside <session_dir>):
#   data.csv        raw input written by the GUI (train / scm tasks)
#   df_prep.csv     prepared data written by `train`, read by later tasks
#   model.*         trained model saved via nm_save_model
#   result.csv      main task output read back by the GUI
#   stats.csv       model statistics written by `train`
#   importance.csv  feature importance written by `train`
#   meta.txt        key=value scalars (p_value, diagnostics, ...)
#   *.csv           task-specific extras (treated/placebos/bands/segments/weights)
#
# Parameters use plain key=value tokens; list values are comma-separated.
# No JSON library is required so the bridge only depends on normet itself.

suppressMessages(library(normet))

argv <- commandArgs(trailingOnly = TRUE)
if (length(argv) < 2) stop("usage: Rscript bridge.R <task> <session_dir> [key=value ...]")
task <- argv[[1]]
session <- argv[[2]]

params <- list()
for (tok in argv[-(1:2)]) {
  kv <- regmatches(tok, regexpr("=", tok), invert = TRUE)[[1]]
  params[[kv[[1]]]] <- kv[[2]]
}

p_chr <- function(name, default = NULL) {
  if (is.null(params[[name]])) default else params[[name]]
}
p_num <- function(name, default = NULL) {
  v <- p_chr(name)
  if (is.null(v)) default else as.numeric(v)
}
p_list <- function(name) {
  v <- p_chr(name)
  if (is.null(v) || !nzchar(v)) NULL else strsplit(v, ",", fixed = TRUE)[[1]]
}
p_numlist <- function(name) {
  v <- p_list(name)
  if (is.null(v)) NULL else as.numeric(v)
}
# Like p_list, but distinguishes "not passed" (NULL, so nm_run_back_trajectories's
# own default applies) from "passed but empty" (character(0) -- e.g. the user
# unchecked every diagnostic checkbox, an explicit request for none of them).
p_diagnostics <- function(name) {
  raw <- params[[name]]
  if (is.null(raw)) NULL else if (!nzchar(raw)) character(0) else strsplit(raw, ",", fixed = TRUE)[[1]]
}
# Source-region boxes, encoded as "name:lonmin:latmin:lonmax:latmax;name2:...".
p_regions <- function(name) {
  v <- p_chr(name)
  if (is.null(v) || !nzchar(v)) return(NULL)
  out <- list()
  for (tok in strsplit(v, ";", fixed = TRUE)[[1]]) {
    parts <- strsplit(tok, ":", fixed = TRUE)[[1]]
    if (length(parts) != 5) next
    out[[parts[1]]] <- as.numeric(parts[2:5])
  }
  if (length(out)) out else NULL
}
# Bbox rows (via p_regions) plus any GeoJSON/Shapefile/anything sf::st_read()
# supports, named in parallel by region_file_names / region_file_paths. A
# single-region file uses its row's name directly; a multi-region file keeps
# its own per-feature names, prefixed with the row's name so several loaded
# files can't collide.
p_all_regions <- function() {
  merged <- p_regions("regions")
  if (is.null(merged)) merged <- list()
  names_ <- p_list("region_file_names")
  paths <- p_list("region_file_paths")
  if (!is.null(paths)) {
    for (i in seq_along(paths)) {
      loaded <- nm_load_source_regions(paths[i])
      row_name <- if (!is.null(names_) && i <= length(names_)) names_[i] else NULL
      if (length(loaded) == 1 && !is.null(row_name) && nzchar(row_name)) {
        merged[[row_name]] <- loaded[[1]]
      } else {
        for (feat_name in names(loaded)) {
          key <- if (!is.null(row_name) && nzchar(row_name)) {
            paste0(row_name, "_", feat_name)
          } else {
            feat_name
          }
          merged[[key]] <- loaded[[feat_name]]
        }
      }
    }
  }
  if (length(merged)) merged else NULL
}

TIME_VARS <- c("date_unix", "day_julian", "weekday", "hour")

fmt_dates <- function(df) {
  # write.csv drops " 00:00:00" on midnight POSIXct values, which would leave
  # a mixed-format date column for pandas to choke on.
  for (col in names(df)) {
    if (inherits(df[[col]], c("Date", "POSIXt"))) {
      df[[col]] <- format(df[[col]], "%Y-%m-%d %H:%M:%S")
    }
  }
  df
}

write_csv_at <- function(df, name) {
  utils::write.csv(fmt_dates(as.data.frame(df)), file.path(session, name), row.names = FALSE)
}

write_result <- function(df) write_csv_at(df, "result.csv")

write_meta <- function(kv) {
  lines <- vapply(names(kv), function(k) paste0(k, "=", kv[[k]]), character(1))
  writeLines(lines, file.path(session, "meta.txt"))
}

read_prepared <- function() {
  df <- utils::read.csv(file.path(session, "df_prep.csv"), stringsAsFactors = FALSE)
  df$date <- as.POSIXct(df$date, tz = "UTC")
  df
}

read_input <- function() {
  df <- utils::read.csv(file.path(session, "data.csv"), stringsAsFactors = FALSE)
  if ("date" %in% names(df)) df$date <- as.POSIXct(df$date, tz = "UTC")
  df
}

ensure_h2o <- function() {
  # Each bridge call is a fresh R process; nm_train_h2o/nm_normalise_h2o
  # assume a live cluster.  h2o.init() inside nm_init_h2o connects to an
  # already-running cluster on the default port, so only the first h2o task
  # of a GUI session pays the JVM start-up cost.  The GUI shuts the cluster
  # down via the `shutdown_h2o` task when it exits.
  if (identical(p_chr("backend"), "h2o")) {
    nm_init_h2o(n_cores = p_num("n_cores"), max_mem_size = p_chr("max_mem_size"), verbose = TRUE)
  }
}

load_session_model <- function() {
  ensure_h2o()
  nm_load_model(
    path = session, filename = "model",
    backend = p_chr("backend", "lightgbm"), verbose = FALSE
  )
}

model_config_from_params <- function(backend) {
  if (backend == "lightgbm") {
    trials <- p_num("n_trials")
    if (!is.null(trials)) list(n_trials = as.integer(trials)) else NULL
  } else if (startsWith(backend, "h2o")) {
    cfg <- list()
    secs <- p_num("max_runtime_secs")
    if (!is.null(secs)) cfg$max_runtime_secs <- as.integer(secs)
    algos <- p_list("include_algos")
    if (!is.null(algos)) cfg$include_algos <- algos
    if (length(cfg)) cfg else NULL
  } else {
    NULL
  }
}

scm_design <- function() {
  list(
    date_col = p_chr("date_col", "date"),
    unit_col = p_chr("unit_col", "ID"),
    outcome_col = p_chr("outcome_col"),
    treated_unit = p_chr("treated_unit"),
    donors = p_list("donors"),
    cutoff_date = p_chr("cutoff_date"),
    scm_backend = p_chr("scm_backend", "scm")
  )
}

# effect paths: named list of data.frames indexed by date with an `effect`
# column -> one long CSV (unit, date, effect).
write_effect_paths <- function(paths, name) {
  if (is.null(paths) || length(paths) == 0) {
    write_csv_at(data.frame(unit = character(0), date = character(0), effect = numeric(0)), name)
    return(invisible())
  }
  rows <- lapply(names(paths), function(u) {
    d <- as.data.frame(paths[[u]])
    if (!"date" %in% names(d)) d$date <- rownames(paths[[u]])
    data.frame(unit = u, date = d$date, effect = d$effect)
  })
  write_csv_at(do.call(rbind, rows), name)
}

synth_to_df <- function(synth) {
  d <- as.data.frame(synth)
  if (!"date" %in% names(d)) {
    d <- cbind(date = rownames(as.data.frame(synth)), d)
  }
  d
}

if (task == "check") {
  cat(sprintf(
    "normet %s | lightgbm %s | h2o %s\n",
    as.character(utils::packageVersion("normet")),
    if (requireNamespace("lightgbm", quietly = TRUE)) "yes" else "no",
    if (requireNamespace("h2o", quietly = TRUE)) "yes" else "no"
  ))

} else if (task == "shutdown_h2o") {
  if (requireNamespace("h2o", quietly = TRUE)) {
    up <- tryCatch({ h2o::h2o.init(startH2O = FALSE); TRUE }, error = function(e) FALSE)
    if (up) try(h2o::h2o.shutdown(prompt = FALSE), silent = TRUE)
  }

} else if (task == "train") {
  df <- read_input()
  covariates <- p_list("covariates")
  all_covariates <- c(covariates, TIME_VARS)
  backend <- p_chr("backend", "lightgbm")
  ensure_h2o()

  build <- nm_build_model(
    df,
    target = p_chr("target"),
    backend = backend,
    covariates = all_covariates,
    split_method = p_chr("split_method", "random"),
    train_fraction = p_num("train_fraction", 0.75),
    model_config = model_config_from_params(backend),
    seed = p_num("seed", 7654321),
    verbose = TRUE
  )

  nm_save_model(build$model, path = session, filename = "model", verbose = FALSE)

  df_prep <- as.data.frame(build$df_prep)
  # Per-row predictions enable the parity plot without another R roundtrip.
  df_prep$value_predict <- as.numeric(nm_predict(build$model, df_prep))
  write_csv_at(df_prep, "df_prep.csv")

  splits <- if ("set" %in% names(df_prep)) unique(df_prep$set) else character(0)
  stats <- do.call(rbind, lapply(c(as.list(splits), list(NULL)), function(s) {
    sub <- if (is.null(s)) df_prep else df_prep[df_prep$set == s, ]
    out <- nm_Stats(sub)
    out$set <- if (is.null(s)) "all" else s
    out
  }))
  write_csv_at(stats, "stats.csv")

  # nm_feature_importance only implements the H2O branch; go straight to
  # lgb.importance for LightGBM boosters.
  imp <- tryCatch({
    if (backend == "lightgbm") {
      as.data.frame(lightgbm::lgb.importance(build$model))[, c("Feature", "Gain")]
    } else {
      as.data.frame(nm_feature_importance(build$model))
    }
  }, error = function(e) NULL)
  if (!is.null(imp) && nrow(imp) > 0) {
    write_csv_at(imp, "importance.csv")
  }

} else if (task == "normalise") {
  df <- read_prepared()
  args <- list(
    df = df,
    model = load_session_model(),
    resample_vars = p_list("resample_vars"),
    n_samples = p_num("n_samples", 300),
    n_cores = p_num("n_cores"),
    seed = p_num("seed", 7654321),
    verbose = TRUE
  )
  q <- p_numlist("return_quantiles")
  if (!is.null(q)) args$return_quantiles <- q
  result <- do.call(nm_normalise, args)
  write_result(result)

} else if (task == "decompose") {
  df <- read_prepared()
  result <- nm_decompose(
    method = p_chr("method", "emission"),
    df = df,
    model = load_session_model(),
    target = "value",
    covariates = c(p_list("covariates"), TIME_VARS),
    backend = p_chr("backend", "lightgbm"),
    n_samples = p_num("n_samples", 300),
    seed = p_num("seed", 7654321),
    verbose = TRUE
  )
  write_result(result)

} else if (task == "pdp") {
  df <- read_prepared()
  result <- nm_pdp(
    df, load_session_model(),
    var_list = p_list("var_list"),
    verbose = TRUE
  )
  write_result(result)

} else if (task == "rolling") {
  df <- read_prepared()
  result <- nm_rolling(
    df,
    model = load_session_model(),
    target = "value",
    covariates = c(p_list("covariates"), TIME_VARS),
    resample_vars = p_list("resample_vars"),
    backend = p_chr("backend", "lightgbm"),
    n_samples = p_num("n_samples", 100),
    window_days = p_num("window_days", 14),
    rolling_every = p_num("rolling_every", 7),
    seed = p_num("seed", 7654321),
    verbose = TRUE
  )
  write_result(result)

} else if (task == "scm_fit") {
  d <- scm_design()
  df <- read_input()
  backend <- d$scm_backend
  weights <- NULL

  if (backend == "scm") {
    out <- nm_scm(
      df = df, date_col = d$date_col, unit_col = d$unit_col,
      outcome_col = d$outcome_col, treated_unit = d$treated_unit,
      cutoff_date = d$cutoff_date, donors = setdiff(d$donors, d$treated_unit),
      verbose = TRUE
    )
    if (is.list(out) && "synthetic" %in% names(out)) {
      synth <- out$synthetic
      w <- out$weights
      if (!is.null(w)) {
        weights <- data.frame(unit = names(w), weight = as.numeric(w))
      }
    } else {
      synth <- out
    }
  } else {
    synth <- nm_run_scm(
      df = df, date_col = d$date_col, unit_col = d$unit_col,
      outcome_col = d$outcome_col, treated_unit = d$treated_unit,
      cutoff_date = d$cutoff_date, donors = d$donors,
      scm_backend = backend,
      model_config = model_config_from_params(p_chr("backend", "lightgbm")),
      verbose = TRUE
    )
  }

  synth_df <- synth_to_df(synth)
  write_result(synth_df)
  if (!is.null(weights)) write_csv_at(weights, "weights.csv")

  diag <- tryCatch(
    nm_scm_diagnostics(if (is.null(weights)) synth_df else
      list(synthetic = synth_df, weights = stats::setNames(weights$weight, weights$unit)),
      cutoff_date = d$cutoff_date),
    error = function(e) NULL
  )
  meta <- list()
  if (!is.null(diag)) {
    for (k in names(diag)) {
      v <- diag[[k]]
      if (is.numeric(v) && length(v) == 1) meta[[k]] <- v
    }
    td <- diag$top_donors
    if (!is.null(td) && length(td) > 0) {
      if (is.list(td) && !is.null(names(td[[1]]))) {
        # list of (name, weight) pairs
        meta$top_donors <- paste(
          vapply(td, function(x) paste0(x[[1]], ":", x[[2]]), character(1)), collapse = ";"
        )
      } else if (!is.null(names(td))) {
        meta$top_donors <- paste(paste0(names(td), ":", as.numeric(td)), collapse = ";")
      }
    }
  }
  write_meta(meta)

} else if (task == "placebo_space") {
  d <- scm_design()
  df <- read_input()
  out <- nm_placebo_in_space(
    df, date_col = d$date_col, unit_col = d$unit_col, outcome_col = d$outcome_col,
    treated_unit = d$treated_unit, cutoff_date = d$cutoff_date, donors = d$donors,
    scm_backend = d$scm_backend, verbose = TRUE
  )
  write_csv_at(synth_to_df(out$treated), "treated.csv")
  write_effect_paths(out$placebos, "placebos.csv")
  bands <- nm_effect_bands_space(out, level = 0.95, method = "quantile", verbose = FALSE)
  write_csv_at(synth_to_df(bands), "bands.csv")
  write_meta(list(p_value = out$p_value, n_placebos = length(out$placebos)))

} else if (task == "placebo_time") {
  d <- scm_design()
  df <- read_input()
  out <- nm_placebo_in_time(
    df, date_col = d$date_col, unit_col = d$unit_col, outcome_col = d$outcome_col,
    treated_unit = d$treated_unit, cutoff_date = d$cutoff_date, donors = d$donors,
    scm_backend = d$scm_backend,
    min_pre_period = p_num("min_pre_period", 30),
    placebo_every = p_num("placebo_every", 7),
    verbose = TRUE
  )
  write_csv_at(synth_to_df(out$treated), "treated.csv")
  n_plc <- length(out$placebos)
  if (n_plc > 0) {
    bd <- nm_effect_bands_time(out, level = 0.95, method = "quantile", return_segments = TRUE)
    bands <- as.data.frame(bd$bands)
    bands$step <- seq_len(nrow(bands)) - 1
    write_csv_at(bands, "bands.csv")
    if (!is.null(bd$segments)) {
      seg <- as.data.frame(bd$segments)
      seg$step <- seq_len(nrow(seg)) - 1
      write_csv_at(seg, "segments.csv")
    }
  }
  write_meta(list(p_value = out$p_value, n_placebos = n_plc))

} else if (task == "uncertainty") {
  d <- scm_design()
  df <- read_input()
  out <- nm_uncertainty_bands(
    df, date_col = d$date_col, unit_col = d$unit_col, outcome_col = d$outcome_col,
    treated_unit = d$treated_unit, cutoff_date = d$cutoff_date, donors = d$donors,
    scm_backend = d$scm_backend,
    method = p_chr("method", "jackknife"),
    B = p_num("B", 100),
    seed = p_num("seed", 7654321),
    verbose = TRUE
  )
  if (is.null(out$low)) {
    write_meta(list(ok = 0))
  } else {
    tr <- synth_to_df(out$treated)
    export <- data.frame(
      date = tr$date, effect = tr$effect,
      low = as.numeric(out$low), high = as.numeric(out$high)
    )
    write_result(export)
    write_meta(list(ok = 1))
  }

} else if (task == "scm_all") {
  d <- scm_design()
  df <- read_input()
  result <- nm_scm_all(
    df, date_col = d$date_col, unit_col = d$unit_col, outcome_col = d$outcome_col,
    donors = NULL, cutoff_date = d$cutoff_date, scm_backend = d$scm_backend,
    verbose = TRUE
  )
  write_result(result)

} else if (task == "find_stations") {
  pollutants <- p_list("pollutants")
  frames <- lapply(pollutants, function(pol) {
    st <- nm_list_aurn_stations(pollutant = pol)
    if (nrow(st) == 0) return(NULL)
    st$pollutant <- pol
    st
  })
  frames <- Filter(Negate(is.null), frames)
  if (length(frames) == 0) {
    write_result(data.frame())
  } else {
    out <- do.call(rbind, frames)
    # Attach official AURN site codes (MY1, MAN3, ...) from DEFRA's metadata
    # (the same file openair's importMeta uses).  Match by site name, fall
    # back to nearest coordinates; leave NA when neither matches.
    out$code <- NA_character_
    meta <- tryCatch({
      cache <- file.path(session, "aurn_metadata.rds")
      if (file.exists(cache)) {
        readRDS(cache)
      } else {
        con <- url("https://uk-air.defra.gov.uk/openair/R_data/AURN_metadata.RData")
        load(con); close(con)
        m <- unique(AURN_metadata[, c("site_id", "site_name", "latitude", "longitude")])
        saveRDS(m, cache)
        m
      }
    }, error = function(e) { message("AURN metadata unavailable: ", conditionMessage(e)); NULL })
    if (!is.null(meta)) {
      site_names <- sub("-[^-]*$", "", out$label)  # strip '-Pollutant (air)' suffix
      idx <- match(tolower(trimws(site_names)), tolower(trimws(meta$site_name)))
      out$code <- meta$site_id[idx]
      unmatched <- which(is.na(out$code) & !is.na(out$lat) & !is.na(out$lon))
      for (i in unmatched) {
        d2 <- (meta$latitude - out$lat[i])^2 + (meta$longitude - out$lon[i])^2
        j <- which.min(d2)
        if (length(j) == 1 && d2[j] < 0.02^2) out$code[i] <- meta$site_id[j]
      }
    }
    write_result(out)
  }

} else if (task == "fetch_merge") {
  pollutants <- p_list("pollutants")
  station_id <- p_chr("station_id")
  site_name <- p_chr("site_name", "site")
  lat <- p_num("lat")
  lon <- p_num("lon")
  date_from <- p_chr("date_from")
  date_to <- p_chr("date_to")
  met <- p_chr("met_source", "none")

  frames <- list()
  for (pol in pollutants) {
    aq <- tryCatch(
      nm_fetch_aurn_measurements(
        station = station_id, pollutant = pol,
        date_from = date_from, date_to = date_to
      ),
      error = function(e) { message(sprintf("%s: %s", pol, conditionMessage(e))); NULL }
    )
    if (is.null(aq) || nrow(aq) == 0) next
    aq <- aq[aq$value > -50, ]  # UK-AIR missing-value sentinels
    agg <- stats::aggregate(value ~ date, data = aq, FUN = mean)
    names(agg)[2] <- pol
    frames[[pol]] <- agg
  }
  if (length(frames) == 0) stop("No air-quality data came back for this site/date range.")
  merged <- Reduce(function(a, b) merge(a, b, by = "date", all = TRUE), frames)

  if (met %in% c("openmeteo", "cds")) {
    sites <- data.frame(site = site_name, lat = lat, lon = lon)
    met_df <- if (met == "openmeteo") {
      nm_fetch_openmeteo_timeseries(sites, date_from = date_from, date_to = date_to)
    } else {
      nm_fetch_era5_timeseries(sites, date_from = date_from, date_to = date_to)
    }
    met_df$site <- NULL; met_df$lat <- NULL; met_df$lon <- NULL
    merged <- merge(merged, met_df, by = "date", all.x = TRUE)
  }
  merged <- merged[order(merged$date), ]
  merged$site <- site_name
  merged$lat <- lat
  merged$lon <- lon
  write_result(merged)

} else if (task == "traj_build") {
  tdumps <- p_list("tdumps")
  result <- nm_build_trajectory_features(
    tdumps,
    source_regions = p_all_regions(),
    prefix = p_chr("prefix", "traj_")
  )
  site <- p_chr("site")
  if (!is.null(site) && nzchar(site)) result <- cbind(site = site, result)
  write_result(result)

} else if (task == "gdas_fetch") {
  paths <- nm_fetch_gdas1(
    date_from = p_chr("date_from"),
    date_to = p_chr("date_to"),
    cache_dir = p_chr("cache_dir"),
    on_missing = p_chr("on_missing", "warn")
  )
  write_csv_at(data.frame(path = paths), "gdas_paths.csv")

} else if (task == "traj_run") {
  times <- as.POSIXct(readLines(file.path(session, "receptor_times.txt")), tz = "UTC")
  traj_args <- list(
    times = times,
    lat = p_num("lat"),
    lon = p_num("lon"),
    met_files = p_list("met_files"),
    hysplit_exec = p_chr("hysplit_exec"),
    height_m = p_num("height_m", 500),
    hours_back = p_num("hours_back", 72),
    source_regions = p_all_regions(),
    prefix = p_chr("prefix", "traj_")
  )
  diag <- p_diagnostics("diagnostics")
  if (!is.null(diag)) traj_args$diagnostics <- diag
  result <- do.call(nm_run_back_trajectories, traj_args)
  write_result(result)

} else {
  stop(sprintf("unknown task '%s'", task))
}

cat("BRIDGE_OK\n")
