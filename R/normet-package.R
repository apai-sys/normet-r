#' @details
#' `normet` brings three layers together behind one API:
#'
#' 1. **Weather normalisation.** [nm_do_all()] and [nm_normalise()] train a
#'    LightGBM or H2O model of the pollutant on weather and time, then
#'    resample the meteorology many times to remove its contribution and
#'    reveal the emission-driven signal.
#' 2. **Decomposition and uncertainty.** [nm_decompose()] splits a series
#'    into its emission- and meteorology-driven parts;
#'    [nm_decompose_uncertainty()] attributes the spread of a de-weathered
#'    estimate to weather, model form and their interaction;
#'    [nm_rolling()] and [nm_trend()] follow the emission-driven signal over
#'    time.
#' 3. **Causal inference.** [nm_run_scm()] and [nm_run_scm_staggered()] build
#'    synthetic controls from untreated donor units, with placebo tests and
#'    uncertainty bands.
#'
#' Data adapters ([nm_read_table()], [nm_fetch_ukaq_measurements()],
#' [nm_fetch_era5_timeseries()]) and transport features
#' ([nm_build_trajectory_features()]) feed the pipelines, while
#' [nm_make_run()] and [nm_generate_html()] record and report them.
#'
#' @seealso
#' * [nm_do_all()] for the end-to-end pipeline.
#' * `vignette("normet", package = "normet")` for the getting-started guide.
#' * <https://github.com/apai-sys/normet-r/tree/main/docs> for the user guide.
#' @keywords internal
"_PACKAGE"
