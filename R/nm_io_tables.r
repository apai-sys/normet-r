# A time series from a table file, whatever form the file and its times take.
#
#   nm_table_suffixes        the files read: text, Excel, Parquet, Feather, JSON
#   nm_read_table(path)      the file as a data.frame
#   nm_find_dates(df)        its times in a column named 'date', and how they were read
#   nm_parse_dates(values)   one column of times, in whichever form they are written
#   nm_on_clock(dates, zone) times on one clock: a table's own (local time, or UTC)
#   nm_clock_to_utc / nm_utc_to_clock   between that clock and UTC
#   nm_read_time_series(path)  a table ready for analysis, on its clock
#
# Times. A table's times may be one column or several (a date and a time, or a year,
# month, day and hour), written as text in any of the usual orders (2020-01-31,
# 31/01/2020, 01/31/2020, 31.01.2020, 2020-01-31T13:00, a CJK-written date), as numbers
# (Unix seconds or milliseconds, Excel's serial days, 20200131 or 2020013113), or with
# their own UTC offset (2020-03-29T02:00+01:00).
#
# Clocks. normet keeps a table's times as POSIXct in "UTC" whose clock reading is the
# table's own clock -- a site's local time (Asia/Shanghai, Europe/London) or UTC -- so
# the hour and weekday a model learns from are the site's. Times written with their own
# offset are put on that clock. Meteorology joined to a table (ERA5, Open-Meteo,
# HYSPLIT) is on UTC, and is put on the table's clock as it is joined
# (nm_utc_to_clock()); what it is fetched for goes the other way (nm_clock_to_utc()).

NULL

.EXCEL_SUFFIXES <- c(".xlsx", ".xlsm", ".xls")
.TEXT_SUFFIXES <- c(".csv", ".txt", ".tsv", ".dat")
.BINARY_SUFFIXES <- c(".parquet", ".feather", ".json")

#' File suffixes nm_read_table() reads
#'
#' Delimited text (plain or gzipped), Excel workbooks, Parquet, Feather and JSON.
#' @format A character vector.
#' @export
nm_table_suffixes <- c(
  .TEXT_SUFFIXES, paste0(.TEXT_SUFFIXES, ".gz"), .EXCEL_SUFFIXES, .BINARY_SUFFIXES
)

# CJK words in headers and dates, written as escapes so the package source stays ASCII.
.ZH <- list(
  date = intToUtf8(c(0x65e5, 0x671f)), time = intToUtf8(c(0x65f6, 0x95f4)),
  datetime = intToUtf8(c(0x65e5, 0x671f, 0x65f6, 0x95f4)),
  year = intToUtf8(0x5e74), month = intToUtf8(0x6708), day = intToUtf8(0x65e5),
  hour = intToUtf8(0x65f6), hours = intToUtf8(c(0x5c0f, 0x65f6)), dian = intToUtf8(0x70b9),
  dian_t = intToUtf8(0x9ede), minute = intToUtf8(0x5206), second = intToUtf8(0x79d2)
)
# The middle dot joining the parts of "how the times were read".
.DOT <- intToUtf8(0xb7)

# Headers a table's times go under, compared without case, spaces or punctuation.
.DATE_NAMES <- c(
  "date", "datetime", "datetimeutc", "dateutc", "timestamp", "time", "times", "dt",
  "dateandtime", "datetimelocal", "starttime", "start", "readingdatetime",
  .ZH$date, .ZH$time, .ZH$datetime
)
# A separate time-of-day column beside a date column.
.TIME_NAMES <- c("time", "hour", "hourofday", "timeofday", .ZH$time, .ZH$hours)
# Calendar parts in columns of their own.
.PART_NAMES <- list(
  year = c("year", "yr", .ZH$year),
  month = c("month", "mon", .ZH$month),
  day = c("day", "dayofmonth", "date", .ZH$day),
  hour = c("hour", "hr", .ZH$hour, .ZH$hours)
)

# A header compared without case, spaces or punctuation: "Date/Time (UTC)" is
# "datetimeutc".
.header_key <- function(name) tolower(gsub("[[:space:]_/().:-]+", "", as.character(name)))

# The suffix a file is read by: ".csv.gz" for a gzipped CSV, else the last one.
.path_suffix <- function(path) {
  name <- tolower(as.character(path))
  for (s in nm_table_suffixes) if (endsWith(name, s)) return(s)
  ext <- tools::file_ext(name)
  if (nzchar(ext)) paste0(".", ext) else ""
}

.without_blank_rows <- function(df) {
  if (nrow(df) == 0 || ncol(df) == 0) return(df)
  blank <- Reduce(`&`, lapply(df, function(col) {
    is.na(col) | !nzchar(trimws(as.character(col)))
  }))
  if (any(blank)) {
    df <- df[!blank, , drop = FALSE]
    rownames(df) <- NULL
  }
  df
}

# Every byte of a file, gzipped or not.
.read_bytes <- function(path) {
  con <- gzfile(path, "rb") # reads plain files as they are
  on.exit(close(con))
  chunks <- list()
  repeat {
    b <- readBin(con, "raw", n = 1048576L)
    if (length(b) == 0) break
    chunks[[length(chunks) + 1L]] <- b
  }
  unlist(chunks, use.names = FALSE)
}

# Bytes as UTF-8 text: UTF-8 (with or without Excel's byte-order mark), else GB18030,
# else Windows-1252, else Latin-1.
.decode_text <- function(blob) {
  if (length(blob) >= 3 && identical(blob[1:3], as.raw(c(0xef, 0xbb, 0xbf)))) {
    blob <- blob[-(1:3)]
  }
  blob <- blob[blob != as.raw(0)]
  text <- rawToChar(blob)
  if (validUTF8(text)) {
    Encoding(text) <- "UTF-8"
    return(text)
  }
  for (enc in c("GB18030", "CP1252", "latin1")) {
    out <- iconv(text, enc, "UTF-8")
    if (!is.na(out)) return(out)
  }
  text
}

# The field separator among , ; tab |: the one splitting the sample's lines into the
# same number (above one) of fields most often.
.sniff_sep <- function(lines, suffix) {
  lines <- lines[nzchar(trimws(lines))]
  best <- NULL
  best_score <- 0
  for (sep in c(",", ";", "\t", "|")) {
    n <- lengths(regmatches(lines, gregexpr(sep, lines, fixed = TRUE)))
    if (length(n) == 0 || all(n == 0)) next
    tab <- table(n[n > 0])
    mode_n <- as.integer(names(tab)[which.max(tab)])
    score <- sum(n == mode_n)
    if (score > best_score) {
      best <- sep
      best_score <- score
    }
  }
  if (!is.null(best)) return(best)
  if (suffix %in% c(".dat", ".txt", ".dat.gz", ".txt.gz")) " " else ","
}

#' Read a table file as a data.frame
#'
#' An Excel workbook (`.xlsx`, `.xlsm`, `.xls`) is read from its first sheet (needs
#' \pkg{readxl}); Parquet and Feather through \pkg{arrow}; JSON (records or columns)
#' through \pkg{jsonlite}. Anything else is delimited text, plain or gzipped, which
#' instruments and spreadsheets write several ways: commas, semicolons, tabs or bars
#' between fields, a decimal comma where the fields are not comma-separated, UTF-8 with
#' or without Excel's byte-order mark, or a Windows code page (or GB18030) for a "ug" or
#' "degC" sign in the header. Each is settled from the file itself. Columns are read as
#' text and converted to numbers where every value is one; times are left as text for
#' \code{\link{nm_find_dates}}. Rows that hold nothing in any field are dropped.
#'
#' @param path Path to the file.
#' @param ... Passed on to the reader (\code{data.table::fread} for text).
#' @return A data.frame.
#' @seealso \code{\link{nm_read_time_series}}, \code{\link{nm_table_suffixes}}
#' @export
nm_read_table <- function(path, ...) {
  if (!file.exists(path)) stop("File not found: ", path)
  suffix <- .path_suffix(path)
  if (suffix %in% .EXCEL_SUFFIXES) {
    nm_require("readxl", hint = "install.packages('readxl'), or save the sheet as .csv")
    df <- as.data.frame(readxl::read_excel(path, sheet = 1, ...), stringsAsFactors = FALSE)
    names(df) <- as.character(names(df))
    return(.without_blank_rows(df))
  }
  if (suffix == ".parquet") {
    nm_require("arrow", hint = "install.packages('arrow')")
    return(as.data.frame(arrow::read_parquet(path, ...)))
  }
  if (suffix == ".feather") {
    nm_require("arrow", hint = "install.packages('arrow')")
    return(as.data.frame(arrow::read_feather(path, ...)))
  }
  if (suffix == ".json") {
    obj <- jsonlite::fromJSON(path, ...)
    df <- as.data.frame(obj, stringsAsFactors = FALSE)
    return(.without_blank_rows(df))
  }

  text <- .decode_text(.read_bytes(path))
  lines <- strsplit(text, "\r\n|\n|\r")[[1]]
  sample <- utils::head(lines, 50)
  args <- list(...)
  sep <- if (!is.null(args$sep)) args$sep else .sniff_sep(sample, suffix)
  args$sep <- NULL
  dec <- if (!is.null(args$dec)) args$dec else {
    # Fields that are numbers with a decimal comma, against those with a point (a
    # date's dots, 31.01.2020, are neither).
    fields <- trimws(unlist(strsplit(sample[-1], sep, fixed = TRUE)))
    commas <- sum(grepl("^-?\\d+,\\d+$", fields))
    points <- sum(grepl("^-?\\d+\\.\\d+$", fields))
    if (sep != "," && commas > points) "," else "."
  }
  args$dec <- NULL
  df <- do.call(data.table::fread, c(list(
    text = paste(lines, collapse = "\n"), sep = sep, colClasses = "character",
    data.table = FALSE, encoding = "UTF-8", na.strings = c("", "NA"),
    strip.white = TRUE, fill = TRUE
  ), args))
  df[] <- lapply(df, function(col) {
    if (!is.character(col)) return(col)
    v <- trimws(col)
    known <- !is.na(v) & nzchar(v)
    if (!any(known)) return(col)
    num <- suppressWarnings(as.numeric(if (dec == ",") sub(",", ".", v, fixed = TRUE) else v))
    if (all(!is.na(num[known]))) num else col
  })
  .without_blank_rows(df)
}

# -- times ---------------------------------------------------------------------------------

.TIME_PART <- paste0(
  "(?:[ T]+(\\d{1,2})(?::(\\d{2}))?(?::(\\d{2}(?:\\.\\d+)?))?\\s*([AaPp][Mm])?)?"
)
.OFFSET_PART <- "\\s*(Z|UTC|GMT|[+-]\\d{2}(?::?\\d{2})?)?"
.ISO_RE <- paste0("^(\\d{4})[-/.](\\d{1,2})[-/.](\\d{1,2})", .TIME_PART, .OFFSET_PART, "$")
.NUMERIC_RE <- paste0("^(\\d{1,2})[-/.](\\d{1,2})[-/.](\\d{2,4})", .TIME_PART, .OFFSET_PART, "$")
.DMON_RE <- paste0(
  "^(\\d{1,2})[ -]([A-Za-z]{3,9})\\.?[ ,-]+(\\d{4})", .TIME_PART, .OFFSET_PART, "$"
)
.MOND_RE <- paste0(
  "^([A-Za-z]{3,9})\\.? (\\d{1,2})(?:st|nd|rd|th)?,? (\\d{4})", .TIME_PART, .OFFSET_PART, "$"
)
.NUMERIC_DMY_START <- "^\\s*(\\d{1,2})[/.-](\\d{1,2})[/.-](\\d{2,4})"

# Captures of `pattern` in each of `x`: a character matrix, a row of NA where it does
# not match.
.captures <- function(x, pattern) {
  m <- regmatches(x, regexec(pattern, x, perl = TRUE))
  # Capturing groups: an unescaped "(" not opening "(?".
  n_groups <- 1L + length(gregexpr("(?<!\\\\)\\((?!\\?)", pattern, perl = TRUE)[[1]])
  out <- matrix(NA_character_, nrow = length(x), ncol = n_groups)
  hit <- lengths(m) > 0
  if (any(hit)) out[hit, ] <- do.call(rbind, m[hit])
  out
}

.offset_seconds <- function(off) {
  out <- rep(0, length(off))
  signed <- !is.na(off) & grepl("^[+-]", off)
  if (any(signed)) {
    o <- gsub(":", "", off[signed])
    sgn <- ifelse(substr(o, 1, 1) == "-", -1, 1)
    hh <- as.numeric(substr(o, 2, 3))
    mm <- ifelse(nchar(o) >= 5, as.numeric(substr(o, 4, 5)), 0)
    out[signed] <- sgn * (hh * 3600 + mm * 60)
  }
  out
}

.month_number <- function(name) {
  match(tolower(substr(name, 1, 3)), tolower(month.abb))
}

# Assemble times from captured parts (year, month, day as numbers; the time columns
# H, M, S, ampm, offset as text, "" where absent). Offsets are applied: the result is
# the UTC instant for an offset value, the clock reading (labelled UTC) otherwise.
.assemble_times <- function(y, mo, d, cap_time) {
  num <- function(v, default = 0) {
    v <- suppressWarnings(as.numeric(v))
    ifelse(is.na(v), default, v)
  }
  H <- num(cap_time[, 1])
  M <- num(cap_time[, 2])
  S <- num(cap_time[, 3])
  ampm <- toupper(ifelse(is.na(cap_time[, 4]), "", cap_time[, 4]))
  H <- ifelse(ampm == "PM" & H < 12, H + 12, ifelse(ampm == "AM" & H == 12, 0, H))
  off <- cap_time[, 5]
  aware <- !is.na(off) & nzchar(off)
  y <- ifelse(!is.na(y) & y < 100, ifelse(y < 69, 2000 + y, 1900 + y), y)
  ok <- !is.na(y) & !is.na(mo) & !is.na(d) & H <= 24 & M < 60 & S < 61
  base <- rep(NA_real_, length(y))
  if (any(ok)) {
    t <- ISOdatetime(y[ok], mo[ok], d[ok], 0, 0, 0, tz = "UTC")
    # ISOdatetime refuses 24:00; the hour is added after.
    base[ok] <- as.numeric(t) + H[ok] * 3600 + M[ok] * 60 + S[ok]
  }
  base <- base - ifelse(aware, .offset_seconds(off), 0)
  list(time = base, aware = aware & !is.na(base), offset = ifelse(aware, off, NA_character_))
}

# Whether dates written as two numbers then the year put the day first: TRUE where one
# of the first numbers passes 12, FALSE where one of the second does, NA where neither
# does (and NA for text not so written).
.day_first <- function(text) {
  cap <- .captures(text, .NUMERIC_DMY_START)
  found <- !is.na(cap[, 1])
  if (!any(found)) return(NA)
  first <- as.integer(cap[found, 2])
  second <- as.integer(cap[found, 3])
  if (any(first > 12)) return(TRUE)
  if (any(second > 12)) return(FALSE)
  NA
}

# A CJK-written date and time (year/month/day and hour/minute/second marks) as
# 2020-01-31 13:05:00.
.from_cjk <- function(text) {
  # Compared as bytes, so a UTF-8 string matches whatever the session's locale.
  z <- lapply(.ZH, enc2utf8)
  date_re <- sprintf("(\\d{4})\\s*%s\\s*(\\d{1,2})\\s*%s\\s*(\\d{1,2})\\s*(?:%s)?",
                     z$year, z$month, z$day)
  time_re <- sprintf(
    "(\\d{1,2})\\s*(?:%s|%s|%s)\\s*(?:(\\d{1,2})\\s*%s)?\\s*(?:(\\d{1,2})\\s*%s)?",
    z$hour, z$dian, z$dian_t, z$minute, z$second
  )
  one <- function(s) {
    if (is.na(s)) return(s)
    m <- regmatches(s, regexec(date_re, s, perl = TRUE, useBytes = TRUE))[[1]]
    if (length(m)) {
      s <- sub(date_re, sprintf("%s-%02d-%02d ", m[2], as.integer(m[3]), as.integer(m[4])), s,
               perl = TRUE, useBytes = TRUE)
    }
    m <- regmatches(s, regexec(time_re, s, perl = TRUE, useBytes = TRUE))[[1]]
    if (length(m)) {
      v <- suppressWarnings(as.integer(m[2:4]))
      v[is.na(v)] <- 0L
      s <- sub(time_re, sprintf("%02d:%02d:%02d", v[1], v[2], v[3]), s, perl = TRUE,
               useBytes = TRUE)
    }
    trimws(s)
  }
  vapply(text, one, character(1), USE.NAMES = FALSE)
}

# Text times, value by value: the parsed time (numeric seconds), whether each had its own
# UTC offset, and how they were read, in words.
.parse_text_times <- function(text, dayfirst = NULL) {
  text <- trimws(as.character(text))
  how <- "as written"
  if (any(grepl(enc2utf8(.ZH$year), text, fixed = TRUE, useBytes = TRUE), na.rm = TRUE)) {
    text <- .from_cjk(text)
    how <- paste0("as written (", .ZH$year, .ZH$month, .ZH$day, ")")
  }
  first <- .day_first(text)
  if (is.na(first)) {
    if (is.null(dayfirst)) {
      dayfirst <- any(grepl("^\\s*\\d{1,2}\\.\\d{1,2}\\.\\d{2,4}", text), na.rm = TRUE)
    }
    first <- isTRUE(dayfirst)
    if (any(grepl(.NUMERIC_DMY_START, text), na.rm = TRUE)) {
      how <- paste0(if (first) "day first (31/01)" else "month first (01/31)",
                    " ", .DOT, " the column does not tell the order")
    }
  } else {
    how <- if (first) "day first (31/01)" else "month first (01/31)"
  }

  u <- unique(text)
  time <- rep(NA_real_, length(u))
  aware <- rep(FALSE, length(u))
  offset <- rep(NA_character_, length(u))
  todo <- !is.na(u) & nzchar(u)
  put <- function(sel, parsed) {
    take <- sel & is.na(time) & !is.na(parsed$time)
    time[take] <<- parsed$time[take]
    aware[take] <<- parsed$aware[take]
    offset[take] <<- parsed$offset[take]
  }
  if (any(todo)) {
    cap <- .captures(u, .ISO_RE)
    sel <- todo & !is.na(cap[, 1])
    put(sel, .assemble_times(as.numeric(cap[, 2]), as.numeric(cap[, 3]),
                             as.numeric(cap[, 4]), cap[, 5:9, drop = FALSE]))
    cap <- .captures(u, .NUMERIC_RE)
    sel <- todo & !is.na(cap[, 1])
    a <- as.numeric(cap[, 2])
    b <- as.numeric(cap[, 3])
    put(sel, .assemble_times(as.numeric(cap[, 4]), if (first) b else a, if (first) a else b,
                             cap[, 5:9, drop = FALSE]))
    cap <- .captures(u, .DMON_RE)
    sel <- todo & !is.na(cap[, 1])
    put(sel, .assemble_times(as.numeric(cap[, 4]), .month_number(cap[, 3]),
                             as.numeric(cap[, 2]), cap[, 5:9, drop = FALSE]))
    cap <- .captures(u, .MOND_RE)
    sel <- todo & !is.na(cap[, 1])
    put(sel, .assemble_times(as.numeric(cap[, 4]), .month_number(cap[, 2]),
                             as.numeric(cap[, 3]), cap[, 5:9, drop = FALSE]))
  }
  idx <- match(text, u)
  list(time = time[idx], aware = aware[idx], offset = offset[idx], how = how)
}

.as_utc_posixct <- function(seconds) .POSIXct(as.numeric(seconds), tz = "UTC")

# Times from any vector, as POSIXct (UTC), coercing what does not parse to NA, with
# whether each value carried its own UTC offset. Values whose offsets differ -- local
# time across a daylight-saving change, +00:00 in winter and +01:00 in summer -- have no
# one time zone to keep, so every offset value is converted to UTC by its own offset; a
# value with no offset is read as a clock reading (labelled UTC).
.parse_any_times <- function(values, dayfirst = NULL) {
  if (inherits(values, "POSIXt")) {
    v <- as.POSIXct(values)
    tz <- attr(v, "tzone")
    aware <- !is.null(tz) && length(tz) && nzchar(tz[1]) && !(tz[1] %in% c("UTC", "GMT"))
    return(list(time = as.numeric(v), aware = rep(aware, length(v)), how = "as stored",
                zone = if (aware) tz[1] else NULL))
  }
  if (inherits(values, "Date")) {
    return(list(time = as.numeric(values) * 86400, aware = rep(FALSE, length(values)),
                how = "as stored"))
  }
  if (is.factor(values)) values <- as.character(values)
  if (is.numeric(values)) {
    v <- as.numeric(values)
    fin <- v[is.finite(v)]
    if (!length(fin)) {
      return(list(time = rep(NA_real_, length(v)), aware = rep(FALSE, length(v)),
                  how = "as written"))
    }
    lo <- min(fin)
    hi <- max(fin)
    none <- rep(FALSE, length(v))
    if (lo >= 19000101 && hi <= 21001231) {
      t <- as.POSIXct(sprintf("%.0f", v), format = "%Y%m%d", tz = "UTC")
      return(list(time = as.numeric(t), aware = none, how = "as YYYYMMDD"))
    }
    if (lo >= 1900010100 && hi <= 2100123123) {
      t <- as.POSIXct(sprintf("%.0f", v), format = "%Y%m%d%H", tz = "UTC")
      return(list(time = as.numeric(t), aware = none, how = "as YYYYMMDDHH"))
    }
    if (lo >= 1e12 && hi < 1e13) return(list(time = v / 1000, aware = none, how = "as Unix milliseconds"))
    if (lo >= 1e8 && hi < 1e10) return(list(time = v, aware = none, how = "as Unix seconds"))
    if (lo >= 2e4 && hi <= 8e4) {
      origin <- as.numeric(as.POSIXct("1899-12-30", tz = "UTC"))
      return(list(time = origin + v * 86400, aware = none, how = "as Excel serial days"))
    }
    stop(sprintf(paste0(
      "the numbers %g to %g are not times normet can read ",
      "(Unix seconds, Excel serial days, or 20200131-style dates)"
    ), lo, hi))
  }
  .parse_text_times(values, dayfirst = dayfirst)
}

# Text dates (or anything) to POSIXct UTC, coercing failures to NA; offsets are applied
# each by its own, so dates on both sides of a daylight-saving change keep their order.
.to_datetime_coerced <- function(values, dayfirst = NULL) {
  if (inherits(values, "POSIXct")) return(values)
  p <- .parse_any_times(values, dayfirst = dayfirst)
  offs <- unique(stats::na.omit(p$offset))
  if (length(offs) > 1) {
    nm_get_logger("utils.time")$info(
      "Dates with differing UTC offsets (daylight saving, say) were converted to UTC."
    )
  }
  .as_utc_posixct(p$time)
}

#' Parse one column of times, in whichever form they are written
#'
#' Numbers are read by their size: Unix seconds (1e8 to 1e10) or milliseconds (1e12 to
#' 1e13), Excel serial days (20 000 to 80 000, from 1899-12-30), 20200131 and
#' 2020013113 as dates and hours. Text is read value by value (ISO 8601 with a `T` or a
#' space, `/`, `.` or `-` between the parts, month names, AM/PM, CJK-written dates);
#' dates written as two numbers and a year (31/01/2020) take the order the column itself
#' shows -- the day first where a first number passes 12, the month where a second does
#' -- or `dayfirst` where it shows neither (by default: the day first after a dot,
#' 31.01.2020, the month first otherwise). A value that does not parse becomes `NA`.
#'
#' Times written with their own UTC offset (`2020-03-29T02:00+01:00`, `...Z`) are
#' converted to UTC, each by its own offset -- so local times across a daylight-saving
#' change (`+00:00` in winter, `+01:00` in summer) keep their order -- and a value with
#' no offset is read as written. Base R's `as.POSIXct()` instead drops the time from
#' `2020-01-31T13:00` and ignores the offset.
#'
#' @param values A vector of times: character, factor, numeric, Date or POSIXct.
#' @param dayfirst Logical or `NULL`. The order for `01/02/2020`-style dates when the
#'   column does not settle it.
#' @return A POSIXct vector (tz `"UTC"`), with attribute `"how"`: how the times were
#'   read, in words.
#' @examples
#' nm_parse_dates(c("31/01/2020 13:00", "01/02/2020 14:00"))
#' nm_parse_dates(c("2020-03-29T00:30+00:00", "2020-03-29T02:30+01:00"))
#' @export
nm_parse_dates <- function(values, dayfirst = NULL) {
  p <- .parse_any_times(values, dayfirst = dayfirst)
  out <- .as_utc_posixct(p$time)
  attr(out, "how") <- p$how
  out
}

.match_header <- function(columns, names) {
  keys <- .header_key(names)
  hit <- columns[.header_key(columns) %in% keys]
  if (length(hit)) hit[1] else NULL
}

# find_dates' work, keeping which values had their own offset (for nm_on_clock).
.find_dates <- function(df, dayfirst = NULL) {
  df <- as.data.frame(df, stringsAsFactors = FALSE)
  cols <- names(df)
  found <- .match_header(cols, .DATE_NAMES)
  parts <- lapply(.PART_NAMES, function(n) .match_header(cols, n))
  if (!is.null(found) && .header_key(found) %in% .header_key(.PART_NAMES$day) &&
      !is.null(parts$year)) {
    found <- NULL # "day" beside "year" and "month" is a part, not the times
  }
  if (is.null(found) && !is.null(parts$year) && !is.null(parts$month)) {
    num <- function(col, default) {
      if (is.null(col)) return(default)
      suppressWarnings(as.numeric(df[[col]]))
    }
    y <- num(parts$year, NA)
    mo <- num(parts$month, NA)
    d <- num(parts$day, 1)
    h <- num(parts$hour, 0)
    t <- ISOdatetime(y, mo, d, 0, 0, 0, tz = "UTC") + h * 3600
    used <- unlist(parts[!vapply(parts, is.null, logical(1))], use.names = FALSE)
    out <- df[, setdiff(cols, used), drop = FALSE]
    out <- cbind(data.frame(date = t), out)
    return(list(df = out, how = paste0("joined from ", paste(used, collapse = ", ")),
                aware = rep(FALSE, nrow(out)), zone = NULL))
  }
  if (is.null(found)) {
    for (c in cols) {
      x <- df[[c]]
      if (inherits(x, c("POSIXt", "Date"))) {
        found <- c
        break
      }
      if (is.character(x) || is.factor(x)) {
        trial <- .parse_text_times(utils::head(as.character(x), 200), dayfirst = dayfirst)
        if (mean(!is.na(trial$time)) >= 0.9) {
          found <- c
          break
        }
      }
    }
  }
  if (is.null(found)) {
    stop("No column of times was found: name it 'date' (or datetime, timestamp, time), ",
         "or give year, month, day and hour columns.")
  }
  p <- .parse_any_times(df[[found]], dayfirst = dayfirst)
  dates <- p$time
  said <- if (found != "date") sprintf("from '%s' %s %s", found, .DOT, p$how) else p$how
  clock <- .match_header(setdiff(cols, found), .TIME_NAMES)
  drop <- found
  if (!is.null(clock) && any(!is.na(dates))) {
    known <- dates[!is.na(dates)]
    if (all(known %% 86400 == 0)) {
      cv <- df[[clock]]
      offset <- if (is.numeric(cv)) {
        cv * 3600
      } else {
        ct <- trimws(as.character(cv))
        m <- .captures(ct, "^(\\d{1,2})(?::(\\d{2}))?(?::(\\d{2}(?:\\.\\d+)?))?$")
        hh <- as.numeric(m[, 2])
        mm <- suppressWarnings(as.numeric(m[, 3]))
        ss <- suppressWarnings(as.numeric(m[, 4]))
        hh * 3600 + ifelse(is.na(mm), 0, mm) * 60 + ifelse(is.na(ss), 0, ss)
      }
      dates <- dates + offset
      drop <- c(drop, clock)
      said <- paste0(said, sprintf(" %s hours from '%s'", .DOT, clock))
    }
  }
  out <- df[, setdiff(cols, drop), drop = FALSE]
  out <- cbind(data.frame(date = .as_utc_posixct(dates)), out)
  list(df = out, how = said, aware = p$aware, zone = p$zone)
}

#' Find a table's times and put them in a column named 'date'
#'
#' The times are a column named as times are (date, datetime, timestamp, time, or their
#' Chinese names) -- joined with a time-of-day column beside it where the dates have no
#' hours -- or year, month, day (and hour) columns, joined; else the first text column
#' that reads as times (\code{\link{nm_parse_dates}}).
#'
#' @param df A data.frame.
#' @param dayfirst Passed to \code{\link{nm_parse_dates}}.
#' @return `df` with its times parsed into a first column `date` (POSIXct, UTC) and the
#'   columns they came from dropped; attribute `"normet_dates"` says how they were found
#'   and read. Stops, in words for the user, where no column reads as times.
#' @export
nm_find_dates <- function(df, dayfirst = NULL) {
  f <- .find_dates(df, dayfirst = dayfirst)
  out <- f$df
  attr(out, "normet_dates") <- f$how
  out
}

.utc_zone <- function(zone) is.null(zone) || !nzchar(zone) || toupper(zone) %in% c("UTC", "GMT")

# The clock reading in `zone` of UTC instants (numeric seconds), as seconds labelled UTC.
.instant_to_clock <- function(seconds, zone) {
  if (.utc_zone(zone)) return(seconds)
  t <- .as_utc_posixct(seconds)
  lt <- as.POSIXlt(t, tz = zone)
  off <- lt$gmtoff
  if (is.null(off) || anyNA(off[!is.na(seconds)])) {
    wall <- format(t, "%Y-%m-%d %H:%M:%OS6", tz = zone)
    return(as.numeric(as.POSIXct(wall, format = "%Y-%m-%d %H:%M:%OS", tz = "UTC")))
  }
  seconds + off
}

#' Times on one clock: a table's own (local time) or UTC
#'
#' `nm_on_clock()` puts times on `zone`'s clock (an IANA name: `"Asia/Shanghai"`,
#' `"Europe/London"`; `NULL` for UTC), as POSIXct labelled `"UTC"` whose reading is that
#' clock's -- the form normet's models and figures read the hour and weekday from. Times
#' written with their own offset (text with `+01:00` or `Z`, or a POSIXct in another time
#' zone) are converted to it; times without one (text without an offset, a POSIXct in
#' UTC or without a time zone) are taken to be on it already, and left as they read.
#'
#' `nm_clock_to_utc()` goes from that clock to UTC: what HYSPLIT, ERA5 and Open-Meteo are
#' asked for. An hour a change to summer time skips is moved forward to the change; one
#' it repeats is taken in order (its first occurrence before its second).
#'
#' `nm_utc_to_clock()` goes from UTC to `zone`'s clock: meteorology and trajectories
#' fetched on UTC, joined to a table kept on local time. Times without an offset are
#' taken as UTC.
#'
#' @param dates Times: POSIXct, Date, or anything \code{\link{nm_parse_dates}} reads.
#' @param zone An IANA time-zone name, or `NULL`/`"UTC"`.
#' @return A POSIXct vector labelled `"UTC"`.
#' @examples
#' x <- c("2020-07-01T07:00+01:00", "2020-01-01T07:00Z")
#' nm_on_clock(x, "Europe/London")
#' nm_clock_to_utc(as.POSIXct("2020-07-01 07:00", tz = "UTC"), "Europe/London")
#' @export
nm_on_clock <- function(dates, zone = NULL) {
  p <- .parse_any_times(dates)
  out <- p$time
  if (any(p$aware)) {
    out[p$aware] <- .instant_to_clock(p$time[p$aware], if (.utc_zone(zone)) "UTC" else zone)
  }
  if (inherits(dates, "POSIXt") && !any(p$aware)) {
    tz <- attr(as.POSIXct(dates), "tzone")
    if (is.null(tz) || !length(tz) || !nzchar(tz[1])) {
      # A POSIXct without a time zone reads on the session's clock: keep that reading.
      wall <- format(as.POSIXct(dates), "%Y-%m-%d %H:%M:%OS6")
      out <- as.numeric(as.POSIXct(wall, format = "%Y-%m-%d %H:%M:%OS", tz = "UTC"))
    }
  }
  .as_utc_posixct(out)
}

#' @rdname nm_on_clock
#' @export
nm_clock_to_utc <- function(dates, zone = NULL) {
  w <- as.numeric(nm_on_clock(dates, zone))
  if (.utc_zone(zone)) return(.as_utc_posixct(w))
  # Candidate instants from the offsets either side of the clock reading.
  off_before <- .instant_to_clock(w - 86400, zone) - (w - 86400)
  off_after <- .instant_to_clock(w + 86400, zone) - (w + 86400)
  c1 <- w - off_before
  c2 <- w - off_after
  ok1 <- !is.na(w) & .instant_to_clock(c1, zone) == w
  ok2 <- !is.na(w) & .instant_to_clock(c2, zone) == w
  out <- ifelse(ok1, c1, ifelse(ok2, c2, NA_real_))
  # A repeated hour (both valid): the first occurrence of the reading takes the earlier
  # instant, a second occurrence the later.
  amb <- which(ok1 & ok2 & c1 != c2)
  if (length(amb)) {
    seen <- stats::ave(seq_along(w), w, FUN = seq_along)
    lo <- pmin(c1, c2)
    hi <- pmax(c1, c2)
    out[amb] <- ifelse(seen[amb] >= 2, hi[amb], lo[amb])
  }
  # A skipped hour (neither valid): forward to the change, found by bisection.
  gap <- which(!is.na(w) & !ok1 & !ok2)
  for (i in gap) {
    lo <- min(c1[i], c2[i])
    hi <- max(c1[i], c2[i])
    off_lo <- .instant_to_clock(lo, zone) - lo
    for (k in seq_len(40)) {
      mid <- (lo + hi) / 2
      if (.instant_to_clock(mid, zone) - mid == off_lo) lo <- mid else hi <- mid
      if (hi - lo < 0.5) break
    }
    out[i] <- round(hi)
  }
  .as_utc_posixct(out)
}

#' @rdname nm_on_clock
#' @export
nm_utc_to_clock <- function(dates, zone = NULL) {
  p <- .parse_any_times(dates)
  .as_utc_posixct(.instant_to_clock(p$time, if (.utc_zone(zone)) "UTC" else zone))
}

#' Read a table file as a time series on its own clock
#'
#' \code{\link{nm_read_table}}, then \code{\link{nm_find_dates}}, then
#' \code{\link{nm_on_clock}}: the file's times in a first column `date`, on `zone`'s
#' clock (the site's local time, or UTC).
#'
#' @param path Path to a table file (see \code{\link{nm_table_suffixes}}).
#' @param zone IANA time-zone name of the clock to keep, or `NULL` for UTC.
#' @param dayfirst Passed to \code{\link{nm_parse_dates}}.
#' @return A data.frame; attribute `"normet_dates"` says how the times were found and
#'   read, `"normet_zone"` the clock.
#' @examples
#' f <- tempfile(fileext = ".csv")
#' writeLines(c("Date;NO2", "31.01.2020 13:00;12,5", "01.02.2020 14:00;9,0"), f)
#' nm_read_time_series(f)
#' @export
nm_read_time_series <- function(path, zone = NULL, dayfirst = NULL) {
  f <- .find_dates(nm_read_table(path), dayfirst = dayfirst)
  df <- f$df
  how <- f$how
  clock <- if (.utc_zone(zone)) "UTC" else zone
  t <- as.numeric(df$date)
  if (any(f$aware)) {
    how <- paste0(how, " ", .DOT, " UTC offsets put on ", clock)
    t[f$aware] <- .instant_to_clock(t[f$aware], clock)
  }
  df$date <- .as_utc_posixct(t)
  attr(df, "normet_dates") <- how
  attr(df, "normet_zone") <- clock
  df
}
