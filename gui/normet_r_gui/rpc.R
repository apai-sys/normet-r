# One call into the normet R package, for the GUI (normet_r_gui/_rpc.py).
#
#   Rscript rpc.R <request.json>
#
# The request names a function and its arguments; the response, written beside the
# request as <request>.out.json, holds its value. Values cross as JSON, with three
# kinds of their own:
#
#   {"__df__": "<file>.csv", "types": {...}, "levels": {...}}  a data.frame
#   {"__rds__": "<file>.rds", ...}                               any other R object,
#                                                                  kept in the store
#   {"__date__": "<ISO 8601>"}                                   a POSIXct scalar
#
# A data.frame's columns carry their types (double, integer, logical, character,
# datetime, date, factor), so a table reads back as it was written. A model, or any
# object JSON cannot hold, is saved as .rds in the store folder and handed back as a
# handle; passed again, it is read back. Functions are normet's exported ones, or the
# GUI's own helpers below (named .gui_*). An error is written as {"error": ...} and
# the process exits 1.

suppressPackageStartupMessages({
  library(normet)
})

.rpc_args <- commandArgs(trailingOnly = TRUE)
if (length(.rpc_args) < 1) stop("usage: Rscript rpc.R <request.json>")
.rpc_request_path <- .rpc_args[1]
.rpc_dir <- dirname(normalizePath(.rpc_request_path))
.rpc_counter <- 0L

.rpc_new_file <- function(prefix, ext) {
  .rpc_counter <<- .rpc_counter + 1L
  stamp <- sub("\\.json$", "", basename(.rpc_request_path))
  file.path(.rpc_dir, sprintf("%s_%s_%d.%s", stamp, prefix, .rpc_counter, ext))
}

# -- reading values -------------------------------------------------------------------

.rpc_read_df <- function(spec) {
  types <- spec$types %||% list()
  levels <- spec$levels %||% list()
  df <- utils::read.csv(spec[["__df__"]], stringsAsFactors = FALSE, check.names = FALSE,
                        na.strings = c("NA", ""), colClasses = "character",
                        encoding = "UTF-8")
  for (col in names(df)) {
    t <- types[[col]] %||% "character"
    v <- df[[col]]
    df[[col]] <- switch(t,
      double = as.numeric(v),
      integer = as.integer(v),
      logical = as.logical(v),
      datetime = as.POSIXct(v, format = "%Y-%m-%dT%H:%M:%OS", tz = "UTC"),
      date = as.Date(v),
      factor = factor(v, levels = unlist(levels[[col]] %||% sort(unique(v)))),
      v
    )
  }
  df
}

.rpc_decode <- function(x) {
  if (is.list(x)) {
    if (!is.null(x[["__df__"]])) return(.rpc_read_df(x))
    if (!is.null(x[["__model__"]])) {
      return(nm_load_model(path = x[["__model__"]], filename = "model",
                           backend = x[["backend"]], verbose = FALSE))
    }
    if (!is.null(x[["__rds__"]])) return(readRDS(x[["__rds__"]]))
    if (!is.null(x[["__date__"]])) {
      return(as.POSIXct(x[["__date__"]], format = "%Y-%m-%dT%H:%M:%OS", tz = "UTC"))
    }
    if (!is.null(x[["__list__"]])) return(lapply(x[["__list__"]], .rpc_decode))
    out <- lapply(x, .rpc_decode)
    return(out)
  }
  x
}

# -- writing values -------------------------------------------------------------------

.rpc_write_df <- function(df) {
  df <- as.data.frame(df, stringsAsFactors = FALSE, check.names = FALSE)
  types <- list()
  levels <- list()
  out <- df
  for (col in names(df)) {
    v <- df[[col]]
    if (inherits(v, "POSIXt")) {
      types[[col]] <- "datetime"
      out[[col]] <- format(as.POSIXct(v), "%Y-%m-%dT%H:%M:%OS6", tz = "UTC")
    } else if (inherits(v, "Date")) {
      types[[col]] <- "date"
      out[[col]] <- format(v, "%Y-%m-%d")
    } else if (is.factor(v)) {
      types[[col]] <- "factor"
      levels[[col]] <- as.list(levels(v))
      out[[col]] <- as.character(v)
    } else if (is.logical(v)) {
      types[[col]] <- "logical"
    } else if (is.integer(v)) {
      types[[col]] <- "integer"
    } else if (is.numeric(v)) {
      types[[col]] <- "double"
    } else {
      types[[col]] <- "character"
      out[[col]] <- as.character(v)
    }
  }
  path <- .rpc_new_file("df", "csv")
  data.table::fwrite(out, path, na = "NA", quote = TRUE)
  list(`__df__` = path, types = types, levels = levels, columns = as.list(names(df)),
       rownames = if (.row_names_info(df) > 0) as.list(rownames(df)) else NULL)
}

# What a handle says about the object it stands for: its class, and for a model the
# backend and the features it was trained on.
.rpc_object_info <- function(x) {
  info <- list(class = as.list(class(x)))
  backend <- tryCatch(attr(x, "backend"), error = function(e) NULL)
  if (!is.null(backend)) info$backend <- backend
  feats <- tryCatch(nm_extract_features(x), error = function(e) NULL)
  if (!is.null(feats) && is.character(feats)) info$features <- as.list(feats)
  info
}

.rpc_encode <- function(x) {
  if (is.null(x)) return(NULL)
  if (is.data.frame(x)) return(.rpc_write_df(x))
  if (inherits(x, "POSIXt")) {
    if (length(x) == 1) return(list(`__date__` = format(as.POSIXct(x), "%Y-%m-%dT%H:%M:%OS6", tz = "UTC")))
    return(list(`__dates__` = as.list(format(as.POSIXct(x), "%Y-%m-%dT%H:%M:%OS6", tz = "UTC"))))
  }
  if (inherits(x, "Date")) return(format(x, "%Y-%m-%d"))
  if (is.factor(x)) x <- as.character(x)
  if (is.atomic(x) && is.null(attr(x, "class"))) {
    if (!is.null(names(x)) && length(x) > 0) return(as.list(x))
    return(x)
  }
  if (is.list(x) && is.null(attr(x, "class")) || identical(class(x), "list")) {
    return(lapply(x, .rpc_encode))
  }
  backend <- tryCatch(attr(x, "backend"), error = function(e) NULL)
  if (is.character(backend) && length(backend) == 1 && (backend == "lightgbm" || startsWith(backend, "h2o"))) {
    # A model is saved as normet saves models (a booster's own format, or H2O's).
    dir <- .rpc_new_file("model", "d")
    dir.create(dir, recursive = TRUE, showWarnings = FALSE)
    nm_save_model(x, path = dir, filename = "model", verbose = FALSE)
    return(c(list(`__model__` = dir), .rpc_object_info(x)))
  }
  path <- .rpc_new_file("obj", "rds")
  saveRDS(x, path)
  c(list(`__rds__` = path), .rpc_object_info(x))
}

`%||%` <- function(a, b) if (is.null(a)) b else a

# -- the GUI's own helpers -------------------------------------------------------------

# The banner the window shows: normet's version and which backends load.
.gui_check <- function() {
  list(
    normet = as.character(utils::packageVersion("normet")),
    r = paste(R.version$major, R.version$minor, sep = "."),
    lightgbm = requireNamespace("lightgbm", quietly = TRUE),
    h2o = requireNamespace("h2o", quietly = TRUE)
  )
}

# The H2O cluster this window's calls started, shut down.
.gui_shutdown_h2o <- function() {
  if (requireNamespace("h2o", quietly = TRUE)) {
    try(nm_stop_h2o(), silent = TRUE)
  }
  TRUE
}

# A model's prediction, as a numeric vector.
.gui_predict <- function(model, newdata) {
  as.numeric(nm_predict(model, newdata))
}

# A model's feature importance as a data.frame (feature, importance).
.gui_importance <- function(model) {
  fi <- nm_feature_importance(model)
  as.data.frame(fi)
}

# One of normet's bundled tables.
.gui_dataset <- function(name) {
  stopifnot(name %in% c("my1", "my1_pm25", "scm", "traj_my1"))
  as.data.frame(get(name, envir = asNamespace("normet")))
}

# A folder of the files normet ships (inst/extdata): the sample tdumps are "traj".
.gui_extdata <- function(name) {
  stopifnot(name %in% c("traj"))
  system.file("extdata", name, package = "normet", mustWork = TRUE)
}

# The regions a vector file names.
.gui_region_names <- function(path) names(nm_load_source_regions(path))

# Source regions from the window: boxes as c(lon_min, lat_min, lon_max, lat_max), and
# regions from files as list(`__region_file__` = path, name = name), read here.
.gui_regions <- function(regions) {
  if (is.null(regions) || length(regions) == 0) return(NULL)
  files <- list()
  out <- lapply(regions, function(r) {
    if (is.list(r) && !is.null(r[["__region_file__"]])) {
      path <- r[["__region_file__"]]
      if (is.null(files[[path]])) files[[path]] <<- nm_load_source_regions(path)
      return(files[[path]][[r$name]])
    }
    as.numeric(unlist(r))
  })
  out
}

.gui_build_trajectory_features <- function(tdumps, regions = NULL, ...) {
  nm_build_trajectory_features(unlist(tdumps), source_regions = .gui_regions(regions), ...)
}

.gui_run_back_trajectories <- function(times, regions = NULL, ...) {
  if (is.list(times)) times <- do.call(c, times)
  nm_run_back_trajectories(times, source_regions = .gui_regions(regions), ...)
}

# -- a session script (File -> Load Session Script) -----------------------------------

# The normet calls a session script makes, read without running it: each one's
# arguments named as its function names them (match.call), a literal's value kept and
# anything else (a name: df, model) as NULL; the last call of each function. The
# rolling runs a multi-scale entry writes (rolled_<days> <- nm_rolling(...)) are kept
# apart, in order.
.gui_read_calls <- function(path) {
  literal <- function(e) {
    if (is.null(e) || (is.atomic(e) && length(e) <= 1)) return(TRUE)
    if (is.call(e) && is.symbol(e[[1]]) && as.character(e[[1]]) %in% c("c", "list", "-")) {
      return(all(vapply(as.list(e)[-1], literal, logical(1))))
    }
    FALSE
  }
  value <- function(e) if (literal(e)) eval(e, baseenv()) else NULL
  ns <- asNamespace("normet")
  calls <- list()
  multiscale <- list()
  visit <- function(e, target = NULL) {
    if (!is.call(e)) return(invisible())
    head <- e[[1]]
    if (is.symbol(head) && as.character(head) %in% c("<-", "=") && length(e) == 3) {
      return(visit(e[[3]], if (is.symbol(e[[2]])) as.character(e[[2]]) else NULL))
    }
    fn <- if (is.symbol(head)) {
      as.character(head)
    } else if (is.call(head) && identical(head[[1]], as.name("::"))) {
      as.character(head[[3]])
    } else {
      ""
    }
    if (startsWith(fn, "nm_") && exists(fn, envir = ns, inherits = FALSE)) {
      m <- tryCatch(match.call(get(fn, envir = ns), e), error = function(err) NULL)
      if (!is.null(m)) {
        args <- lapply(as.list(m)[-1], value)
        if (fn == "nm_rolling" && !is.null(target) && grepl("^rolled_[0-9]+$", target)) {
          multiscale[[length(multiscale) + 1]] <<- args
        } else {
          calls[[fn]] <<- args
        }
      }
    }
    for (a in as.list(e)[-1]) visit(a)
  }
  for (e in parse(path, keep.source = FALSE)) visit(e)
  list(calls = calls, multiscale = multiscale)
}

# A session script run in the folder it was saved in, workdir (so a CSV it reads by a
# relative path is found); what it made, by the names the command log gives them, and its
# multi-scale rolling runs by their names.
.gui_run_script <- function(path, workdir = dirname(path)) {
  path <- normalizePath(path)
  env <- new.env(parent = globalenv())
  old <- setwd(workdir)
  on.exit(setwd(old), add = TRUE)
  sys.source(path, envir = env, keep.source = FALSE)
  keep <- c("df", "df_prep", "model", "normalised", "decomposition", "rolled", "pd_values")
  made <- mget(intersect(keep, ls(env)), envir = env)
  rolled <- grep("^rolled_[0-9]+$", ls(env), value = TRUE)
  if (length(rolled)) made$multiscale <- mget(rolled, envir = env)
  made
}

# -- the call -------------------------------------------------------------------------

.rpc_response <- paste0(sub("\\.json$", "", .rpc_request_path), ".out.json")

.rpc_main <- function() {
  req <- jsonlite::fromJSON(.rpc_request_path, simplifyVector = TRUE,
                            simplifyDataFrame = FALSE, simplifyMatrix = FALSE)
  fn_name <- req$fn
  fn <- if (startsWith(fn_name, ".gui_")) {
    get(fn_name, mode = "function")
  } else {
    getExportedValue("normet", fn_name)
  }
  args <- lapply(req$args %||% list(), .rpc_decode)
  kwargs <- lapply(req$kwargs %||% list(), .rpc_decode)
  # The share of the call done, as the package's loops report it, on a line of its own
  # for the window's task clock (_rpc._forward); a package without the reports runs as is.
  listening <- get0(".nm_progress_listening", envir = asNamespace("normet"), inherits = FALSE)
  value <- if (is.null(listening)) {
    do.call(fn, c(args, kwargs))
  } else {
    last <- -1
    listening(function(share) {
      if (share - last >= 0.001) {
        last <<- share
        message(sprintf("NM_PROGRESS %.4f", share))
      }
    }, do.call(fn, c(args, kwargs)))
  }
  out <- list(value = .rpc_encode(value))
  writeLines(jsonlite::toJSON(out, auto_unbox = TRUE, null = "null", na = "null",
                              digits = NA, POSIXt = "ISO8601"),
             .rpc_response, useBytes = TRUE)
}

.rpc_status <- tryCatch(
  {
    withCallingHandlers(.rpc_main(), warning = function(w) {
      message("Warning: ", conditionMessage(w))
      invokeRestart("muffleWarning")
    })
    0L
  },
  error = function(e) {
    msg <- conditionMessage(e)
    calls <- vapply(sys.calls(), function(cl) paste(deparse(cl, nlines = 1), collapse = " "),
                    character(1))
    writeLines(jsonlite::toJSON(list(error = msg, call = utils::tail(calls, 6)),
                                auto_unbox = TRUE), .rpc_response, useBytes = TRUE)
    message("Error: ", msg)
    1L
  }
)
cat("RPC_DONE\n")
quit(save = "no", status = .rpc_status)
