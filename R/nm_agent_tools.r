# The tools an assistant drives normet with
#
# Ported from Python normet agent/tools.py. Each returns text -- normet's own
# readings (nm_agent_readings.r) -- or, for a figure, its caption and a PNG. A
# job's tool writes an R script and starts it (nm_agent_jobs.r), returning at
# once; its status is asked for after, and once it has ended its status carries
# the readings of what it wrote. nm_mcp_server() serves them over MCP; the R GUI's
# Assistant calls them through nm_agent_tool().
#
# Files are read and written only under the folders allowed: $NORMET_MCP_ROOTS
# (folders separated as PATH separates them), the user's home folder where it is
# not set, and the jobs' own folder.

NULL

#' The examples normet ships, by the name a tool takes them by: the data set and
#' what it is.
#' @noRd
.NM_AGENT_EXAMPLES <- list(
  my1 = c("my1", paste0(
    "Hourly NO2 and meteorology at London Marylebone Road (MY1), Jan\u2013Aug 2020: ",
    "a single site, for do-all, decompose and cv (target NO2)."
  )),
  my1_pm25 = c("my1_pm25", "Hourly PM2.5 and meteorology at MY1, Jan\u2013Aug 2020 (target pm25)."),
  scm = c("scm", paste0(
    "Monthly de-weathered NO2 at 104 UK sites, 2016\u20132021 (unit column 'code', ",
    "outcomes NO2_obs / NO2_dw): a panel for synthetic control, e.g. the ULEZ at MY1."
  ))
)

#' The figures a tool draws: kind -> what it shows and what it is drawn from.
#' @noRd
.NM_AGENT_FIGURES <- c(
  normalised = "observed and normalised series, daily means (a run or a normalised CSV)",
  model = "observed against predicted on the held-out rows (a run)",
  importance = "the model's feature importance (a run)",
  decomposition = "each component of a decomposition over time (a decomposition CSV)",
  scm = "the treated unit against its synthetic control (an SCM CSV; cutoff marks the date)"
)

#' What each job writes, read back once it has ended.
#' @noRd
.NM_AGENT_OUTPUTS <- c(do_all = "normalised.csv", decompose = "decomposition.csv",
                       scm = "scm.csv", cv = "cv.csv")

.nm_cut <- function(text, limit = 4000) {
  if (nchar(text) <= limit) text else paste0("\u2026", substr(text, nchar(text) - limit + 1, nchar(text)))
}

#' normet's tools over one job store and one set of allowed folders.
#' @noRd
.nm_agent <- function(home = NULL, roots = NULL) {
  store <- .nm_job_store(home)
  if (is.null(roots)) {
    env <- Sys.getenv("NORMET_MCP_ROOTS", "")
    roots <- Filter(nzchar, strsplit(env, .Platform$path.sep, fixed = TRUE)[[1]])
    if (!length(roots)) roots <- "~"
  }
  roots <- normalizePath(path.expand(roots), winslash = "/", mustWork = FALSE)
  structure(list(store = store, roots = roots), class = "nm_agent")
}

.nm_agent_allowed <- function(agent, path) {
  real <- normalizePath(path, winslash = "/", mustWork = FALSE)
  for (root in c(agent$roots, normalizePath(agent$store$home, winslash = "/", mustWork = FALSE))) {
    root <- sub("/+$", "", root)
    if (real == root || startsWith(real, paste0(root, "/"))) return(TRUE)
  }
  FALSE
}

#' `given` as an absolute path inside the allowed folders, or an error saying so.
#' @noRd
.nm_agent_path <- function(agent, given, must_exist = TRUE) {
  p <- path.expand(as.character(given))
  # A file not yet written is found by its folder (a link in it resolved, as /var on macOS).
  p <- if (file.exists(p)) normalizePath(p, winslash = "/") else
    file.path(normalizePath(dirname(p), winslash = "/", mustWork = FALSE), basename(p))
  if (!.nm_agent_allowed(agent, p)) {
    stop(sprintf("%s is outside the folders normet may use (%s); set NORMET_MCP_ROOTS to allow another",
                 p, paste(agent$roots, collapse = .Platform$path.sep)), call. = FALSE)
  }
  if (must_exist && !file.exists(p)) stop(sprintf("no file %s", p), call. = FALSE)
  p
}

.nm_agent_list_examples <- function(agent) {
  paste(vapply(names(.NM_AGENT_EXAMPLES), function(n) paste0(n, ": ", .NM_AGENT_EXAMPLES[[n]][2]), ""),
        collapse = "\n")
}

#' An example written as a CSV in the store's folder (once), its path.
#' @noRd
.nm_agent_example_path <- function(agent, name) {
  if (!name %in% names(.NM_AGENT_EXAMPLES)) {
    stop(sprintf("no example '%s'; the examples are %s", name,
                 paste(names(.NM_AGENT_EXAMPLES), collapse = ", ")), call. = FALSE)
  }
  folder <- file.path(agent$store$home, "examples")
  dir.create(folder, recursive = TRUE, showWarnings = FALSE)
  path <- file.path(folder, paste0(name, ".csv"))
  if (!file.exists(path)) {
    env <- new.env()
    utils::data(list = .NM_AGENT_EXAMPLES[[name]][1], package = "normet", envir = env)
    data.table::fwrite(get(.NM_AGENT_EXAMPLES[[name]][1], envir = env), paste0(path, ".part"))
    file.rename(paste0(path, ".part"), path)
  }
  path
}

.nm_agent_source <- function(agent, data = NULL, example = NULL) {
  if (is.null(data) == is.null(example)) {
    stop("give one of data=<path of a table> or example=<name>", call. = FALSE)
  }
  if (!is.null(example)) .nm_agent_example_path(agent, example) else .nm_agent_path(agent, data)
}

#' A table as normet reads one: its dates read where it has a date column.
#' @noRd
.nm_agent_table <- function(path) {
  df <- as.data.frame(nm_read_table(path))
  if ("date" %in% names(df)) {
    tryCatch(df <- as.data.frame(nm_read_time_series(path)), error = function(e) NULL)
  }
  df
}

# -- the data -----------------------------------------------------------------------

.nm_agent_inspect_data <- function(agent, data = NULL, example = NULL, target = NULL) {
  path <- .nm_agent_source(agent, data, example)
  .nm_data_reading(.nm_agent_table(path), target, name = basename(path))
}

# -- jobs ---------------------------------------------------------------------------

#' A value as R writes it in a script.
#' @noRd
.nm_r_literal <- function(x) {
  if (is.null(x)) return("NULL")
  if (is.list(x)) x <- unlist(x)
  if (is.numeric(x)) x <- as.numeric(x)  # 5, not 5L
  paste(deparse(x, width.cutoff = 500L), collapse = "")
}

#' `target <- fn(args...)`, its arguments wrapped under the bracket at 88 columns.
#' @noRd
.nm_r_call <- function(target, fn, positional = character(), named = list()) {
  named <- named[!vapply(named, is.null, TRUE)]
  parts <- c(positional, vapply(names(named), function(k) paste(k, "=", .nm_r_literal(named[[k]])), ""))
  head <- paste0(target, " <- ", fn, "(")
  indent <- strrep(" ", nchar(head))
  lines <- character()
  line <- head
  for (i in seq_along(parts)) {
    piece <- paste0(parts[i], if (i < length(parts)) "," else ")")
    fresh <- line == head || line == indent
    if (!fresh && nchar(line) + 1 + nchar(piece) > 88) {
      lines <- c(lines, line)
      line <- paste0(indent, piece)
    } else {
      line <- paste0(line, if (fresh) "" else " ", piece)
    }
  }
  if (!length(parts)) line <- paste0(line, ")")
  paste(c(lines, line), collapse = "\n")
}

#' A list of names, as a tool may be given one: a JSON array, or one string of
#' names separated by commas.
#' @noRd
.nm_names <- function(x) {
  if (is.null(x)) return(NULL)
  x <- as.character(unlist(x))
  if (length(x) == 1) x <- trimws(strsplit(x, ",", fixed = TRUE)[[1]])
  x <- x[nzchar(x)]
  if (length(x)) x else NULL
}

.nm_agent_start <- function(agent, kind, code, label) {
  job <- .nm_job_submit(agent$store, kind, code, label = label %||% "")
  paste0(
    sprintf("Started job %s (%s): %s", job$id, kind, job$state),
    if (isTRUE(job$ahead > 0)) sprintf(", %d ahead of it", job$ahead) else "",
    sprintf(".\nCommand (run from %s): %s\nAsk normet_job_status for how it goes.", job$folder, job$command)
  )
}

.nm_read_line <- function(path) {
  sprintf("df <- nm_read_time_series(%s)", .nm_r_literal(path))
}

.nm_agent_start_do_all <- function(agent, target, covariates, data = NULL, example = NULL,
                                   resample_vars = NULL, backend = NULL, n_samples = NULL,
                                   split_method = NULL, train_fraction = NULL, seed = NULL,
                                   label = "") {
  covariates <- .nm_names(covariates)
  if (is.null(covariates)) stop("give the covariates (predictor columns) to train on", call. = FALSE)
  src <- .nm_agent_source(agent, data, example)
  covs <- union(covariates, .NM_TIME_FEATURES)
  config <- list(target = target, covariates = covs, resample_vars = .nm_names(resample_vars) %||% covariates,
                 backend = backend %||% "lightgbm", n_samples = n_samples, split_method = split_method,
                 train_fraction = train_fraction, seed = seed)
  code <- c(
    "# Train a model and normalise it: the time features are added to the covariates,",
    "# the meteorology alone resampled. The settings once: the call reads them, the run",
    "# keeps them.",
    .nm_read_line(src),
    .nm_r_call("config", "list", character(), config),
    "res <- do.call(nm_do_all, c(list(df), config))",
    "data.table::fwrite(res$res, \"normalised.csv\")",
    "",
    "# The run: its result and the data it was trained on, the model saved beside it.",
    "nm_save_model(res$model, path = \"run_model\", filename = \"model\", verbose = FALSE)",
    "run <- nm_make_run(res$res, kind = \"do_all\", config = config, df = df, df_prep = res$df_prep)",
    "nm_save_run(run, \"run\")"
  )
  .nm_agent_start(agent, "do_all", code, label)
}

.nm_agent_start_decompose <- function(agent, target, covariates, method = "emission", data = NULL,
                                      example = NULL, backend = NULL, n_samples = NULL, seed = NULL,
                                      label = "") {
  method <- method %||% "emission"
  if (!method %in% c("emission", "meteorology")) stop("method is 'emission' or 'meteorology'", call. = FALSE)
  covariates <- .nm_names(covariates)
  if (is.null(covariates)) stop("give the covariates (predictor columns) to train on", call. = FALSE)
  src <- .nm_agent_source(agent, data, example)
  code <- c(
    "# Decompose: the time features are added to the covariates.",
    .nm_read_line(src),
    .nm_r_call("dec", "nm_decompose", "df = df", list(
      method = method, target = target, covariates = union(covariates, .NM_TIME_FEATURES),
      backend = backend %||% "lightgbm", n_samples = n_samples, seed = seed
    )),
    "data.table::fwrite(dec, \"decomposition.csv\")"
  )
  .nm_agent_start(agent, "decompose", code, label)
}

.nm_agent_start_scm <- function(agent, treated, cutoff, data = NULL, example = NULL, donors = NULL,
                                date_col = NULL, unit_col = NULL, outcome_col = NULL, backend = NULL,
                                label = "") {
  src <- .nm_agent_source(agent, data, example)
  code <- c(
    "# A synthetic control of the treated unit, its effect after the cutoff.",
    .nm_read_line(src),
    .nm_r_call("sc", "nm_run_scm", "df", list(
      date_col = date_col %||% "date", unit_col = unit_col %||% "ID", outcome_col = outcome_col %||% "value",
      treated_unit = treated, cutoff_date = as.character(cutoff), donors = .nm_names(donors),
      scm_backend = backend %||% "scm"
    )),
    "data.table::fwrite(sc, \"scm.csv\")"
  )
  .nm_agent_start(agent, "scm", code, label)
}

.nm_agent_start_cv <- function(agent, target, covariates, data = NULL, example = NULL, n_splits = NULL,
                               gap = NULL, backend = NULL, label = "") {
  covariates <- .nm_names(covariates)
  if (is.null(covariates)) stop("give the covariates (predictor columns) to train on", call. = FALSE)
  src <- .nm_agent_source(agent, data, example)
  code <- c(
    "# Time-series cross-validation: trained on the past, scored on the next block.",
    .nm_read_line(src),
    .nm_r_call("cv", "nm_cv_score", "df", list(
      target = target, covariates = union(covariates, .NM_TIME_FEATURES),
      backend = backend %||% "lightgbm", n_splits = n_splits, gap = gap
    )),
    "data.table::fwrite(cv, \"cv.csv\")"
  )
  .nm_agent_start(agent, "cv", code, label)
}

.nm_agent_cutoff_of <- function(job) {
  script <- file.path(job$folder, "job.R")
  if (!file.exists(script)) return(NULL)
  text <- paste(readLines(script, warn = FALSE), collapse = "\n")
  m <- regmatches(text, regexpr("cutoff_date = \"[^\"]+\"", text))
  if (length(m)) sub("cutoff_date = \"([^\"]+)\"", "\\1", m) else NULL
}

.nm_agent_readings_of <- function(agent, job) {
  folder <- job$folder
  kind <- job$kind
  if (kind == "do_all" && file.exists(file.path(folder, "run.rds"))) {
    return(.nm_agent_read_run(agent, file.path(folder, "run.rds")))
  }
  out <- file.path(folder, .NM_AGENT_OUTPUTS[[kind]] %||% "")
  if (!file.exists(out) || dir.exists(out)) return("")
  .nm_agent_read_result(agent, out, kind, cutoff = .nm_agent_cutoff_of(job))
}

.nm_agent_job_status <- function(agent, job_id) {
  store <- agent$store
  .nm_job_pump(store)
  job <- .nm_job_status(store, job_id)
  lines <- c(
    paste0(
      sprintf("Job %s (%s%s): %s", job$id, job$kind,
              if (nzchar(job$label %||% "")) paste0(", ", job$label) else "", job$state),
      if (!is.null(job$elapsed_s)) sprintf(" after %s s", job$elapsed_s) else "",
      if (isTRUE(job$ahead > 0)) sprintf(", %d ahead of it", job$ahead) else "",
      "."
    ),
    sprintf("Command (run from %s): %s", job$folder, job$command)
  )
  if (job$state == "failed") {
    err <- trimws(.nm_job_text(store, job_id, "stderr.txt", tail = 3000))
    out <- trimws(.nm_job_text(store, job_id, "stdout.txt", tail = 1500))
    said <- if (nzchar(err)) err else if (nzchar(out)) out else "(nothing printed)"
    lines <- c(lines, "", "It failed. Its last output:", .nm_cut(said))
  } else if (job$state == "done") {
    lines <- c(lines, "", "Files:", paste0("  ", unlist(job$files)))
    said <- tryCatch(.nm_agent_readings_of(agent, job), error = function(e) {
      sprintf("(could not read its output: %s)", conditionMessage(e))
    })
    if (nzchar(said)) lines <- c(lines, "", said)
  } else if (job$state == "running") {
    tail <- trimws(.nm_job_text(store, job_id, "stderr.txt", tail = 600))
    if (nzchar(tail)) lines <- c(lines, "", "Latest log lines:", tail)
  }
  paste(lines, collapse = "\n")
}

.nm_agent_cancel_job <- function(agent, job_id) {
  job <- .nm_job_cancel(agent$store, job_id)
  sprintf("Job %s: %s.", job$id, job$state)
}

.nm_agent_list_jobs <- function(agent, limit = 20) {
  .nm_job_pump(agent$store)
  ids <- rev(.nm_job_ids(agent$store))
  ids <- utils::head(ids, max(1, as.integer(limit %||% 20)))
  if (!length(ids)) return("No jobs yet.")
  rows <- lapply(ids, function(id) {
    job <- .nm_job_status(agent$store, id)
    list(id, job$kind, job$state, if (nzchar(job$label %||% "")) job$label else substr(job$command, 1, 60))
  })
  .nm_text_table(c("id", "kind", "state", "label / command"), rows)
}

# -- results ------------------------------------------------------------------------

#' A saved do-all run (`run.rds`), with its model put back from the folder saved
#' beside it (`run_model/`).
#' @noRd
.nm_agent_run <- function(agent, run) {
  p <- .nm_agent_path(agent, if (grepl("\\.rds$", run)) run else paste0(run, ".rds"))
  r <- nm_load_run(p)
  model_dir <- paste0(sub("\\.rds$", "", p), "_model")
  if (dir.exists(model_dir)) {
    backend <- r$metadata$config$backend %||% "lightgbm"
    r$model <- nm_load_model(path = model_dir, filename = "model", backend = backend, verbose = FALSE)
  }
  r
}

.nm_agent_read_run <- function(agent, run) {
  r <- .nm_agent_run(agent, run)
  parts <- character()
  cfg <- r$metadata$config %||% list()
  said <- cfg[intersect(c("target", "covariates", "backend", "n_samples", "split_method"), names(cfg))]
  said <- said[!vapply(said, is.null, TRUE)]
  if (length(said)) parts <- c(parts, paste("Run:", jsonlite::toJSON(said, auto_unbox = TRUE)))
  if (!is.null(r$model) && !is.null(r$df_prep)) parts <- c(parts, .nm_model_reading(r$df_prep, r$model))
  if (is.data.frame(r$result)) parts <- c(parts, .nm_normalised_reading(r$result))
  paste(parts, collapse = "\n\n")
}

.nm_agent_read_result <- function(agent, path, kind, cutoff = NULL) {
  df <- .nm_agent_table(.nm_agent_path(agent, path))
  if (kind %in% c("normalised", "do_all")) return(.nm_normalised_reading(df))
  if (kind %in% c("decomposition", "decompose")) return(.nm_decomposition_reading(df))
  if (kind == "scm") {
    if (is.null(cutoff) || !nzchar(cutoff)) {
      stop("an SCM result is read against its cutoff date: give cutoff=", call. = FALSE)
    }
    return(.nm_scm_reading(df, cutoff))
  }
  if (kind == "cv") return(.nm_cv_reading(df))
  stop("kind is normalised, decomposition, scm or cv", call. = FALSE)
}

#' One of the figures in .NM_AGENT_FIGURES: its caption and the PNG's bytes.
#' @noRd
.nm_agent_figure <- function(agent, source, kind, cutoff = NULL, dpi = 100) {
  if (!kind %in% names(.NM_AGENT_FIGURES)) {
    stop(sprintf("kind is one of %s", paste(names(.NM_AGENT_FIGURES), collapse = ", ")), call. = FALSE)
  }
  from_run <- kind %in% c("model", "importance") || grepl("\\.rds$", source)
  if (from_run) {
    drawn <- .nm_draw_run(.nm_agent_run(agent, source), kind)
  } else {
    drawn <- .nm_draw_table(.nm_agent_table(.nm_agent_path(agent, source)), kind, cutoff)
  }
  png <- tempfile(fileext = ".png")
  on.exit(unlink(png), add = TRUE)
  ggplot2::ggsave(png, drawn$plot, width = drawn$width, height = drawn$height,
                  dpi = max(as.numeric(dpi %||% 100), 150), bg = "white")
  list(caption = drawn$caption, png = readBin(png, "raw", file.size(png)))
}

.nm_daily <- function(df, cols) {
  day <- as.Date(df$date)
  out <- stats::aggregate(df[cols], by = list(date = day), FUN = mean, na.rm = TRUE)
  out$date <- as.POSIXct(out$date)
  out
}

.nm_normalised_plot <- function(d) {
  long <- rbind(
    data.frame(date = d$date, value = d$observed, series = "observed"),
    data.frame(date = d$date, value = d$normalised, series = "normalised")
  )
  long$series <- factor(long$series, c("observed", "normalised"))
  ggplot2::ggplot(long, ggplot2::aes(.data$date, .data$value, colour = .data$series,
                                     linewidth = .data$series, alpha = .data$series)) +
    ggplot2::geom_line() +
    ggplot2::scale_colour_manual(values = c(observed = nm_colours[["observed"]],
                                            normalised = nm_colours[["modelled"]]), name = NULL) +
    ggplot2::scale_linewidth_manual(values = c(observed = .pt_lw(0.8), normalised = .pt_lw(1.2)),
                                    guide = "none") +
    ggplot2::scale_alpha_manual(values = c(observed = 0.6, normalised = 1), guide = "none") +
    ggplot2::scale_x_datetime(expand = c(0, 0)) +
    ggplot2::labs(x = NULL, y = NULL) +
    nm_theme_normet() +
    ggplot2::theme(legend.position = "top", legend.justification = "right")
}

.nm_draw_run <- function(run, kind) {
  if (kind == "normalised") {
    d <- .nm_daily(.nm_reading_dated(run$result), c("observed", "normalised"))
    return(list(plot = .nm_normalised_plot(d), width = 6.5, height = 3.2,
                caption = "Observed and meteorologically normalised series (daily means)."))
  }
  if (kind == "model") {
    test <- run$df_prep[run$df_prep$set == "testing", , drop = FALSE]
    if (!nrow(test)) test <- run$df_prep
    pred <- nm_predict(run$model, test)
    d <- data.frame(observed = test$value, predicted = as.numeric(pred))
    lim <- range(c(d$observed, d$predicted), na.rm = TRUE)
    plot <- ggplot2::ggplot(d, ggplot2::aes(.data$observed, .data$predicted)) +
      ggplot2::geom_point(size = 0.6, alpha = 0.35, colour = nm_colours[["observed"]], stroke = 0) +
      ggplot2::geom_abline(slope = 1, intercept = 0, colour = nm_colours[["ink"]],
                           linewidth = .pt_lw(0.7), linetype = "dashed") +
      ggplot2::coord_equal(xlim = lim, ylim = lim) +
      nm_theme_normet()
    return(list(plot = plot, width = 4.5, height = 4.2, caption = sprintf(
      "Observed against predicted on %s held-out rows; dashed: 1:1.", .nm_count(nrow(test)))))
  }
  if (kind == "importance") {
    fi <- tryCatch(nm_feature_importance(run$model), error = function(e) NULL)
    if (!is.data.frame(fi) || !nrow(fi)) stop("this run's model does not report feature importance", call. = FALSE)
    fi <- fi[order(-fi$relative_importance), , drop = FALSE][seq_len(min(15, nrow(fi))), ]
    fi$variable <- factor(fi$variable, rev(fi$variable))
    plot <- ggplot2::ggplot(fi, ggplot2::aes(.data$relative_importance, .data$variable)) +
      ggplot2::geom_col(fill = nm_colours[["component"]], width = 0.65) +
      ggplot2::labs(x = NULL, y = NULL) +
      nm_theme_normet() +
      ggplot2::theme(axis.ticks.y = ggplot2::element_blank())
    return(list(plot = plot, width = 6.5, height = 3.2, caption = "The model's feature importance (largest 15)."))
  }
  .nm_draw_table(run$result, kind, NULL)
}

.nm_draw_table <- function(df, kind, cutoff) {
  df <- .nm_reading_dated(df)
  if (kind == "normalised") {
    return(list(plot = .nm_normalised_plot(.nm_daily(df, c("observed", "normalised"))),
                width = 6.5, height = 3.2,
                caption = "Observed and meteorologically normalised series (daily means)."))
  }
  if (kind == "decomposition") {
    cols <- setdiff(names(df)[vapply(df, is.numeric, TRUE)], "date")
    long <- do.call(rbind, lapply(cols, function(c) data.frame(date = df$date, value = df[[c]], component = c)))
    long$component <- factor(long$component, cols)
    plot <- ggplot2::ggplot(long, ggplot2::aes(.data$date, .data$value)) +
      ggplot2::geom_line(linewidth = .pt_lw(0.6), colour = nm_colours[["component"]]) +
      ggplot2::facet_grid(component ~ ., scales = "free_y", switch = "y") +
      ggplot2::scale_x_datetime(expand = c(0, 0)) +
      ggplot2::labs(x = NULL, y = NULL) +
      nm_theme_normet() +
      ggplot2::theme(strip.placement = "outside")
    return(list(plot = plot, width = 8, height = 1.4 * max(length(cols), 1) + 0.6,
                caption = sprintf("The decomposition's %d components.", length(cols))))
  }
  if (kind == "scm") {
    long <- rbind(
      data.frame(date = df$date, value = df$observed, series = "treated (observed)"),
      data.frame(date = df$date, value = df$synthetic, series = "synthetic control")
    )
    long$series <- factor(long$series, c("treated (observed)", "synthetic control"))
    plot <- ggplot2::ggplot(long, ggplot2::aes(.data$date, .data$value, colour = .data$series,
                                               linetype = .data$series)) +
      ggplot2::geom_line(linewidth = .pt_lw(1.2), na.rm = TRUE) +
      ggplot2::scale_colour_manual(values = c(nm_colours[["observed"]], nm_colours[["modelled"]]), name = NULL) +
      ggplot2::scale_linetype_manual(values = c("solid", "dashed"), name = NULL) +
      ggplot2::labs(x = NULL, y = NULL) +
      nm_theme_normet() +
      ggplot2::theme(legend.position = "top", legend.justification = "left")
    if (!is.null(cutoff) && nzchar(cutoff)) {
      plot <- plot + ggplot2::geom_vline(xintercept = as.POSIXct(as.character(cutoff), tz = "UTC"),
                                         colour = nm_colours[["ink"]], linetype = "dotted",
                                         linewidth = .pt_lw(0.7))
    }
    return(list(plot = plot, width = 6.5, height = 3.2, caption = paste0(
      "The treated unit and its synthetic control",
      if (!is.null(cutoff) && nzchar(cutoff)) sprintf("; dotted: %s.", cutoff) else "."
    )))
  }
  stop(sprintf("a '%s' figure is drawn from a run (run.rds)", kind), call. = FALSE)
}

.nm_agent_write_report <- function(agent, run, out = NULL) {
  r <- .nm_agent_run(agent, run)
  base <- sub("\\.rds$", "", run)
  target <- .nm_agent_path(agent, out %||% paste0(base, "_report.html"), must_exist = FALSE)
  path <- nm_generate_html(r, target)
  sprintf("Wrote %s.", path %||% target)
}
