# ci(debug): run the testthat files one at a time, streaming a START/DONE line
# per file, so a hung file is visible as the last START with no DONE.
# Run from the repo's tests/ directory: Rscript ../tools/debug_stream_tests.R
library(testthat)
library(normet)
fls <- sort(list.files("testthat", pattern = "^test.*[.][rR]$"))
for (f in fls) {
  cat(sprintf("=== START %s %s\n", format(Sys.time(), "%H:%M:%S"), f))
  flush.console()
  r <- test_file(file.path("testthat", f), package = "normet", reporter = "summary")
  cat(sprintf("=== DONE  %s %s\n", format(Sys.time(), "%H:%M:%S"), f))
  flush.console()
}
