# Contributing to normet

## Workflow

1. Fork the repo and create a feature branch from `main`.
2. Make your changes, following existing code conventions.
3. Run `R CMD check` and ensure 0 ERROR, 0 WARNING.
4. Add/update tests in `tests/testthat/` for any new or changed functionality.
5. Run the full test suite: `devtools::test()`.
6. Submit a pull request.

## Code Style

- `styler::style_pkg(strict = FALSE)` before committing.
- `lintr::lint_package()` should pass without errors.
- Use roxygen2 for documentation: write `@param`, `@return`, `@export` as needed.
- Run `devtools::document()` after adding/changing docs.

## Testing

- All tests use testthat 3rd edition.
- New features must include at least one test.
- Tests should run without requiring external data or network access.
- Use `skip_if_not_installed("lightgbm")` in lightgbm-specific tests.

## Backend Support

- When adding features that interact with models, ensure both `lightgbm` and `h2o` backends are supported.
- Default backend is `"lightgbm"`; `"h2o"` must continue to work.
