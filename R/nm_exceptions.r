# Structured Conditions
#
# Ported from Python normet exceptions.py
# Provides classed error/warning conditions so callers can catch specific
# normet failure modes, e.g. tryCatch(expr, nm_data_error = function(e) ...).

NULL

#' Signal a normet Error
#'
#' Base constructor for normet's classed error conditions. Most callers
#' should use the more specific [nm_error_data()], [nm_error_model()], or
#' [nm_error_config()] instead.
#'
#' @param message Character. The error message.
#' @param class Character vector of additional condition classes to prepend
#'   (e.g. \code{"nm_data_error"}). Always inherits from \code{"nm_error"}.
#' @param ... Additional data fields stored on the condition object, passed
#'   through to [rlang::abort()].
#'
#' @return Does not return; signals a condition via [rlang::abort()].
#' @export
nm_error <- function(message, class = NULL, ...) {
  rlang::abort(message, class = c(class, "nm_error"), call = NULL, ...)
}

#' @describeIn nm_error Signal an invalid, missing, or malformed input data error.
#' @export
nm_error_data <- function(message, ...) {
  nm_error(message, class = "nm_data_error", ...)
}

#' @describeIn nm_error Signal a model training, prediction, or persistence failure.
#' @export
nm_error_model <- function(message, ...) {
  nm_error(message, class = "nm_model_error", ...)
}

#' @describeIn nm_error Signal an invalid configuration or missing required parameter.
#' @export
nm_error_config <- function(message, ...) {
  nm_error(message, class = "nm_config_error", ...)
}

#' Warn About an Experimental Feature
#'
#' Signals a classed warning (\code{"nm_experimental_warning"}) so it can be
#' selectively suppressed, e.g.
#' \code{withCallingHandlers(expr, nm_experimental_warning = function(w) invokeRestart("muffleWarning"))}.
#'
#' @param message Character. The warning message.
#' @param ... Additional data fields stored on the condition object, passed
#'   through to [rlang::warn()].
#'
#' @return Invisibly \code{NULL}; signals a warning via [rlang::warn()].
#' @export
nm_warn_experimental <- function(message, ...) {
  rlang::warn(message, class = "nm_experimental_warning", ...)
  invisible(NULL)
}
