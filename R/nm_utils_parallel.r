#' Propagate the Master's Library Paths to Cluster Workers (Internal Helper)
#'
#' @description
#' PSOCK workers created by \code{parallel::makeCluster()} start with their own
#' default \code{.libPaths()}, which does not include any non-standard library
#' the master process is using (e.g. a temporary library used while \code{R CMD
#' check} builds vignettes, or an \code{renv}/\code{pak} project library). When
#' that happens, workers cannot find or load 'normet' itself, and functions
#' exported to them via \code{foreach(.export = ...)} fail with
#' "could not find function" even though the function was exported, because the
#' function's own lexical scope (the 'normet' namespace) cannot be reconstructed
#' on the worker. Call this right after creating the cluster and before
#' registering it with \code{doSNOW}/\code{doParallel}.
#'
#' @param cl A cluster object as returned by \code{parallel::makeCluster()}.
#'
#' @return Invisibly, the cluster object.
#'
#' @noRd
.nm_propagate_libpaths <- function(cl) {
  lib_paths <- .libPaths()
  parallel::clusterCall(cl, function(lp) .libPaths(lp), lib_paths)
  invisible(cl)
}


#' Upper Bound on PSOCK Workers Imposed by R's Connection Table (Internal)
#'
#' @description
#' Each PSOCK worker holds one R connection, and R's connection table is a fixed
#' array (128 slots) -- three are taken by stdin/stdout/stderr before any user
#' code runs, and exceeding the rest aborts cluster creation outright with
#' "all 128 connections are in use". The headroom left below leaves room for the
#' file/gzfile connections a caller may legitimately hold open at the same time.
#' This is a backstop against absurd worker counts, not a tuning knob: for every
#' workload in this package, per-worker startup cost dominates long before it
#' binds.
#'
#' @noRd
.NM_MAX_WORKERS <- 120L


#' Read a CPU Quota From the cgroup Filesystem (Internal Helper)
#'
#' @description
#' Catches quota-based limits that leave no trace in the affinity mask, such as
#' \code{docker run --cpus=2.5}. Handles cgroup v2 (\code{cpu.max}, "quota
#' period" or "max period") and v1 (\code{cpu.cfs_quota_us} /
#' \code{cpu.cfs_period_us}, quota -1 meaning unlimited). Returns \code{NULL}
#' when no quota applies or the files are absent/unreadable, so the caller can
#' fall through to the other signals.
#'
#' @return Integer core count, or \code{NULL}.
#'
#' @noRd
.nm_cgroup_cores <- function() {
  ratio <- function(quota, period) {
    if (!is.finite(quota) || !is.finite(period) || quota <= 0 || period <= 0) {
      return(NULL)
    }
    max(1L, as.integer(floor(quota / period)))
  }
  read_num <- function(path) {
    val <- tryCatch(readLines(path, warn = FALSE)[1], error = function(e) NA_character_)
    suppressWarnings(as.numeric(val))
  }

  v2 <- "/sys/fs/cgroup/cpu.max"
  if (file.exists(v2)) {
    fields <- tryCatch(
      strsplit(trimws(readLines(v2, warn = FALSE)[1]), "[[:space:]]+")[[1]],
      error = function(e) character(0)
    )
    # "max <period>" means no quota is set; anything else is "<quota> <period>".
    if (length(fields) == 2L && !identical(fields[1], "max")) {
      out <- ratio(suppressWarnings(as.numeric(fields[1])), suppressWarnings(as.numeric(fields[2])))
      if (!is.null(out)) return(out)
    }
  }

  v1_quota <- "/sys/fs/cgroup/cpu/cpu.cfs_quota_us"
  v1_period <- "/sys/fs/cgroup/cpu/cpu.cfs_period_us"
  if (file.exists(v1_quota) && file.exists(v1_period)) {
    # A quota of -1 is v1's "unlimited"; ratio() rejects it along with NA.
    out <- ratio(read_num(v1_quota), read_num(v1_period))
    if (!is.null(out)) return(out)
  }

  NULL
}


#' How Many Cores Is This Process Actually Allowed to Use? (Internal Helper)
#'
#' @description
#' \code{parallel::detectCores()} reports how many CPUs the \emph{machine} has.
#' It is blind to every mechanism that confines a process to a subset of them --
#' a batch scheduler's allocation, a container's CPU quota, an affinity mask --
#' so on a shared cluster node or inside a container it over-reports by an order
#' of magnitude. A 4-core SLURM allocation on a 168-core node still sees 168,
#' and using that as a worker count both oversubscribes the allocation and, past
#' ~125 workers, exhausts R's connection table outright (see
#' \code{.NM_MAX_WORKERS}).
#'
#' Every constraint that can be detected is applied, not just the first one
#' found: a scheduler may allocate cores without binding them (env var set,
#' affinity mask wide open) or bind without exporting a count, and taking the
#' minimum is correct whichever way round it is. \code{getOption("mc.cores")} is
#' the one exception -- it is an explicit instruction from the user, following
#' base R's own convention, so it wins outright.
#'
#' @return Integer, at least 1.
#'
#' @noRd
.nm_available_cores <- function() {
  # Length guard, not just an NA guard: an explicit options(mc.cores = NULL)
  # makes getOption() hand back NULL rather than the default, and as.integer()
  # turns that into integer(0), which would abort `&&` with a zero-length
  # argument.
  opt <- suppressWarnings(as.integer(getOption("mc.cores", NA_integer_)))
  if (length(opt) == 1L && !is.na(opt) && opt >= 1L) return(opt)

  limits <- integer(0)

  # CPU affinity mask: catches SLURM/PBS cpuset binding, `docker --cpuset-cpus`
  # and taskset in one go. Unix-only -- returns NULL elsewhere.
  affinity <- tryCatch(parallel::mcaffinity(), error = function(e) NULL)
  if (!is.null(affinity) && length(affinity) >= 1L) {
    limits <- c(limits, length(affinity))
  }

  # Schedulers that allocate without binding leave the mask wide open, so their
  # own environment variables are the only signal. Values are per-task where the
  # scheduler distinguishes; SLURM_CPUS_ON_NODE is the whole-node fallback for
  # allocations made without --cpus-per-task.
  #
  # OMP_NUM_THREADS deliberately does not belong here: it sets threads *per
  # process*, not the size of the allocation, and is routinely set to 1 to stop
  # BLAS oversubscribing underneath exactly this kind of worker pool. Reading it
  # as a core count would serialise everything for the users being most careful.
  for (var in c("SLURM_CPUS_PER_TASK", "SLURM_CPUS_ON_NODE", "NSLOTS",
                "PBS_NUM_PPN", "NCPUS", "LSB_DJOB_NUMPROC")) {
    val <- suppressWarnings(as.integer(Sys.getenv(var, "")))
    if (!is.na(val) && val >= 1L) limits <- c(limits, val)
  }

  cgroup <- .nm_cgroup_cores()
  if (!is.null(cgroup)) limits <- c(limits, cgroup)

  # Physical cores are the right denominator for the compute-bound work here;
  # detectCores() returns NA on platforms where it cannot tell, hence the
  # logical fallback.
  detected <- parallel::detectCores(logical = FALSE)
  if (is.na(detected) || length(detected) == 0L) {
    detected <- parallel::detectCores(logical = TRUE)
  }
  if (!is.na(detected) && length(detected) >= 1L) limits <- c(limits, detected)

  if (length(limits) == 0L) return(1L)
  max(1L, min(limits))
}


#' Resolve a Worker Count for a Parallel Section (Internal Helper)
#'
#' @description
#' The single place this package decides how many workers to start. Wraps
#' \code{.nm_available_cores()} with the caps every call site needs:
#'
#' \itemize{
#'   \item \code{n_tasks} -- never start more workers than there are pieces of
#'     work. Each PSOCK worker is a fresh R process that has to load the
#'     package before it can do anything, so workers beyond the task count are
#'     pure startup cost. This is what stops a PDP over one variable from
#'     starting one worker per core.
#'   \item \code{_R_CHECK_LIMIT_CORES_} -- CRAN policy caps checks at 2 cores,
#'     and it must override an explicit \code{n_cores} too, so it is applied
#'     last rather than folded into the default.
#'   \item \code{.NM_MAX_WORKERS} -- backstop against exhausting R's connection
#'     table.
#' }
#'
#' @param n_cores Explicit worker count, or \code{NULL} to auto-detect.
#' @param n_tasks Number of work items to be distributed, or \code{NULL} if not
#'   known up front. Never returns more workers than this.
#' @param reserve Cores to leave for the master process and the OS when
#'   auto-detecting. Ignored when \code{n_cores} is supplied.
#' @param limit Optional extra ceiling for the auto-detected case, used where
#'   R-side workers deliberately stay out of another engine's way (e.g. feeding
#'   H2O). Ignored when \code{n_cores} is supplied.
#'
#' @return Integer, at least 1.
#'
#' @noRd
.nm_resolve_cores <- function(n_cores = NULL, n_tasks = NULL, reserve = 1L, limit = Inf) {
  if (!is.null(n_cores)) {
    n <- suppressWarnings(as.integer(n_cores))[1]
    if (length(n) == 0L || is.na(n)) n <- 1L
  } else {
    n <- min(.nm_available_cores() - as.integer(reserve), limit)
  }

  if (!is.null(n_tasks)) {
    n_tasks <- suppressWarnings(as.integer(n_tasks))[1]
    if (length(n_tasks) == 1L && !is.na(n_tasks)) n <- min(n, n_tasks)
  }

  if (Sys.getenv("_R_CHECK_LIMIT_CORES_", "") != "") n <- min(n, 2L)

  n <- min(n, .NM_MAX_WORKERS)
  max(1L, as.integer(n))
}
