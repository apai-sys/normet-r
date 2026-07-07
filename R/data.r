#' Hourly NO2 and meteorology at London Marylebone Road (MY1), Jan-Aug 2020
#'
#' Real hourly nitrogen-dioxide observations from the UK AURN monitoring
#' station at London Marylebone Road (MY1, kerbside), merged with ERA5
#' single-level meteorology, covering 2020-01-01 to 2020-08-31.  This is the
#' deweathering case-study dataset from the normet model-description paper:
#' the window spans the UK COVID-19 lockdown (from 2020-03-23), making it a
#' compact real-world example of meteorological normalisation revealing an
#' emission-driven change.
#'
#' @format A data frame with 5 793 rows and 11 variables:
#' \describe{
#'   \item{date}{POSIXct timestamp (UTC), hourly.}
#'   \item{NO2}{Nitrogen dioxide concentration (\eqn{\mu g/m^3}), AURN.}
#'   \item{ws, wd}{ERA5-derived 10-metre wind speed (m/s) and direction
#'     (degrees).}
#'   \item{temp}{ERA5 2-metre air temperature (°C).}
#'   \item{RH}{Relative humidity at 2 m (%).}
#'   \item{atmos_pres}{ERA5 surface pressure (Pa).}
#'   \item{blh}{ERA5 boundary-layer height (m).}
#'   \item{tcc}{ERA5 total cloud cover (0-1).}
#'   \item{tp}{ERA5 total precipitation (m).}
#'   \item{ssrd}{ERA5 surface solar radiation downwards (J/m²).}
#' }
#' @source UK AURN (Defra, Open Government Licence v3.0); ERA5 (Copernicus
#'   Climate Change Service).  Prepared by
#'   \code{data-raw/prepare_case_data.R}.
"my1"

#' Monthly deweathered NO2 panel for UK sites (ULEZ SCM case study)
#'
#' A real monthly panel of observed and weather-normalised (deweathered) NO2
#' for 104 UK AURN monitoring sites from 2016-01 to 2021-12, used in the
#' normet paper's Synthetic Control case study of the London Ultra Low
#' Emission Zone (ULEZ, launched 2019-04-08).  The London kerbside site MY1
#' is the treated unit; non-London sites of matching type form the donor
#' pool.  Deweathering removes meteorological variability so that the SCM
#' compares emission-driven signals.
#'
#' @format A data frame with 7 378 rows and 6 variables:
#' \describe{
#'   \item{date}{Date, last day of each month.}
#'   \item{NO2_obs}{Observed monthly-mean NO2 (\eqn{\mu g/m^3}).}
#'   \item{NO2_dw}{Deweathered monthly-mean NO2 (\eqn{\mu g/m^3}), from a
#'     per-site model.}
#'   \item{NO2_dw_common}{Deweathered NO2 using a common covariate set
#'     across sites (\eqn{\mu g/m^3}).}
#'   \item{code}{AURN site code (e.g. \code{"MY1"} = London Marylebone
#'     Road, the ULEZ-treated unit).}
#'   \item{type}{Site classification (e.g. \code{"Urban Traffic"},
#'     \code{"Urban Background"}, London variants thereof).}
#' }
#' @source UK AURN (Defra, Open Government Licence v3.0); ERA5 (Copernicus
#'   Climate Change Service).  Prepared by
#'   \code{data-raw/prepare_case_data.R}.
"scm"

#' Hourly PM2.5 and meteorology at MY1 for transport-aware normalisation
#'
#' Real hourly PM2.5 observations at London Marylebone Road (MY1) with
#' observed and ERA5 meteorology, 2020-01-01 to 2020-08-31.  Companion
#' dataset to \code{\link{traj_my1}} for the transport-aware normalisation
#' case study: augmenting the meteorological predictors with back-trajectory
#' features lets the normalisation also marginalise over long-range
#' transport.
#'
#' @format A data frame with 5 856 rows and 17 variables:
#' \describe{
#'   \item{date}{POSIXct timestamp (UTC), hourly.}
#'   \item{pm25}{PM2.5 concentration (\eqn{\mu g/m^3}), AURN.}
#'   \item{ws, wd, temp}{Observed wind speed (m/s), wind direction
#'     (degrees), and temperature (°C) at the station.}
#'   \item{u10, v10}{ERA5 10-metre wind components (m/s).}
#'   \item{d2m, t2m}{ERA5 2-metre dewpoint and temperature (K).}
#'   \item{blh}{ERA5 boundary-layer height (m).}
#'   \item{sp}{ERA5 surface pressure (Pa).}
#'   \item{ssrd}{ERA5 surface solar radiation downwards (J/m²).}
#'   \item{tcc}{ERA5 total cloud cover (0-1).}
#'   \item{tp}{ERA5 total precipitation (m).}
#'   \item{ws_era5, wd_era5}{Wind speed and direction derived from the ERA5
#'     \code{u10}/\code{v10} components.}
#'   \item{temp_era5}{ERA5 2-metre temperature converted to °C.}
#' }
#' @source UK AURN (Defra, Open Government Licence v3.0); ERA5 (Copernicus
#'   Climate Change Service).  Prepared by
#'   \code{data-raw/prepare_case_data.R}.
"my1_pm25"

#' HYSPLIT back-trajectory features arriving at MY1, Jan-Aug 2020
#'
#' Summary features of 72-hour HYSPLIT back-trajectories arriving at London
#' Marylebone Road (MY1) every 6 hours from 2020-01-01 to 2020-08-31,
#' driven by GDAS 1° meteorology.  Combined with \code{\link{my1_pm25}} in
#' the transport-aware normalisation case study.  A two-day sample of the
#' raw HYSPLIT tdump output that these features were derived from is shipped
#' in \code{system.file("extdata", "traj", package = "normet")} for the
#' trajectory-reader examples.
#'
#' @format A data frame with 976 rows and 12 variables:
#' \describe{
#'   \item{date}{POSIXct arrival time (UTC), 6-hourly.}
#'   \item{traj_dist_km}{Great-circle distance from trajectory origin to
#'     receptor (km).}
#'   \item{traj_pathlen_km}{Along-path trajectory length (km).}
#'   \item{traj_speed_kmh}{Mean transport speed (km/h).}
#'   \item{traj_inflow_deg}{Mean inflow bearing at the receptor (degrees).}
#'   \item{traj_height_mean, traj_height_min}{Mean and minimum trajectory
#'     height above ground (m).}
#'   \item{traj_resid_continent, traj_resid_northsea, traj_resid_atlantic,
#'     traj_resid_uk_north, traj_resid_uk_south}{Fraction of trajectory
#'     hours resident over each source region (0-1).}
#' }
#' @source HYSPLIT (NOAA ARL) back-trajectories driven by GDAS 1°
#'   meteorology.  Prepared by \code{data-raw/prepare_case_data.R}.
"traj_my1"
