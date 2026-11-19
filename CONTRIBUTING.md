# Contributing to normet

Thank you for helping to improve normet. This guide covers how to report
problems, how to set up a development copy, and what a pull request needs before
it can be merged.

Everyone taking part in this project must follow the
[Code of Conduct](CODE_OF_CONDUCT.md). To report a security problem, follow
[SECURITY.md](SECURITY.md) and do not open a public issue.

## Issues

- **Bugs:** open an issue using the *Bug report* template. Include a minimal
  reproducible example (the [reprex](https://reprex.tidyverse.org) package helps),
  your `sessionInfo()`, and the backend you used (`lightgbm` or `h2o`).
- **Features:** open an issue using the *Feature request* template before you
  write a large change, so the design can be agreed first.
- **Questions** about using the package are welcome as issues too.

## Development setup

```r
# install.packages(c("devtools", "lintr", "styler"))
# From a clone of https://github.com/apai-sys/normet-r
devtools::install_deps(dependencies = TRUE)   # Imports and Suggests
devtools::load_all()
```

The default modelling backend is LightGBM (`install.packages("lightgbm")`). To
work on the H2O backend you also need `install.packages("h2o")` and a Java
runtime.

## The development cycle

```r
devtools::document()   # regenerate man/ and NAMESPACE from the roxygen comments
devtools::test()       # the testthat suite
devtools::check()      # R CMD check: aim for 0 errors, 0 warnings, 0 notes
lintr::lint_package()  # uses the repository's .lintr
```

- Documentation is written in roxygen2 (with Markdown) in `R/`. Never edit
  `man/*.Rd` or `NAMESPACE` by hand. Use `@param`, `@return`, `@export` and
  `@examples` as needed. Mark helpers that are not exported with
  `@keywords internal`.
- Tests use testthat (3rd edition) and live in `tests/testthat/`. Every new
  feature or bug fix needs at least one test. Tests must run without network
  access or external data. Guard backend-specific tests with
  `skip_if_not_installed("lightgbm")` or `skip_if_not_installed("h2o")`.
- Features that train or use models must work with both backends. LightGBM is
  the default, and `"h2o"` must keep working.
- Format code with `styler::style_pkg(strict = FALSE)` before committing.
- Every user-visible change gets a bullet in `NEWS.md`, under the version that
  is in development (the top section).

## Documentation website

The pkgdown site is configured in `_pkgdown.yml`. Long-form articles live in
`vignettes/articles/`, and the getting-started vignette is `vignettes/normet.Rmd`.
To check and preview the site locally:

```r
pkgdown::check_pkgdown()   # every exported topic is in the reference index
pkgdown::build_site()      # writes docs/, which is git-ignored
```

## The desktop GUI (`gui/`)

The desktop GUI is a Python/PySide6 app, and most of it is **vendored** from
the sibling project [normet-py](https://github.com/apai-sys/normet-py):
`gui/tools/vendor_py_gui.py` copies normet-py's GUI modules and tests into
`gui/normet_r_gui/` and `gui/tests/`, then applies the R-specific patches in
`gui/tools/r_patches.py`.

- **Do not hand-edit vendored files.** Make the change in normet-py, then
  re-vendor it. Running `vendor_py_gui.py <path-to-normet-py> --check` shows
  what would change.
- The analyses the GUI runs on R (`gui/normet_r_gui/nm/`) belong to this
  repository and can be changed here.

## Branches, commits and pull requests

1. Fork the repository and create one branch per change, off `main`. Name it
   by kind: `feature/...`, `fix/...`, `docs/...`, `gui/...`.
2. Write commit subjects as plain sentences that describe the behaviour, with an
   optional area prefix as in the existing log (for example `gui:`, `tests:`,
   `trajectory:`, `fix(h2o):`).
3. Make sure `devtools::document()`, `devtools::test()` and `devtools::check()`
   pass, and that `NEWS.md` is updated.
4. Open a pull request against `main` and fill in the template. CI runs
   `R CMD check` on Linux, macOS and Windows.

By contributing, you agree that your contributions are licensed under the
project's [GPL-3 licence](LICENSE.md).
