# Example: real-world weather normalisation with OpenAQ and ERA5

This recipe demonstrates the end-to-end workflow of pulling ground-level air
quality observations from **OpenAQ**, fetching the corresponding meteorology
from **ERA5** (Copernicus CDS), compiling them into a long-format panel, and
performing weather normalisation.

## 1. Setup and credentials

You need:

1. An **OpenAQ API key** — a free key at <https://explore.openaq.org/register>.
2. A **Copernicus CDS account**, with the key stored through `ecmwfr` and the
   `ecmwfr` package installed (see [Data adapters](examples_data_adapters.md)).

```r
Sys.setenv(OPENAQ_API_KEY = "your_openaq_api_key_here")

library(normet)
```

## 2. Discover locations and active sensors

```r
# Search for PM2.5 monitoring stations in London
locs <- nm_openaq_locations(
  country   = "GB",
  city      = "London",
  bbox      = c(-0.5, 51.3, 0.2, 51.7),
  parameter = "pm25",
  limit     = 5
)
print(locs[, c("id", "name", "lat", "lon")])

target_id <- locs$id[1]
sensors <- nm_openaq_sensors(location_id = target_id)
print(sensors[, c("id", "name", "parameter_name", "parameter_units")])
```

## 3. Fetch historical hourly measurements

```r
aq <- nm_fetch_openaq_measurements(
  location_id = target_id,
  parameter   = "pm25",
  date_from   = "2024-01-01",
  date_to     = "2024-01-07"
)
# columns: date, site, parameter, value, unit, lat, lon
head(aq)
```

## 4. Fetch the corresponding ERA5 meteorology

`nm_fetch_era5_timeseries()` pulls pre-interpolated single-point time-series
straight from the CDS — no gridded NetCDF needed.

```r
sites <- data.frame(
  site = aq$site[1],
  lat  = aq$lat[1],
  lon  = aq$lon[1]
)

df_met <- nm_fetch_era5_timeseries(
  sites     = sites,
  date_from = "2024-01-01",
  date_to   = "2024-01-07",
  variables = c("2m_temperature",
                "10m_u_component_of_wind",
                "10m_v_component_of_wind"),
  cache_dir = ".era5_cache"
)
# the endpoint returns SHORT variable names:
# columns: site, date, lat, lon, t2m, u10, v10
head(df_met)
```

## 5. Merge the panel

```r
panel <- merge(aq, df_met, by = c("site", "date"))
head(panel)
```

## 6. Weather normalisation and an HTML report

`nm_do_all()` runs the full pipeline — prepare → train → Monte-Carlo
normalise — in one call; then bundle the result with provenance metadata and
export a report.

```r
# Meteorological resample variables (short ERA5 names) + time features
# engineered by nm_prepare_data()
met_vars   <- c("t2m", "u10", "v10")
predictors <- c(met_vars, "date_unix", "day_julian", "weekday", "hour")

results <- nm_do_all(
  df            = panel,
  target        = "value",          # the PM2.5 column returned by OpenAQ
  backend       = "lightgbm",
  covariates    = predictors,
  resample_vars = met_vars,
  n_samples     = 50
)

head(results$res)                  # date | observed | normalised

run <- nm_make_run(
  results$res,
  kind    = "do_all",
  config  = list(target = "value", backend = "lightgbm"),
  df      = panel,
  df_prep = results$df_prep,
  model   = results$model
)

nm_generate_html(
  run,
  "london_normalisation_report.html",
  title = "London PM2.5 weather normalisation"
)
```

The single self-contained HTML report embeds the figure and the provenance
record, so it can be filed with the result. `nm_report_to_markdown()` writes
the same content as Markdown; `lang = "zh"` renders an HTML report in
Chinese.
