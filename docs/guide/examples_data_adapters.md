# Data adapters

`normet` includes built-in adapters that pull air-quality observations and
meteorological datasets from open platforms and return long-format data frames
ready for analysis.

## Your own tables

`nm_read_table()` reads CSV/TSV (any separator, decimal commas, common
encodings, gzipped), Excel, Parquet, Feather and JSON (Excel needs `readxl`,
Parquet/Feather need `arrow`). `nm_read_time_series()` does the same and puts
the times on a site's clock:

```r
df <- nm_read_time_series("site.csv", zone = "Europe/London")
attr(df, "normet_dates")               # how the times were found and read
attr(df, "normet_zone")                # the clock

nm_clock_to_utc(df$date, "Europe/London")   # what ERA5/HYSPLIT are asked for
nm_parse_dates(c("2020-03-29T00:30+00:00", "2020-03-29T02:30+01:00"))
```

Times in any common layout or format are accepted; a daylight-saving gap is
handled rather than silently shifting the series.

## UK air-quality networks (AURN, AQE, SAQN, WAQN, NI, LMAM)

`nm_ukaq_sources` lists the six networks. Each is read from whole-year
archives; `source = "aurn_live"` instead uses the DEFRA SOS API's rolling
recent window (AURN only, near-real-time).

```r
# Browse available stations
stations <- nm_list_ukaq_stations("aurn", pollutant = "NO2")
head(stations)

# Download hourly measurements (whole calendar years)
df_aurn <- nm_fetch_ukaq_measurements("MY1", 2022, source = "aurn",
                                        pollutant = "NO2")

# Or the near-real-time rolling window
df_live <- nm_fetch_ukaq_measurements("MY1", 2026, source = "aurn_live",
                                        pollutant = "NO2")
```

`nm_list_ukaq_stations(source, pollutant, site_type, all_variables)` filters
by the species a station measures and its classification (`"Urban Traffic"`,
...); `all_variables = TRUE` returns the raw station-species metadata, which
tells you which species each station reports and over what period.

`nm_fetch_ukaq_measurements()` returns a wide frame, one row per hour per
station: `date` (UTC POSIXct), `code`, `site`, one column per measured
species, `network`, and with `meta = TRUE` also `site_type`, `latitude` and
`longitude`. Pass any of the archive's own column names as `pollutant`, e.g.
`"NOXasNO2"` for NOx (not `"NOX"`); the same names work for
`source = "aurn_live"`.

## EEA (European Environment Agency)

`nm_fetch_eea_data()` queries the EEA Discomap service's CSV endpoints and
concatenates the response into one tidy frame:

```r
df_eea <- nm_fetch_eea_data(
  country    = "GB",
  pollutant  = "PM2.5",       # or an EIONET code; see nm_eea_pollutant_codes
  year_from  = 2021,
  year_to    = 2022,
  station    = NULL           # or a specific station code
)
```

No account or key is needed; `nm_eea_pollutant_codes` maps names to codes.

## OpenAQ (global air quality)

Get a free API key at <https://explore.openaq.org/register>, then set the
`OPENAQ_API_KEY` environment variable or pass `api_key =` directly.

```r
library(normet)

# Discover monitoring locations in a bounding box
locs <- nm_openaq_locations(
  country   = "GB",
  city      = "London",
  bbox      = c(-0.5, 51.3, 0.2, 51.7),   # min lon, min lat, max lon, max lat
  parameter = "pm25",
  limit     = 10
)
head(locs[, c("id", "name", "lat", "lon")])

# Active sensors at one location
sensors <- nm_openaq_sensors(location_id = locs$id[1])

# Historical hourly measurements
aq <- nm_fetch_openaq_measurements(
  location_id = locs$id[1],
  parameter   = "pm25",
  date_from   = "2024-01-01",
  date_to     = "2024-01-07"
)
# columns: date (UTC), site, parameter, value, unit, lat, lon
```

## ERA5 (Copernicus CDS)

`nm_fetch_era5_timeseries()` queries the CDS
`reanalysis-era5-single-levels-timeseries` dataset, which returns
pre-interpolated single-point CSVs per site — no gridded NetCDF and no extra
gridded-reader dependency.

Prerequisites: a free Copernicus CDS account, its key stored with
`ecmwfr::wf_set_key()`, and the `ecmwfr` package.

```r
# sites: a data frame (site, lat, lon) or a named list of c(lat, lon)
df_met <- nm_fetch_era5_timeseries(
  sites     = data.frame(site = "MY1", lat = 51.52, lon = -0.15),
  date_from = "2022-01-01",
  date_to   = "2022-12-31",
  variables = nm_era5_aq_variables_default,
  cache_dir = ".era5_cache"      # reuse downloaded CSVs
)
# columns use short names: site, date, lat, lon, t2m, u10, v10, ...
```

The response always uses **short** variable names (`t2m`, `u10`, `v10`,
`d2m`, `sp`, `blh`, `tcc`, `tp`, `ssrd`) regardless of the long CDS names
requested; use those short names downstream.

## Open-Meteo (keyless ERA5-derived meteorology)

Open-Meteo serves ERA5-derived hourly weather over HTTP with no account or API
key.

```r
met <- nm_fetch_openmeteo_timeseries(
  sites     = list(MY1 = c(51.52, -0.15)),   # name = c(lat, lon)
  date_from = "2022-01-01",
  date_to   = "2022-12-31"
)
# columns: site, date, t2m, d2m, rh2m, sp, tcc, tp, ssrd, u10, v10, blh, lat, lon
```

The names and units are the same as `nm_fetch_era5_timeseries()` returns. The
archive lags real time by a few days, so recent hours come back as `NA`. Data
by Open-Meteo.com (CC BY 4.0), based on Copernicus ERA5.

## HYSPLIT back-trajectories

Same-timestamp meteorology ignores where the air *came from*. The trajectory
adapter turns HYSPLIT back-trajectory output into per-receptor transport
features (inflow direction, transport distance/speed, trajectory height,
along-path rainfall/boundary-layer height, and residence-time fractions over
source regions) that you can feed to the models as extra predictors.

If you already have `tdump` files (from `pysplit`, `splitr`, or `hyts_std`),
feed them to `nm_build_trajectory_features()`:

```r
library(normet)

# 1. Reduce tdump files to a receptor-time feature table
traj <- nm_build_trajectory_features(
  "traj/tdump_*",
  source_regions = list(
    # name = c(lon_min, lat_min, lon_max, lat_max)
    industrial_NE = c(116.0, 39.0, 120.0, 42.0),
    marine_SW     = c(-12.0, 45.0, -2.0, 52.0)
  )
)
# traj has a `date` (receptor time) column and traj_* feature columns:
# traj_dist_km, traj_pathlen_km, traj_speed_kmh, traj_inflow_deg,
# traj_height_mean, traj_height_min, traj_resid_<region>, plus - only if the
# tdump run wrote them - traj_rain_sum, traj_blh_mean, traj_rh_mean,
# traj_pressure_mean, traj_temp_mean

# 2. Join onto the AQ + local-met panel: each row takes the latest trajectory
#    to have arrived, within one release interval. With a 'site' column in
#    both, each site takes its own.
panel <- nm_join_trajectory_features(panel, traj)

# 3. Use them as transport-aware predictors. Because they are
#    transport/meteorology, list them in resample_vars too, so the
#    Monte-Carlo normalisation deweathers them along with local met.
traj_feats <- grep("^traj_", names(panel), value = TRUE)
local_met  <- c("t2m", "blh", "u10", "v10", "ssrd", "tp")

results <- nm_do_all(
  df            = panel,
  target        = "PM2.5",
  backend       = "lightgbm",
  covariates    = c(local_met, traj_feats,
                    "date_unix", "day_julian", "weekday", "hour"),
  resample_vars = c(local_met, traj_feats),
  n_samples     = 300
)
```

To **keep** the transport signal and normalise only local weather, leave
`traj_*` out of `resample_vars` (they stay fixed at observed values).

A run that starts trajectories at several heights gives each height its own
columns (`traj_dist_km_100m`, `traj_dist_km_500m`, ...). A feature table is
one receptor's: `nm_build_trajectory_features()` refuses tdumps that start
from different places, so build each site on its own, tag it with a `site`
column, and join the sites one after another — each join fills only its own
site's rows.

For exact residence time over concave or multi-part boundaries, pass polygons
instead of bounding boxes: `nm_load_source_regions(path)` reads a GeoJSON,
Shapefile or GeoPackage with `sf` and returns one named geometry per feature,
ready for `source_regions`. Lower-level helpers are also exported:
`nm_read_trajectory_tdump(path)` parses a single `tdump` file, and
`nm_trajectory_features(traj, ...)` reduces one trajectory to its feature
list.

### Downloading GDAS1 met (when you have none)

HYSPLIT needs ARL-format meteorology. If you don't have it locally,
`nm_fetch_gdas1()` pulls the weekly GDAS1 (1°) files from NOAA ARL's archive
and caches them (each is ~570 MB, so existing files are never re-fetched):

```r
# Cover the full BACKWARD window: earliest receptor minus hours_back
met <- nm_fetch_gdas1(
  date_from = "2020-04-01", date_to = "2020-04-30",
  cache_dir = ".gdas_cache"
)
# -> c(".../gdas1.apr20.w1", ".../gdas1.apr20.w2", ...)   (chronological)
```

`nm_gdas1_filenames(date_from, date_to)` returns the same filenames without
downloading, if you just want to see what is needed.

### Running HYSPLIT end-to-end

With a built `hyts_std` and met files, `nm_run_back_trajectories()` does the
whole loop — writes a `CONTROL` per receptor time, runs HYSPLIT, and reduces
the output to the feature table:

```r
met <- nm_fetch_gdas1("2020-04-01", "2020-04-30", cache_dir = ".gdas_cache")

traj <- nm_run_back_trajectories(
  times        = my1$date,          # receptor (arrival) times, run in UTC
  lat = 51.52, lon = -0.15,
  met_files    = met,
  hysplit_exec = "~/hysplit-5.4.2/exec/hyts_std",
  hours_back   = 72,
  min_hours    = 72,                 # null trajectories HYSPLIT cut short
  source_regions = list(industrial_NE = c(116.0, 39.0, 120.0, 42.0))
)
panel <- nm_join_trajectory_features(panel, traj)   # then pass traj_* to nm_do_all
```

**macOS:** HYSPLIT ships `x86_64` binaries via a disk image (run under Rosetta
on Apple Silicon), so they carry a Gatekeeper quarantine flag. If `hyts_std`
is killed (exit 137), clear it once:
`xattr -dr com.apple.quarantine /path/to/hysplit`.

See the worked [OpenAQ + ERA5 example](examples_openaq.md) for a complete
download-and-normalise recipe.
