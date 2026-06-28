#' Predict using a trained model
#'
#' \code{nm_predict} is a high-level wrapper that generates predictions from a trained model.
#' It automatically identifies the model's backend (e.g., H2O) and dispatches to the
#' appropriate prediction function.
#'
#' @param model The trained model object.
#' @param newdata A data frame or data.table containing the new data for prediction.
#' @param verbose Logical. Should the function print log messages? Default is FALSE.
#' @param ... Additional arguments to be passed to the backend-specific function.
#'
#' @return A numeric vector of predicted values.
#'
#' @examples
#' \donttest{
#' if (requireNamespace("lightgbm", quietly = TRUE)) {
#'   covariates <- c("u10", "v10", "d2m", "t2m", "blh", "ssrd")
#'   predictors <- c(covariates, "date_unix", "day_julian", "weekday", "hour")
#'   build <- nm_build_model(
#'     my1[1:150, c("date", "NO2", covariates)],
#'     value = "NO2", predictors = predictors,
#'     model_config = list(n_trials = 1, cv_folds = 2, nrounds = 15,
#'                          num_leaves_min = 5, num_leaves_max = 15),
#'     seed = 42, verbose = FALSE
#'   )
#'   preds <- nm_predict(build$model, build$df_prep)
#'   head(preds)
#' }
#' }
#'
#' @export
nm_predict <- function(model, newdata, verbose = FALSE, ...) {

  log <- nm_get_logger("model.predict")

  # 1. robust backend detection
  model_backend <- attr(model, "backend")

  # Fallback: if attribute is missing, check object class
  if (is.null(model_backend)) {
    if (inherits(model, "H2OModel")) {
      model_backend <- "h2o"
    }
  }

  # 2. Dispatch
  if (!is.null(model_backend) && startsWith(model_backend, "h2o")) {
    if (verbose) log$info("Dispatching to H2O backend for prediction.")
    return(nm_predict_h2o(model = model, newdata = newdata, verbose = verbose, ...))

  } else if (!is.null(model_backend) && model_backend == "lightgbm") {
    if (verbose) log$info("Dispatching to lightgbm backend for prediction.")
    return(nm_predict_lgb(model = model, newdata = newdata))

  } else {
    if (verbose) log$info("Using generic stats::predict().")
    return(as.numeric(stats::predict(model, newdata)))
  }
}
