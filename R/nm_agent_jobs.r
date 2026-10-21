# Jobs: an R script run by Rscript, in a folder of its own
#
# Ported from Python normet agent/jobs.py. A job's folder holds what it is and how
# it went, so a server started again finds its jobs where they were:
#
#   job.json      what was asked: the kind, the label, the command line
#   job.R         the script: the normet calls the job makes, run as it is written
#   started.json  the R process's id and when it started (written by the job)
#   stdout.txt    what the script printed
#   stderr.txt    its log lines and errors
#   exit.json     how it ended: done, failed or cancelled, and the exit code
#   cancel        there when a cancel was asked
#   *.csv, run.*  the script's files
#
# The script is the job's record: `Rscript job.R`, from the job's folder, runs it
# again without the server or an assistant. Jobs run one at a time, in the order
# asked: the server starts the first, and each job, as it ends, the next.

NULL

#' How long a job asked to stop has to stop before it is killed (seconds).
#' @noRd
.NM_CANCEL_GRACE <- 10

#' How long a job launched may take to say it has started (seconds).
#' @noRd
.NM_START_GRACE <- 120

#' Where jobs are kept: `$NORMET_MCP_HOME`, or `~/.normet/mcp-r` (normet-py's
#' server keeps its own in `~/.normet/mcp`).
#' @noRd
.nm_jobs_home <- function(home = NULL) {
  home <- home %||% Sys.getenv("NORMET_MCP_HOME", "")
  if (!nzchar(home)) home <- file.path("~", ".normet", "mcp-r")
  normalizePath(path.expand(home), winslash = "/", mustWork = FALSE)
}

.nm_read_json <- function(path) {
  if (!file.exists(path)) return(NULL)
  value <- tryCatch(jsonlite::fromJSON(path, simplifyVector = FALSE), error = function(e) NULL)
  if (is.list(value)) value else NULL
}

.nm_write_json <- function(path, value) {
  tmp <- paste0(path, ".part")
  writeLines(jsonlite::toJSON(value, auto_unbox = TRUE, pretty = TRUE, null = "null", digits = NA),
             tmp, useBytes = TRUE)
  file.rename(tmp, path)
  invisible(path)
}

.nm_pid_alive <- function(pid) {
  if (is.null(pid) || is.na(pid) || !pid) return(FALSE)
  if (.Platform$OS.type == "windows") {
    out <- tryCatch(system2("tasklist", c("/FI", shQuote(paste("PID eq", pid)), "/NH"),
                            stdout = TRUE, stderr = FALSE), error = function(e) "")
    return(any(grepl(paste0("\\b", pid, "\\b"), out)))
  }
  isTRUE(suppressWarnings(tools::pskill(pid, 0L)))
}

#' Every process `pid` started, and those they started: found before `pid` is
#' killed, as its children are no longer its own after.
#' @noRd
.nm_descendants <- function(pid) {
  if (.Platform$OS.type == "windows") return(integer())
  ps <- tryCatch(system2("ps", c("-A", "-o", "pid=,ppid="), stdout = TRUE, stderr = FALSE),
                 error = function(e) character())
  parts <- strsplit(trimws(ps), "\\s+")
  parts <- parts[lengths(parts) == 2]
  if (!length(parts)) return(integer())
  pids <- as.integer(vapply(parts, `[`, "", 1))
  ppids <- as.integer(vapply(parts, `[`, "", 2))
  out <- integer()
  todo <- as.integer(pid)
  while (length(todo)) {
    kids <- pids[ppids == todo[1]]
    todo <- c(todo[-1], kids)
    out <- c(out, kids)
  }
  out
}

.nm_kill <- function(pid, signal) {
  if (.Platform$OS.type == "windows") {
    system2("taskkill", c("/T", "/F", "/PID", pid), stdout = FALSE, stderr = FALSE)
    return(invisible())
  }
  for (p in c(pid, .nm_descendants(pid))) suppressWarnings(tools::pskill(p, signal))
  invisible()
}

#' The jobs kept in `home/jobs`.
#' @noRd
.nm_job_store <- function(home = NULL) {
  home <- .nm_jobs_home(home)
  root <- file.path(home, "jobs")
  dir.create(root, recursive = TRUE, showWarnings = FALSE)
  structure(list(home = home, root = root), class = "nm_job_store")
}

.nm_job_ids <- function(store) {
  ids <- list.files(store$root)
  sort(ids[file.exists(file.path(store$root, ids, "job.json"))])
}

.nm_job_folder <- function(store, job_id) {
  job_id <- trimws(as.character(job_id))
  if (!nzchar(job_id) || grepl("[/\\\\]|^\\.", job_id) ||
      !file.exists(file.path(store$root, job_id, "job.json"))) {
    stop(sprintf("no job '%s'", job_id), call. = FALSE)
  }
  file.path(store$root, job_id)
}

#' Queue `code` (the lines of an R script) as a job; it starts once those before
#' it have ended.
#' @noRd
.nm_job_submit <- function(store, kind, code, label = "") {
  now <- as.numeric(Sys.time())
  # Ids sort as the jobs were asked -- the queue's order -- to the microsecond.
  job_id <- sprintf("%s.%06d-%s", format(Sys.time(), "%Y%m%d-%H%M%S"),
                    as.integer(round((now %% 1) * 1e6)) %% 1000000L,
                    paste(sample(c(0:9, letters[1:6]), 4, replace = TRUE), collapse = ""))
  folder <- file.path(store$root, job_id)
  dir.create(folder, recursive = TRUE)
  writeLines(c(
    sprintf("# normet job %s (%s)%s", job_id, kind, if (nzchar(label)) paste0(": ", label) else ""),
    "# Runs again as it is: Rscript job.R, from this folder.",
    "",
    "library(normet)",
    "",
    code
  ), file.path(folder, "job.R"), useBytes = TRUE)
  .nm_write_json(file.path(folder, "job.json"), list(
    id = job_id, kind = kind, label = label, script = "job.R",
    command = "Rscript job.R", folder = folder, submitted = now
  ))
  .nm_job_pump(store)
  .nm_job_status(store, job_id)
}

.nm_job_state <- function(store, job_id) {
  folder <- .nm_job_folder(store, job_id)
  ended <- .nm_read_json(file.path(folder, "exit.json"))
  if (!is.null(ended)) return(as.character(ended$state))
  cancelled <- file.exists(file.path(folder, "cancel"))
  started <- .nm_read_json(file.path(folder, "started.json"))
  if (!is.null(started)) {
    if (.nm_pid_alive(started$pid)) return("running")
  } else {
    launched <- file.path(folder, "launched")
    if (!file.exists(launched)) return(if (cancelled) "cancelled" else "queued")
    # Launched, R not yet up: starting, for a while.
    age <- as.numeric(Sys.time()) - as.numeric(file.mtime(launched))
    if (!cancelled && age < .NM_START_GRACE) return("running")
  }
  # Ended without saying how: killed, or the machine stopped.
  if (cancelled) "cancelled" else "failed"
}

#' What a job is, how far it is, and -- once it has ended -- what it left.
#' @noRd
.nm_job_status <- function(store, job_id) {
  folder <- .nm_job_folder(store, job_id)
  job <- .nm_read_json(file.path(folder, "job.json")) %||% list()
  state <- .nm_job_state(store, job_id)
  started <- .nm_read_json(file.path(folder, "started.json")) %||% list()
  ended <- .nm_read_json(file.path(folder, "exit.json")) %||% list()
  t0 <- started$started
  t1 <- ended$finished %||% if (state == "running") as.numeric(Sys.time()) else NULL
  job$state <- state
  job$exit_code <- ended$code
  job$elapsed_s <- if (!is.null(t0) && !is.null(t1)) round(t1 - t0, 1) else NULL
  hidden <- c("job.json", "started.json", "exit.json", "cancel", "launched")
  files <- sort(list.files(folder))
  files <- files[!grepl("\\.part$", files) & !files %in% hidden]
  job$files <- file.path(folder, files)
  if (state == "queued") {
    ids <- .nm_job_ids(store)
    ahead <- ids[ids < job_id]
    job$ahead <- sum(vapply(ahead, function(j) .nm_job_state(store, j) %in% c("queued", "running"), TRUE))
  }
  job
}

#' A job's printed output, or its last `tail` characters.
#' @noRd
.nm_job_text <- function(store, job_id, name = "stdout.txt", tail = NULL) {
  path <- file.path(.nm_job_folder(store, job_id), name)
  if (!file.exists(path)) return("")
  text <- paste(readLines(path, warn = FALSE, encoding = "UTF-8"), collapse = "\n")
  if (!is.null(tail) && nchar(text) > tail) substr(text, nchar(text) - tail + 1, nchar(text)) else text
}

#' Stop a job: one waiting never starts; one running is asked to stop, and killed
#' if it has not within .NM_CANCEL_GRACE seconds.
#' @noRd
.nm_job_cancel <- function(store, job_id) {
  folder <- .nm_job_folder(store, job_id)
  file.create(file.path(folder, "cancel"))
  started <- .nm_read_json(file.path(folder, "started.json"))
  pid <- started$pid
  if (!is.null(pid) && .nm_pid_alive(pid) && is.null(.nm_read_json(file.path(folder, "exit.json")))) {
    .nm_kill(pid, tools::SIGTERM)
    deadline <- Sys.time() + .NM_CANCEL_GRACE
    while (Sys.time() < deadline && .nm_pid_alive(pid)) Sys.sleep(0.1)
    if (.nm_pid_alive(pid)) .nm_kill(pid, tools::SIGKILL)
  }
  .nm_job_pump(store)
  .nm_job_status(store, job_id)
}

#' Start the next waiting job if none is running. Held by a lock folder, as the
#' server and a job that has just ended may both ask at once.
#' @noRd
.nm_job_pump <- function(store) {
  lock <- file.path(store$root, ".pump.lock")
  if (!dir.create(lock, showWarnings = FALSE)) {
    age <- as.numeric(Sys.time()) - as.numeric(file.mtime(lock))
    if (is.na(age) || age < 30) return(invisible(FALSE))
    unlink(lock, recursive = TRUE)  # left by a process that died holding it
    if (!dir.create(lock, showWarnings = FALSE)) return(invisible(FALSE))
  }
  on.exit(unlink(lock, recursive = TRUE), add = TRUE)
  ids <- .nm_job_ids(store)
  states <- vapply(ids, function(j) .nm_job_state(store, j), "")
  if (any(states == "running")) return(invisible(FALSE))
  queued <- ids[states == "queued"]
  if (!length(queued)) return(invisible(FALSE))
  .nm_job_launch(store, queued[1])
  invisible(TRUE)
}

.nm_job_launch <- function(store, job_id) {
  folder <- .nm_job_folder(store, job_id)
  file.create(file.path(folder, "launched"))
  rscript <- file.path(R.home("bin"), if (.Platform$OS.type == "windows") "Rscript.exe" else "Rscript")
  expr <- sprintf("normet:::.nm_job_run(%s)", deparse(folder))
  # Run from the job's folder (system2 runs in the caller's).
  old <- setwd(folder)
  on.exit(setwd(old), add = TRUE)
  system2(rscript, c("--no-save", "--no-restore", "-e", shQuote(expr)),
          stdout = file.path(folder, "stdout.txt"), stderr = file.path(folder, "stderr.txt"),
          wait = FALSE)
  invisible(TRUE)
}

#' A job's own process: run `job.R` in its folder, say how it ended, and start the
#' next job waiting.
#' @noRd
.nm_job_run <- function(folder) {
  .nm_write_json(file.path(folder, "started.json"),
                 list(pid = Sys.getpid(), started = as.numeric(Sys.time())))
  setwd(folder)
  state <- tryCatch({
    source("job.R", echo = FALSE, local = new.env(parent = globalenv()))
    "done"
  }, error = function(e) {
    call <- conditionCall(e)
    message("Error", if (!is.null(call)) paste0(" in ", deparse(call)[1]), ": ", conditionMessage(e))
    "failed"
  })
  .nm_write_json(file.path(folder, "exit.json"), list(
    state = state, code = if (state == "done") 0L else 1L, finished = as.numeric(Sys.time())
  ))
  store <- structure(list(home = dirname(dirname(folder)), root = dirname(folder)),
                     class = "nm_job_store")
  try(.nm_job_pump(store), silent = TRUE)
  invisible(state)
}

#' Wait for a job to end (for tests and scripts; a server asks its status).
#' @noRd
.nm_job_wait <- function(store, job_id, timeout = NULL, poll = 0.2) {
  deadline <- if (is.null(timeout)) NULL else Sys.time() + timeout
  while (.nm_job_state(store, job_id) %in% c("queued", "running")) {
    .nm_job_pump(store)
    if (!is.null(deadline) && Sys.time() > deadline) {
      stop(sprintf("job %s still %s", job_id, .nm_job_state(store, job_id)), call. = FALSE)
    }
    Sys.sleep(poll)
  }
  .nm_job_status(store, job_id)
}
