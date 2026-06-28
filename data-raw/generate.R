# Synthetic dataset generation for normet-r
# Run this script to regenerate data/MY1.RData and data/SCM.RData.

set.seed(42)

# ── Helpers ──────────────────────────────────────────────────────────────────

clip <- function(x, lo, hi) pmax(lo, pmin(hi, x))

voc <- function(n, base) clip(base + rexp(n, rate = 1 / (base * 0.5)), 0, base * 10)

# ── my1: hourly air quality + ERA5 met, 2020 ─────────────────────────────────

n_days  <- 366L   # 2020 is a leap year
dates   <- seq(
  as.POSIXct("2020-01-01 00:00:00", tz = "UTC"),
  by = "hour",
  length.out = n_days * 24L
)
n <- length(dates)

hour  <- as.integer(format(dates, "%H"))
doy   <- as.integer(format(dates, "%j"))

season  <- sin(2 * pi * (doy - 80) / 365)
rush    <- sin(2 * pi * (hour - 8)  / 24)
solar   <- pmax(0, sin(2 * pi * (hour - 6) / 24))

t2m   <- clip(285 + 10 * season + 3 * solar   + rnorm(n, 0, 1),   250, 320)
d2m   <- clip(t2m - 8           + rnorm(n, 0, 1),                  240, 310)
u10   <- rnorm(n, -1.0, 2.0)
v10   <- rnorm(n,  0.0, 2.0)
ws    <- sqrt(u10^2 + v10^2)
blh   <- clip(300 + 1500 * solar + rnorm(n, 0, 80),                50, 3500)
sp    <- clip(101325 + 400 * season + rnorm(n, 0, 200),        99000, 104000)
ssrd  <- pmax(0, 2.5e6 * solar * (0.7 + 0.3 * season) + rnorm(n, 0, 5e4))
tcc   <- clip(0.5 - 0.1 * season + rnorm(n, 0, 0.15),             0, 1)
tp    <- pmax(0, rexp(n, rate = 1 / 5e-5) * (runif(n) < 0.04))
rh2m  <- clip(80 - 5 * season - 3 * solar + rnorm(n, 0, 4),       30, 100)

pm25  <- clip(20 - 6*season + 8*pmax(0,rush) - 1.5*ws + rnorm(n,0,5), 1, 120)
no    <- clip(25 + 15*pmax(0,rush) - 5*season + rnorm(n,0,6),          0, 200)
no2   <- clip(30 + 10*pmax(0,rush) - 4*season + rnorm(n,0,5),          0, 120)
nox   <- no + no2 * 46/30
o3    <- clip(30 + 20*season + 10*solar - 0.3*no2 + rnorm(n,0,5),      0, 120)
ox    <- o3 + no2
so2   <- clip(5 - 2*season + rnorm(n,0,2),                             0, 30)
co    <- clip(0.5 + 0.2*pmax(0,rush) + rnorm(n,0,0.1),              0.1, 3)
pm10  <- clip(pm25*1.5 + rnorm(n,0,5),                                 0, 200)
wd    <- (atan2(v10, u10) * 180 / pi + 360) %% 360
temp  <- t2m - 273.15

my1 <- data.frame(
  date          = dates,
  O3            = o3,
  NO            = no,
  NO2           = no2,
  NOXasNO2      = nox,
  SO2           = so2,
  CO            = co,
  PM10          = pm10,
  NV10          = pm10 * 0.85,
  V10           = pm10 * 0.15,
  "PM2.5"       = pm25,
  "NV2.5"       = pm25 * 0.88,
  "V2.5"        = pm25 * 0.12,
  ETHANE        = voc(n, 2.0),
  ETHENE        = voc(n, 1.2),
  ETHYNE        = voc(n, 0.8),
  PROPANE       = voc(n, 3.0),
  PROPENE       = voc(n, 0.9),
  iBUTANE       = voc(n, 1.5),
  nBUTANE       = voc(n, 2.2),
  "1BUTENE"     = voc(n, 0.15),
  t2BUTENE      = voc(n, 0.07),
  c2BUTENE      = voc(n, 0.05),
  iPENTANE      = voc(n, 0.9),
  nPENTANE      = voc(n, 0.5),
  t2PENTEN      = voc(n, 0.04),
  "1PENTEN"     = voc(n, 0.08),
  "2MEPENT"     = voc(n, 0.2),
  ISOPRENE      = voc(n, 0.03),
  nHEXANE       = voc(n, 0.2),
  nHEPTANE      = voc(n, 0.12),
  iOCTANE       = voc(n, 0.18),
  nOCTANE       = voc(n, 0.07),
  BENZENE       = voc(n, 0.7),
  TOLUENE       = voc(n, 1.0),
  ETHBENZ       = voc(n, 0.2),
  mpXYLENE      = voc(n, 0.4),
  oXYLENE       = voc(n, 0.2),
  "124TMB"      = voc(n, 0.15),
  "135TMB"      = voc(n, 0.05),
  wd            = wd,
  ws            = ws,
  temp          = temp,
  AT10          = clip(pm10 * 0.3 + rnorm(n, 0, 1), 0, 30),
  AP10          = sp / 100 + rnorm(n, 0, 0.5),
  "AT2.5"       = clip(pm25 * 0.3 + rnorm(n, 0, 1), 0, 30),
  "AP2.5"       = sp / 100 - 1 + rnorm(n, 0, 0.2),
  site          = "London Marylebone Road",
  code          = "MY1",
  latitude      = 51.52253,
  longitude     = -0.154611,
  location_type = "Urban Traffic",
  Ox            = ox,
  NOx           = nox,
  u10           = u10,
  v10           = v10,
  d2m           = d2m,
  t2m           = t2m,
  blh           = blh,
  sp            = sp,
  ssrd          = ssrd,
  tcc           = tcc,
  tp            = tp,
  rh2m          = rh2m,
  lat           = 51.52253,
  lon           = -0.154611,
  check.names   = FALSE
)

# ── scm: weekly panel, 2015-05-03 to 2016-04-24, 38 units ───────────────────

treated_id <- "2+26 cities"
donor_ids  <- c(
  "Dongguan", "Zhongshan", "Foshan", "Beihai", "Nanning", "Nanchang",
  "Xiamen", "Taizhou", "Ningbo", "Guangzhou", "Huizhou", "Hangzhou",
  "Liuzhou", "Shantou", "Jiangmen", "Heyuan", "Quanzhou", "Haikou",
  "Shenzhen", "Wenzhou", "Huzhou", "Zhuhai", "Fuzhou", "Shaoxing",
  "Zhaoqing", "Zhoushan", "Quzhou", "Jinhua", "Shaoguan", "Sanya",
  "Jieyang", "Meizhou", "Shanwei", "Zhanjiang", "Chaozhou", "Maoming",
  "Yangjiang"
)
all_ids <- c(treated_id, donor_ids)

dates_scm <- seq(as.Date("2015-05-03"), as.Date("2016-04-24"), by = "week")
n_weeks   <- length(dates_scm)
cutoff    <- as.Date("2015-10-23")

common <- 60 + 5 * sin(2 * pi * seq_len(n_weeks) / 52) + rnorm(n_weeks, 0, 3)

rows <- lapply(all_ids, function(uid) {
  scale <- runif(1, 0.6, 1.4)
  idio  <- rnorm(n_weeks, 0, 4)
  so2wn <- common * scale + idio
  if (uid == treated_id) so2wn[dates_scm >= cutoff] <- so2wn[dates_scm >= cutoff] * 0.65
  so2wn <- pmax(so2wn, 1)
  grp   <- if (uid == treated_id) "target" else "control"
  data.frame(
    date     = dates_scm,
    ID       = uid,
    CO       = pmax(so2wn * 0.025 + rnorm(n_weeks, 0, 0.2), 0),
    COwn     = pmax(so2wn * 0.024 + rnorm(n_weeks, 0, 0.2), 0),
    NO2      = pmax(so2wn * 0.6   + rnorm(n_weeks, 0, 3),   0),
    NO2wn    = pmax(so2wn * 0.58  + rnorm(n_weeks, 0, 3),   0),
    O3       = pmax(35 - so2wn * 0.1 + rnorm(n_weeks, 0, 5), 5),
    O3_8h    = pmax(40 - so2wn * 0.1 + rnorm(n_weeks, 0, 5), 5),
    O3_8hwn  = pmax(38 - so2wn * 0.1 + rnorm(n_weeks, 0, 5), 5),
    O3wn     = pmax(36 - so2wn * 0.1 + rnorm(n_weeks, 0, 5), 5),
    Ox       = pmax(so2wn * 0.5   + rnorm(n_weeks, 0, 4),   0),
    Oxwn     = pmax(so2wn * 0.48  + rnorm(n_weeks, 0, 4),   0),
    PM10     = pmax(so2wn * 1.8   + rnorm(n_weeks, 0, 10),  0),
    PM10wn   = pmax(so2wn * 1.75  + rnorm(n_weeks, 0, 10),  0),
    "PM2.5"  = pmax(so2wn * 1.1   + rnorm(n_weeks, 0, 6),   0),
    "PM2.5wn"= pmax(so2wn * 1.05  + rnorm(n_weeks, 0, 6),   0),
    SO2      = pmax(so2wn          + rnorm(n_weeks, 0, 2),   0),
    SO2wn    = so2wn,
    group    = grp,
    check.names = FALSE,
    stringsAsFactors = FALSE
  )
})

scm <- do.call(rbind, rows)
scm$date <- as.Date(scm$date)
rownames(scm) <- NULL

# ── Save ─────────────────────────────────────────────────────────────────────

save(my1, file = "data/MY1.RData", compress = "bzip2")
save(scm,  file = "data/SCM.RData",  compress = "bzip2")

cat("MY1:", nrow(my1), "rows x", ncol(my1), "cols\n")
cat("SCM:", nrow(scm),  "rows x", ncol(scm),  "cols\n")
cat("Done.\n")
