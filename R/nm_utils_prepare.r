#' Prepare and Standardize Date Column in Panel Data
#' @description
#' Ensures the input data frame contains a valid datetime column,
#' converts it to POSIXct format (UTC) if needed, and renames it to "date".
#'
#' @param df A data frame containing at least one datetime-like column.
#' @param prefer Optional string specifying which column to prioritize as the date column.
#' @param verbose Logical flag to enable progress messages.
#'
#' @importFrom lubridate yday wday hour
#' @importFrom data.table as.data.table is.data.table setDT setorder setnames
#'
#' @return A data frame with a standardized "date" column of POSIXct type (UTC).
#'
#' @examples
#' df <- nm_process_date(my1, verbose = FALSE)
#' head(df$date)
#'
#' @export
nm_process_date <- function(df, prefer = NULL, verbose = TRUE) {
  # 1. Check if 'date' already exists and is valid
  if ("date" %in% names(df) && inherits(df$date, c("POSIXct", "Date"))) {
    # Force UTC to prevent DST issues
    df$date <- as.POSIXct(df$date, tz = "UTC")
    return(df)
  }

  # 2. Try rownames
  if (inherits(row.names(df), "POSIXct")) {
    df$date <- as.POSIXct(row.names(df), tz = "UTC")
    row.names(df) <- NULL
    if (verbose) message("Extracted date from rownames.")
    return(df)
  }

  # 3. Search for existing POSIXct/Date columns
  time_columns <- names(df)[sapply(df, function(x) inherits(x, c("POSIXct", "Date")))]

  # 4. If none found, try regex matching on strings
  if (length(time_columns) == 0) {
    # Look for patterns like YYYY-MM-DD or YYYY/MM/DD
    candidates <- names(df)[sapply(df, function(x) {
      if (!is.character(x) && !is.factor(x)) return(FALSE)
      # Check first non-NA value to speed up
      val <- na.omit(as.character(x))[1]
      if (is.na(val)) return(FALSE)
      return(grepl("^\\d{4}[-/]\\d{2}[-/]\\d{2}", val))
    })]

    for (c in candidates) {
      # Try conversion with explicit UTC
      try_date <- suppressWarnings(as.POSIXct(df[[c]], tz = "UTC"))

      # Check if conversion was successful (mostly valid dates)
      if (inherits(try_date, "POSIXct") && mean(is.na(try_date)) < 0.5) {
        df$date <- try_date
        if (verbose) message("Converted column '", c, "' to POSIXct (UTC) and set as 'date'.")
        return(df)
      }
    }
    stop("No datetime column found. Please provide a column with 'YYYY-MM-DD HH:MM:SS' format.")
  }

  # 5. Select based on preference
  chosen <- if (!is.null(prefer) && prefer %in% time_columns) prefer else time_columns[1]
  df$date <- as.POSIXct(df[[chosen]], tz = "UTC")

  return(df)
}


#' Check Data Validity
#' @keywords internal
nm_check_data <- function(dt, covariates, target) {
  log <- nm_get_logger("data.prepare.check")

  if (!data.table::is.data.table(dt)) data.table::setDT(dt)

  # 1. Check target column
  if (!target %in% names(dt)) {
    log$error("Target variable '%s' not found.", target)
    stop("Target variable not found.")
  }

  # 2. Check covariates
  missing_vars <- setdiff(covariates, names(dt))
  if (length(missing_vars) > 0) {
    log$error("Missing covariates: %s", paste(missing_vars, collapse = ", "))
    stop("Missing covariates.")
  }

  # 3. Select relevant columns (Safe Unique Selection)
  # Prevent error if 'date' is accidentally included in covariates
  selected_columns <- unique(c("date", target, covariates))
  dt <- dt[, selected_columns, with = FALSE]

  # 4. Rename target to 'value'
  if (target != "value") {
    data.table::setnames(dt, old = target, new = "value")
  }

  # 5. Check date validity
  if (!"date" %in% names(dt)) stop("Input data must contain a 'date' column.")

  if (any(is.na(dt$date))) {
    log$error("`date` column contains NA values. Please clean the timeline.")
    stop("`date` contains NA.")
  }

  # 6. Ensure POSIXct (UTC)
  if (!inherits(dt$date, "POSIXct")) {
    dt[, date := as.POSIXct(date, tz = "UTC")]
  }

  return(dt)
}


#' Impute Missing Values (data.table version)
#'
#' \code{nm_impute_values} imputes or removes missing values using data.table.
#'
#' @keywords internal
nm_impute_values <- function(dt, dropna) {
  if (dropna) {
    # Efficiently remove rows with any NA
    dt <- na.omit(dt)
  } else {
    # Impute numeric columns with median
    numeric_cols <- names(dt)[sapply(dt, is.numeric)]
    for (col in numeric_cols) {
      if (any(is.na(dt[[col]]))) {
        median_val <- stats::median(dt[[col]], na.rm = TRUE)
        dt[is.na(get(col)), (col) := median_val]
      }
    }
    # Impute character/factor columns with mode
    other_cols <- names(dt)[sapply(dt, function(x) is.character(x) || is.factor(x))]
    for (col in other_cols) {
      if (any(is.na(dt[[col]]))) {
        mode_val <- nm_getmode(dt[[col]])
        dt[is.na(get(col)), (col) := mode_val]
      }
    }
  }
  return(dt)
}


#' Add Date Variables
#'
#' \code{nm_add_date_variables} adds date-related features using data.table.
#'
#' Always computes and adds all four columns (\code{date_unix},
#' \code{day_julian}, \code{weekday}, \code{hour}), regardless of whether
#' any of them will actually be used to train a model -- they're opt-in,
#' not mandatory. \code{\link{nm_build_model}}/\code{\link{nm_train_model}}
#' only use whichever of these four end up in the caller's \code{predictors};
#' a subset (e.g. only \code{weekday} and \code{hour}, omitting
#' \code{date_unix}/\code{day_julian}) or none at all (training purely on
#' meteorology, traffic counts, or other non-temporal predictors) both
#' work -- just don't list the ones you don't want.
#' \code{\link{nm_decompose}}/\code{\link{nm_decom_emi}} adapt
#' automatically, producing a component only for whichever time variables
#' actually ended up in the model.
#'
#' @keywords internal
nm_add_date_variables <- function(dt) {
  dt[, `:=`(
    date_unix = as.numeric(as.POSIXct(date)),
    day_julian = lubridate::yday(date),

    # week_start = 1 ensures Monday=1, Sunday=7.
    weekday = factor(lubridate::wday(date, label = TRUE, week_start = 1), ordered = FALSE),

    hour = lubridate::hour(date)
  )]
  return(dt)
}


#' Convert Ordered Factors to Factors
#'
#' \code{nm_convert_ordered_to_factor} converts ordered factors to regular factors.
#'
#' @keywords internal
nm_convert_ordered_to_factor <- function(dt) {
  # Find ordered factors
  ordered_cols <- names(dt)[sapply(dt, is.ordered)]
  if (length(ordered_cols) > 0) {
    for (col in ordered_cols) {
      # Convert to standard factor
      dt[, (col) := factor(as.character(get(col)), ordered = FALSE)]
    }
  }
  return(dt)
}


#' Split Data into Training and Testing Sets
#'
#' \code{nm_split_into_sets} splits the data.table into training and testing sets.
#'
#' @param dt A data.table containing a column named `date`.
#' @param split_method Character string, one of
#' \code{c("random", "ts", "month_ts", "season_ts")}.
#' **Note on 'season_ts'**: Uses Northern Hemisphere meteorological
#' seasons (Dec-Feb=DJF); December is grouped with the *following* year's
#' DJF block. **'month_ts'/'season_ts'** split *chronologically* within each
#' individual (year, month) or (meteorological year, season) instance: a
#' contiguous \code{1 - train_fraction} block of each block is held out as
#' testing, at a random position within the period (seeded by \code{seed},
#' reproducible). This combines "ts"'s within-block temporal ordering (a
#' contiguous block is held out, not randomly interleaved with training
#' rows from the same days) with full-record coverage (every block, across
#' every year, contributes training rows) -- avoiding the extrapolation
#' failure a single global "ts" cutoff causes for monotonic features such
#' as a Unix-time trend.
#'
#' **Note:** before this random-position placement, 'month_ts'/'season_ts'
#' held out a block at a *fixed relative position* within every period --
#' always the trailing \code{1 - train_fraction} -- which meant any calendar
#' window consistently falling in that trailing slice (e.g. late December,
#' with \code{train_fraction = 0.75}'s trailing ~8 days of a 31-day month) was
#' excluded from training in *every* year of the record, not just some of
#' them. That created a permanent blind spot: a decomposition or
#' feature-importance step built on such a model could systematically fail
#' to represent whatever real signal lived in that window (observed
#' directly in practice: a genuine, network-corroborated holiday-period
#' activity drop was absent from the recovered components under the old
#' fixed-trailing \code{"month_ts"} but present under \code{"random"}).
#' Randomising the window's start position per period (via \code{seed})
#' removes that permanent alignment -- a given calendar window is no
#' longer excluded in every year. This doesn't make a *single* run immune
#' to coincidentally missing a specific window in some subset of years
#' (the window position is still fixed once \code{seed} is fixed, just no
#' longer calendar-anchored); \code{"random"} remains the safest default
#' for data with a recurring feature you must not systematically lose from
#' training.
#' @param train_fraction Numeric fraction (0–1) of rows per group to assign to training.
#' @param seed Integer random seed for reproducibility.
#'
#' @return The input data.table with an added column `set` ("training" or "testing").
#' @keywords internal
nm_split_into_sets <- function(dt, split_method = c("random", "ts", "month_ts", "season_ts"), train_fraction = 0.75, seed = 123) {
  split_method <- match.arg(split_method)
  set.seed(seed)

  data.table::setorder(dt, date)

  # Marks `idx` (ascending == chronological) "training" outside a random
  # contiguous test window of size `length(idx) - floor(train_fraction*length(idx))`.
  # See @param split_method above for why a random (not fixed-trailing)
  # position matters.
  mark_random_window_training <- function(dt, idx) {
    n <- length(idx)
    cut <- floor(train_fraction * n)
    test_len <- n - cut
    max_start <- max(n - test_len, 0L)
    start <- if (max_start > 0L) sample.int(max_start + 1L, 1L) - 1L else 0L
    train_positions <- setdiff(seq_len(n), seq.int(start + 1L, start + test_len))
    if (length(train_positions) > 0) dt[idx[train_positions], set := "training"]
  }

  if (split_method == "random") {
    train_idx <- sample(seq_len(nrow(dt)), size = floor(train_fraction * nrow(dt)))
    dt[, set := "testing"]
    dt[train_idx, set := "training"]

  } else if (split_method == "ts") {
    n <- nrow(dt)
    cut <- floor(train_fraction * n)
    dt[, set := ifelse(seq_len(n) <= cut, "training", "testing")]

  } else if (split_method == "month_ts") {
    # Chronological split within each individual (year, month) instance:
    # a contiguous (1 - train_fraction) block, at a random position (seeded), is
    # held out as testing; the rest of the month is training.
    dt[, ym_temp := format(date, "%Y-%m")]
    dt[, set := "testing"]

    for (ym in unique(dt$ym_temp)) {
      idx <- which(dt$ym_temp == ym)  # ascending order == chronological, dt is sorted
      mark_random_window_training(dt, idx)
    }
    dt[, ym_temp := NULL]

  } else if (split_method == "season_ts") {
    # Chronological split within each individual (meteorological year,
    # season) instance: a contiguous (1 - fraction) block, at a random
    # position (seeded), is held out as testing. December is assigned to
    # the following year's DJF block so each DJF group is a single
    # contiguous Dec-Jan-Feb span.
    season_map <- c("DJF", "DJF", "MAM", "MAM", "MAM", "JJA", "JJA", "JJA", "SON", "SON", "SON", "DJF")
    month_int <- as.integer(format(dt$date, "%m"))
    dt[, season_temp := season_map[month_int]]
    dt[, season_year_temp := as.integer(format(dt$date, "%Y"))]
    dt[month_int == 12L, season_year_temp := season_year_temp + 1L]
    dt[, sy_key_temp := paste(season_year_temp, season_temp, sep = "_")]
    dt[, set := "testing"]

    for (k in unique(dt$sy_key_temp)) {
      idx <- which(dt$sy_key_temp == k)  # ascending order == chronological, dt is sorted
      mark_random_window_training(dt, idx)
    }
    dt[, c("season_temp", "season_year_temp", "sy_key_temp") := NULL]
  }

  return(dt)
}



#' Prepare Data for Model Training
#'
#' @description
#' `nm_prepare_data` is a high-level wrapper that performs a complete data preparation pipeline.
#' It handles date standardization, feature selection, missing value treatment,
#' automatic generation of time-based features, and data splitting.
#'
#' @param df The raw input data frame.
#' @param target A string indicating the target variable name (e.g., pollutant concentration).
#' @param covariates A character vector of external predictor columns (e.g., meteorological variables).
#'   \strong{Note:} Do NOT include time variables (e.g., "weekday", "day_julian") here, as they are
#'   automatically generated and added by this function.
#' @param dropna If TRUE, rows with NA values are removed. If FALSE, they are imputed.
#' @param split_method A string for the data splitting strategy (e.g., "random").
#'   See \code{\link{nm_split_into_sets}} for the exact mechanics -- in
#'   particular, \code{"month_ts"}/\code{"season_ts"} hold out a contiguous
#'   block at a randomised (seeded) position within every period, rather
#'   than always the trailing slice; read that function's note for why
#'   that matters and its remaining caveats before choosing them over
#'   \code{"random"}.
#' @param train_fraction A numeric value for the training fraction of the split (default 0.75).
#' @param seed An integer for the random seed to ensure reproducibility.
#' @param verbose Should the function print log messages?
#'
#' @return A prepared data frame ready for model training, including the new time features and a 'set' column.
#'
#' @examples
#' covariates <- c("ws", "wd", "temp", "RH", "blh", "ssrd")
#' df_prep <- nm_prepare_data(
#'   my1[1:200, c("date", "NO2", covariates)],
#'   target = "NO2", covariates = covariates, verbose = FALSE
#' )
#' head(df_prep)
#'
#' @export
nm_prepare_data <- function(df, target, covariates, dropna = TRUE,
                            split_method = "random", train_fraction = 0.75,
                            seed = 7654321, verbose = FALSE) {

  log <- nm_get_logger("data.prepare")
  nm_require("data.table", hint = "install.packages('data.table')")
  nm_require("lubridate", hint = "install.packages('lubridate')")

  if (verbose) log$info("Starting data preparation pipeline...")

  # 1. Standardize date (UTC forced)
  df_processed_date <- nm_process_date(df, verbose = verbose)
  dt <- data.table::as.data.table(df_processed_date)

  # 2. Check and clean columns
  dt <- nm_check_data(dt, covariates = covariates, target = target)

  # 3. Impute
  dt <- nm_impute_values(dt, dropna = dropna)

  # 4. Add Features
  dt <- nm_add_date_variables(dt)
  dt <- nm_convert_ordered_to_factor(dt)

  # 5. Split (With fixed season logic)
  dt <- nm_split_into_sets(dt, split_method = split_method, train_fraction = train_fraction, seed = seed)

  if (verbose) {
    n_train <- dt[set == "training", .N]
    n_test <- dt[set == "testing", .N]
    log$info("Data prep complete: %d rows (%d training, %d testing).", nrow(dt), n_train, n_test)
  }

  return(as.data.frame(dt))
}


#' Helper function to get mode
#' @keywords internal
nm_getmode <- function(v) {
  uniqv <- unique(v[!is.na(v)])
  if (length(uniqv) == 0) return(NA)
  uniqv[which.max(tabulate(match(v, uniqv)))]
}
