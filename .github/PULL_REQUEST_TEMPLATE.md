## What this changes

<!-- What the change does and why. Link the issue it addresses, e.g. "Closes #12". -->

## Checklist

- [ ] The branch is off `main` and holds one change (`feature/...`, `fix/...`, `docs/...`, `gui/...`).
- [ ] `devtools::document()` was run, and `man/` and `NAMESPACE` are up to date.
- [ ] `devtools::test()` passes, and new behaviour has a test.
- [ ] `devtools::check()` shows no new errors, warnings or notes.
- [ ] `NEWS.md` has a bullet under the version in development (for user-visible changes).
- [ ] Model-related changes work with both backends (`lightgbm` and `h2o`).
- [ ] No vendored GUI file under `gui/` was hand-edited (they come from normet-py through `gui/tools/vendor_py_gui.py`).
