# The resolver reads options and environment variables, so these tests have to
# set them and put them back. withr would be the obvious tool but is not a
# declared dependency of this package, and R CMD check runs here with
# error_on = "warning", so it is done with base R instead: `code` is a promise,
# forced after the state is in place, and on.exit() restores it when this
# wrapper returns. Passing NA for a variable means "unset it".
with_state <- function(mc.cores = NULL, envvars = character(), code) {
  old_opts <- options(mc.cores = mc.cores)
  on.exit(options(old_opts), add = TRUE)

  if (length(envvars)) {
    nms <- names(envvars)
    old <- Sys.getenv(nms, unset = NA, names = TRUE)
    on.exit({
      if (any(!is.na(old))) do.call(Sys.setenv, as.list(old[!is.na(old)]))
      if (any(is.na(old))) Sys.unsetenv(nms[is.na(old)])
    }, add = TRUE)

    unset <- is.na(envvars)
    if (any(!unset)) do.call(Sys.setenv, as.list(envvars[!unset]))
    if (any(unset)) Sys.unsetenv(nms[unset])
  }

  force(code)
}


test_that(".nm_resolve_cores never starts more workers than there are tasks", {
  # The bug this guards: nm_pdp() derived its worker count from detectCores()
  # alone and ignored how many variables it was actually parallelising over, so
  # a PDP over one variable started one worker per core. Measured on the cluster
  # this package runs on, a 4-core allocation on a 168-core node still sees 168,
  # so that was 167 PSOCK workers against R's 128-slot connection table --
  # "all 128 connections are in use".
  #
  # _R_CHECK_LIMIT_CORES_ is cleared because R CMD check may set it itself,
  # which would cap every expectation below at 2 and mask what is being tested.
  with_state(mc.cores = 64L, envvars = c(`_R_CHECK_LIMIT_CORES_` = NA), {
    expect_equal(normet:::.nm_resolve_cores(n_tasks = 1), 1L)
    expect_equal(normet:::.nm_resolve_cores(n_tasks = 3), 3L)

    # The cap binds against an explicit n_cores too, not just the auto-detected
    # default -- n_cores = 32 for two variables is still 30 idle workers.
    expect_equal(normet:::.nm_resolve_cores(n_cores = 32, n_tasks = 2), 2L)

    # Degenerate task counts must still yield a usable cluster size.
    expect_equal(normet:::.nm_resolve_cores(n_tasks = 0), 1L)
  })
})


test_that(".nm_resolve_cores honours explicit values", {
  with_state(mc.cores = 64L, envvars = c(`_R_CHECK_LIMIT_CORES_` = NA), {
    expect_equal(normet:::.nm_resolve_cores(n_cores = 8), 8L)
    expect_equal(normet:::.nm_resolve_cores(n_cores = 0), 1L)
    expect_equal(normet:::.nm_resolve_cores(n_cores = NA), 1L)
  })
})


test_that(".nm_resolve_cores applies the R CMD check cap over everything else", {
  # CRAN policy caps checks at 2 cores, and it has to override an explicit
  # n_cores as well, which is why it is applied after the default is chosen
  # rather than folded into it.
  with_state(mc.cores = 64L, envvars = c(`_R_CHECK_LIMIT_CORES_` = "TRUE"), {
    expect_equal(normet:::.nm_resolve_cores(n_cores = 16), 2L)
    expect_equal(normet:::.nm_resolve_cores(), 2L)
  })
})


test_that(".nm_resolve_cores stays below R's connection-table limit", {
  # Backstop for very large machines: R's connection table has 128 slots, three
  # already taken, and makeCluster() aborts outright rather than degrading when
  # the worker count exceeds what is left. Measured on a 168-core node: 125
  # connections available beyond stdio.
  with_state(mc.cores = 10000L, envvars = c(`_R_CHECK_LIMIT_CORES_` = NA), {
    expect_lte(normet:::.nm_resolve_cores(), 120L)
    expect_lte(normet:::.nm_resolve_cores(n_cores = 10000), 120L)
  })
})


test_that(".nm_available_cores respects a scheduler allocation, not the machine size", {
  # detectCores() reports the whole node and is blind to the allocation. mc.cores
  # is cleared so the scheduler path is what gets exercised -- and cleared to
  # NULL specifically, which is also the zero-length input that would abort the
  # resolver with "invalid 'x' type in 'x && y'" without its length guard.
  with_state(mc.cores = NULL, envvars = c(SLURM_CPUS_PER_TASK = "4"), {
    expect_lte(normet:::.nm_available_cores(), 4L)
    expect_gte(normet:::.nm_available_cores(), 1L)
  })
})


test_that(".nm_available_cores treats mc.cores as an explicit override", {
  # Base R's own convention: an mc.cores set by the user is an instruction, so it
  # wins outright rather than being minimised against the detected limits.
  with_state(mc.cores = 3L, envvars = c(SLURM_CPUS_PER_TASK = "64"), {
    expect_equal(normet:::.nm_available_cores(), 3L)
  })
})
