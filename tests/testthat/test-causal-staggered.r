# Mirrors normet-py's tests/test_causal_staggered.py (PR #66).
#
# Staggered synthetic controls: several treated units, each with its own
# cutoff. The panel is the clean case: both treated units share a common
# pre-period signal that the donors span (0.5*D1 + 0.5*D2), so every
# pre-period fits perfectly and an injected post-cutoff step is read almost
# exactly. With the step the effects are far outside the donor-only placebo
# reference (the p-value sits at its minimum, 1/(n_donors + 1)); without it
# the effects sit at zero and the p-value at its maximum (1.0). The summary
# rows are checked against the units' own effects, and the input guards
# against the staggered-specific mistakes: a treated unit inside the donor
# pool, a misaligned cutoff list, and a treated unit whose cutoff falls after
# its last observation.

N_DAYS <- 160
T1_CUTOFF <- "2023-03-02"  # day 60
T2_CUTOFF <- "2023-04-01"  # day 90
DONORS <- paste0("D", 1:5)

.staggered_panel <- function(effect = 5.0) {
  # Two treated units (T1 at day 60, T2 at day 90) plus five donors; the
  # treated pre-period is 0.5*D1 + 0.5*D2 plus the step after each cutoff.
  t <- seq_len(N_DAYS) - 1
  dates <- seq(as.Date("2023-01-01"), by = "day", length.out = N_DAYS)
  base <- lapply(1:5, function(j) {
    5 + (j - 1) + 3 * sin(2 * pi * t / (30 - 4 * (j - 1)) + (j - 1))
  })
  common <- 0.5 * base[[1]] + 0.5 * base[[2]]
  series <- c(list(T1 = common + effect * (t >= 60), T2 = common + effect * (t >= 90)), base)
  names(series) <- c("T1", "T2", DONORS)
  do.call(rbind, lapply(names(series), function(name) {
    data.frame(date = dates, ID = name, value = series[[name]], stringsAsFactors = FALSE)
  }))
}

.stag <- function(df, ...) {
  nm_run_scm_staggered(
    df, date_col = "date", unit_col = "ID", outcome_col = "value",
    treated_units = c("T1", "T2"),
    cutoff_dates = c(T1 = T1_CUTOFF, T2 = T2_CUTOFF),
    n_cores = 2, verbose = FALSE, ...
  )
}

# ------------------------------------------------------------------- the fit
test_that("nm_run_scm_staggered reads each unit's step and ranks it", {
  out <- .stag(.staggered_panel())

  expect_equal(out$unit, c("T1", "T2", "mean", "median"))
  expect_equal(out$cutoff_date[1:2], c(T1_CUTOFF, T2_CUTOFF))
  expect_equal(out$n_pre[1:2], c(60L, 90L))
  expect_equal(out$n_post[1:2], c(100L, 70L))
  # The step is read almost exactly, and the pre-period is a clean fit.
  expect_lt(abs(out$effect[1] - 5.0), 0.05)
  expect_lt(abs(out$effect[2] - 5.0), 0.05)
  expect_gt(min(out$pre_r2[1:2]), 0.99)
  # Five donors: with no placebo reaching the step the p-value sits at its
  # minimum, (0 + 1) / (5 + 1).
  expect_equal(out$p_value[1:2], c(1 / 6, 1 / 6))
})

test_that("nm_run_scm_staggered: the null gives the maximum p", {
  out <- .stag(.staggered_panel(effect = 0.0))

  expect_lt(max(abs(out$effect[1:2])), 1e-3)
  expect_equal(out$p_value[1:2], c(1.0, 1.0))
  expect_equal(out$p_value[out$unit == "mean"], 1.0)
})

test_that("nm_run_scm_staggered: the summary rows aggregate the units", {
  out <- .stag(.staggered_panel())

  units <- out[out$unit %in% c("T1", "T2"), ]
  mean_row <- out[out$unit == "mean", ][1, ]
  median_row <- out[out$unit == "median", ][1, ]
  expect_equal(mean_row$effect, mean(units$effect), tolerance = 1e-12)
  expect_equal(median_row$effect, median(units$effect), tolerance = 1e-12)
  # The cross-unit test is stated on the mean; the median row is descriptive.
  expect_equal(mean_row$p_value, 1 / 6)
  expect_true(is.na(median_row$p_value))
  expect_true(is.na(mean_row$cutoff_date))
})

test_that("nm_run_scm_staggered: a list of cutoffs matches the named form", {
  df <- .staggered_panel()
  out_named <- .stag(df)
  out_list <- nm_run_scm_staggered(
    df, date_col = "date", unit_col = "ID", outcome_col = "value",
    treated_units = c("T1", "T2"), cutoff_dates = c(T1_CUTOFF, T2_CUTOFF),
    n_cores = 2, verbose = FALSE
  )
  expect_equal(out_named, out_list)
})

test_that("nm_run_scm_staggered: an explicit donor pool sets the reference size", {
  # Four of the five donors: the reference holds four placebos, so the
  # minimum p-value is (0 + 1) / (4 + 1) -- the pool is honoured, and the
  # reduced pool (three donors) is still large enough for the default
  # backend to fit each placebo.
  out <- .stag(.staggered_panel(), donors = DONORS[1:4])
  expect_equal(out$p_value[1], 0.2)
  expect_lt(abs(out$effect[1] - 5.0), 0.05)
})

test_that("nm_run_scm_staggered: post_agg='sum' reads the cumulative effect", {
  out <- .stag(.staggered_panel(effect = 2.0), post_agg = "sum")
  # 2 per day over 100 (T1) and 70 (T2) post days.
  expect_lt(abs(out$effect[1] - 200.0), 2.0)
  expect_lt(abs(out$effect[2] - 140.0), 2.0)
})

# ------------------------------------------------------------------- the guards
test_that("nm_run_scm_staggered rejects an empty or duplicate treated list", {
  df <- .staggered_panel()
  expect_error(
    nm_run_scm_staggered(df, date_col = "date", unit_col = "ID", outcome_col = "value",
      treated_units = character(0), cutoff_dates = character(0)),
    "must not be empty"
  )
  expect_error(
    nm_run_scm_staggered(df, date_col = "date", unit_col = "ID", outcome_col = "value",
      treated_units = c("T1", "T1"), cutoff_dates = c(T1 = T1_CUTOFF)),
    "must be unique"
  )
})

test_that("nm_run_scm_staggered rejects units absent from the panel", {
  expect_error(
    nm_run_scm_staggered(.staggered_panel(), date_col = "date", unit_col = "ID", outcome_col = "value",
      treated_units = c("T1", "Nope"), cutoff_dates = c(T1 = T1_CUTOFF, Nope = T2_CUTOFF)),
    "not in the panel"
  )
})

test_that("nm_run_scm_staggered rejects a misaligned cutoff list", {
  df <- .staggered_panel()
  expect_error(
    nm_run_scm_staggered(df, date_col = "date", unit_col = "ID", outcome_col = "value",
      treated_units = c("T1", "T2"), cutoff_dates = T1_CUTOFF),
    "align"
  )
  expect_error(
    nm_run_scm_staggered(df, date_col = "date", unit_col = "ID", outcome_col = "value",
      treated_units = c("T1", "T2"), cutoff_dates = list("2023-03-02")),
    "named vector"
  )
})

test_that("nm_run_scm_staggered rejects a treated unit inside the donors", {
  expect_error(
    .stag(.staggered_panel(), donors = c("D1", "T2")),
    "must not include treated"
  )
})

test_that("nm_run_scm_staggered rejects a design with no donors left", {
  expect_error(
    nm_run_scm_staggered(
      .staggered_panel(), date_col = "date", unit_col = "ID", outcome_col = "value",
      treated_units = c("T1", "T2", DONORS),
      cutoff_dates = c(T1 = T1_CUTOFF, T2 = T2_CUTOFF,
        D1 = T1_CUTOFF, D2 = T2_CUTOFF, D3 = T1_CUTOFF, D4 = T2_CUTOFF, D5 = T1_CUTOFF)
    ),
    "No donor units"
  )
})

test_that("nm_run_scm_staggered rejects a cutoff after the unit's last observation", {
  expect_error(
    nm_run_scm_staggered(.staggered_panel(), date_col = "date", unit_col = "ID", outcome_col = "value",
      treated_units = c("T1", "T2"), cutoff_dates = c(T1 = T1_CUTOFF, T2 = "2024-01-01")),
    "No post-cutoff observations"
  )
})
