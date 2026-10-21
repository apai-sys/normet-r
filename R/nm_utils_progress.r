# How far a long call has come, for whoever is listening (the GUI's status bar).
#
# The R side of normet-py's normet.utils.progress. A loop reports its steps with
# .nm_progress_report(); nothing is done unless a caller has asked to hear
# (.nm_progress_listening()), so a script pays nothing for it. A call made as one part
# of a larger one (.nm_progress_part()) reports within its share of the whole, so the
# listener always hears the share of the whole that is done. Parallel workers report
# nothing: the state is the R session's own.

.nm_progress <- new.env(parent = emptyenv())
.nm_progress$listener <- NULL
#: The share of the whole the call reporting now covers, as c(from, to).
.nm_progress$span <- c(0, 1)

# Have `listener` hear the share done (0 to 1) of the calls made within `expr`.
.nm_progress_listening <- function(listener, expr) {
  old <- list(listener = .nm_progress$listener, span = .nm_progress$span)
  on.exit({
    .nm_progress$listener <- old$listener
    .nm_progress$span <- old$span
  })
  .nm_progress$listener <- listener
  .nm_progress$span <- c(0, 1)
  expr
}

# The calls within `expr` as the `index`-th (from 0) of `count` equal parts of the
# current one.
.nm_progress_part <- function(index, count, expr) {
  old <- .nm_progress$span
  on.exit(.nm_progress$span <- old)
  width <- (old[2] - old[1]) / max(count, 1)
  .nm_progress$span <- c(old[1] + width * index, old[1] + width * (index + 1))
  expr
}

# `done` of `total` steps of the current call are done.
.nm_progress_report <- function(done, total) {
  listener <- .nm_progress$listener
  if (is.null(listener) || total <= 0) return(invisible(NULL))
  span <- .nm_progress$span
  listener(span[1] + (span[2] - span[1]) * min(max(done / total, 0), 1))
  invisible(NULL)
}
