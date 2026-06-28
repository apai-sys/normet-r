# Input Validation Utilities
#
# Ported from Python normet utils/validate.py
# Centralises common data frame boundary checks so analysis functions don't
# reinvent the same guards. All checks signal an "nm_data_error" condition
# (see nm_exceptions.r) on failure.

NULL

#' Require a Column to Exist in a Data Frame
#'
#' @param df A data frame.
#' @param col Character. Column name expected in \code{df}.
#' @param label Character. Human-readable label for \code{col} used in the
#'   error message (e.g. \code{"date column"}). Default \code{"column"}.
#'
#' @return Invisibly \code{TRUE} if \code{col} is present; otherwise signals
#'   an \code{"nm_data_error"} condition via [nm_error_data()].
#' @export
nm_require_column <- function(df, col, label = "column") {
  if (!col %in% names(df)) {
    label_cap <- paste0(toupper(substring(label, 1, 1)), substring(label, 2))
    nm_error_data(sprintf(
      "%s '%s' not found in data frame. Available columns: %s",
      label_cap, col, paste(names(df), collapse = ", ")
    ))
  }
  invisible(TRUE)
}

#' Require a Data Frame to be Non-Empty
#'
#' @param df A data frame.
#' @param label Character. Human-readable label for \code{df} used in the
#'   error message. Default \code{"data frame"}.
#'
#' @return Invisibly \code{TRUE} if \code{df} has at least one row; otherwise
#'   signals an \code{"nm_data_error"} condition via [nm_error_data()].
#' @export
nm_require_not_empty <- function(df, label = "data frame") {
  if (nrow(df) == 0) {
    label_cap <- paste0(toupper(substring(label, 1, 1)), substring(label, 2))
    nm_error_data(sprintf("%s is empty (0 rows).", label_cap))
  }
  invisible(TRUE)
}

#' Require Columns to Contain No Missing Values
#'
#' @param df A data frame.
#' @param columns Character vector of column names to check. Names absent
#'   from \code{df} are silently skipped.
#'
#' @return Invisibly \code{TRUE} if none of \code{columns} contain \code{NA};
#'   otherwise signals an \code{"nm_data_error"} condition via [nm_error_data()].
#' @export
nm_require_no_nan_in <- function(df, columns) {
  present <- intersect(columns, names(df))
  bad <- present[vapply(present, function(col) anyNA(df[[col]]), logical(1))]
  if (length(bad) > 0) {
    nm_error_data(sprintf(
      "Column(s) %s contain NA values. Use nm_impute_values() or na.omit() before calling this function.",
      paste(sort(bad), collapse = ", ")
    ))
  }
  invisible(TRUE)
}

#' Require a Column to Contain No Duplicate Values
#'
#' @param df A data frame.
#' @param col Character. Column name to check for duplicates. If absent from
#'   \code{df}, the check is skipped.
#'
#' @return Invisibly \code{TRUE} if \code{col} contains no duplicates;
#'   otherwise signals an \code{"nm_data_error"} condition via [nm_error_data()].
#' @export
nm_require_no_duplicates <- function(df, col) {
  if (col %in% names(df) && anyDuplicated(df[[col]]) > 0) {
    nm_error_data(sprintf(
      "Column '%s' contains duplicate values. Remove duplicates before calling this function.",
      col
    ))
  }
  invisible(TRUE)
}
