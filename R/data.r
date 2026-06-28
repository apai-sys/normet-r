#' Synthetic hourly air quality and meteorology dataset (MY1-style)
#'
#' A synthetic hourly dataset modelled on the MY1 (London Marylebone Road)
#' monitoring station, covering the full year 2020 (8 784 rows).  It contains
#' realistic seasonal and diurnal patterns for pollutant concentrations and
#' ERA5 meteorological variables, generated with a fixed random seed so results
#' are fully reproducible.  The column names and units match the original MY1
#' station data so that existing code requires no changes.
#'
#' @format A data frame with 8 784 rows and 66 variables:
#' \describe{
#'   \item{date}{POSIXct timestamp (UTC), hourly from 2020-01-01 00:00 to
#'     2020-12-31 23:00.}
#'   \item{O3, NO, NO2, NOXasNO2, SO2, CO}{Criteria pollutant concentrations
#'     (\eqn{\mu g/m^3} or ppb depending on species).}
#'   \item{PM10, NV10, V10, PM2.5, NV2.5, V2.5}{Particulate matter fractions
#'     (\eqn{\mu g/m^3}).}
#'   \item{ETHANE, ETHENE, \ldots, 135TMB}{Volatile organic compound
#'     concentrations (\eqn{\mu g/m^3}).}
#'   \item{wd, ws, temp}{Surface wind direction (degrees), wind speed (m/s),
#'     and temperature (°C).}
#'   \item{AT10, AP10, AT2.5, AP2.5}{Auxiliary PM fractions for PM10 and
#'     PM2.5.}
#'   \item{site, code, latitude, longitude, location_type, lat, lon}{Station
#'     metadata.}
#'   \item{Ox, NOx}{Derived oxidant and NOx concentrations.}
#'   \item{u10, v10}{ERA5 10-metre wind components (m/s).}
#'   \item{d2m, t2m}{ERA5 2-metre dewpoint and temperature (K).}
#'   \item{blh}{ERA5 boundary-layer height (m).}
#'   \item{sp}{ERA5 surface pressure (Pa).}
#'   \item{ssrd}{ERA5 surface solar radiation downwards (J/m²).}
#'   \item{tcc}{ERA5 total cloud cover (0–1).}
#'   \item{tp}{ERA5 total precipitation (m).}
#'   \item{rh2m}{Relative humidity at 2 m (\%).}
#' }
#' @source Synthetically generated via \code{data-raw/generate.R}.
"my1"

#' Synthetic weekly air quality panel for Synthetic Control Method examples
#'
#' A synthetic weekly panel dataset covering one treated unit
#' (\code{"2+26 cities"}) and 37 donor cities from 2015-05-03 to 2016-04-24
#' (1 976 rows, 52 weeks × 38 units).  The treated unit shows a
#' \eqn{\approx 35\%} step-down reduction in \code{SO2wn} starting
#' 2015-10-23, representing a simulated policy intervention.  All other
#' pollutant columns are generated with realistic correlations to
#' \code{SO2wn}.
#'
#' @format A data frame with 1 976 rows and 19 variables:
#' \describe{
#'   \item{date}{Date of the weekly observation (Sunday of each week).}
#'   \item{ID}{Unit identifier: \code{"2+26 cities"} (treated) or one of 37
#'     donor city names.}
#'   \item{CO, COwn}{Carbon monoxide concentration and its weather-normalised
#'     counterpart (mg/m³).}
#'   \item{NO2, NO2wn}{Nitrogen dioxide and weather-normalised NO2
#'     (\eqn{\mu g/m^3}).}
#'   \item{O3, O3_8h, O3_8hwn, O3wn}{Ozone (hourly and 8-hour averages, raw
#'     and weather-normalised, \eqn{\mu g/m^3}).}
#'   \item{Ox, Oxwn}{Oxidant (O3 + NO2) and weather-normalised oxidant
#'     (\eqn{\mu g/m^3}).}
#'   \item{PM10, PM10wn, PM2.5, PM2.5wn}{Particulate matter and
#'     weather-normalised counterparts (\eqn{\mu g/m^3}).}
#'   \item{SO2, SO2wn}{Sulphur dioxide and weather-normalised SO2
#'     (\eqn{\mu g/m^3}).  \code{SO2wn} is the primary outcome used in SCM
#'     examples.}
#'   \item{group}{\code{"target"} for the treated unit; \code{"control"} for
#'     all donor cities.}
#' }
#' @source Synthetically generated via \code{data-raw/generate.R}.
"scm"
