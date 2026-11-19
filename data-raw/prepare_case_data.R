# Prepare the bundled example datasets from the normet GMD paper case studies.
#
# Source data (see the paper's Zenodo archive for full provenance):
#   my1      — AURN hourly NO2 at London Marylebone Road (MY1) merged with
#              ERA5 single-level meteorology; subset 2020-01-01..2020-08-31.
#   scm      — monthly deweathered NO2 panel for 104 UK monitoring sites
#              (2016-2021), used for the ULEZ Synthetic Control case study.
#   my1_pm25 — AURN hourly PM2.5 at MY1 with observed and ERA5 meteorology,
#              2020-01-01..2020-08-31 (transport-aware normalisation case).
#   traj_my1 — 6-hourly HYSPLIT 72-h back-trajectory features arriving at
#              MY1, 2020-01-01..2020-08-31 (same case study). The raw
#              HYSPLIT tdump files for the first two days are shipped in
#              inst/extdata/traj/ for the trajectory-reader examples.
#
# Air-quality observations: UK AURN (Defra), Open Government Licence v3.0.
# Meteorology: ERA5 (Copernicus Climate Change Service), Copernicus licence.
#
# Run from the package root:  Rscript data-raw/prepare_case_data.R

read_case <- function(name) {
  utils::read.csv(file.path("data-raw", "case_data", paste0(name, ".csv.gz")),
                  check.names = FALSE)
}

my1 <- read_case("my1")
my1$date <- as.POSIXct(my1$date, tz = "UTC")
stopifnot(nrow(my1) == 5793, ncol(my1) == 11, !anyNA(my1$NO2))

scm <- read_case("scm")
scm$date <- as.Date(scm$date)
stopifnot(nrow(scm) == 7378, ncol(scm) == 6, "MY1" %in% scm$code)

my1_pm25 <- read_case("my1_pm25")
my1_pm25$date <- as.POSIXct(my1_pm25$date, tz = "UTC")
stopifnot(nrow(my1_pm25) == 5856, ncol(my1_pm25) == 17)

traj_my1 <- read_case("traj_my1")
traj_my1$date <- as.POSIXct(traj_my1$date, tz = "UTC")
stopifnot(nrow(traj_my1) == 976, ncol(traj_my1) == 12)

save(my1, file = "data/my1.rda", compress = "xz")
save(scm, file = "data/scm.rda", compress = "xz")
save(my1_pm25, file = "data/my1_pm25.rda", compress = "xz")
save(traj_my1, file = "data/traj_my1.rda", compress = "xz")

cat("Written:\n")
print(file.info(list.files("data", full.names = TRUE))["size"])
