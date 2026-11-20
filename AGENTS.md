# AGENTS.md

Instructions for coding agents working in this repository.
They hold for every session and survive context compaction, so read them again before
acting on a terse prompt such as "continue".

## Where you are

- The repository is `/Users/user/normet-r` (remote `origin` = github.com/apai-sys/normet-r).
  The R package (`normet`) is at the root; the desktop GUI is under `gui/` (Python +
  PySide6). Work only here.
- Python for the GUI: `/Users/user/miniforge3/envs/normet/bin/python` (conda env
  `normet`). R is on `PATH` as `Rscript`. The GUI drives R through an RPC bridge
  (`gui/normet_r_gui/nm/_r.py`), so GUI tests spawn R child processes.
- The GUI is **vendored from the sibling repo** `normet-py` (`/Users/user/normet-py`):
  `gui/tools/vendor_py_gui.py <normet-py>` copies normet-py's GUI modules and GUI tests
  into `gui/normet_r_gui/` and `gui/tests/`, then applies the R-specific patches in
  `gui/tools/r_patches.py`. Run `vendor_py_gui.py <normet-py> --check` to see what would
  change (the sync gate: `0 of 103 file(s) would change`). Do not hand-edit vendored files
  — change them in normet-py and re-vendor.

## The two kinds of change

- **R-own** — the analyses themselves live in `gui/normet_r_gui/nm/` (`__init__.py`,
  `_r.py`): training, normalising, decomposing, SCM, trajectories, fetching. These run on
  the `normet` R package and are this repo's own work, not vendored.
- **Synced from normet-py** — the window (all of `gui/normet_r_gui/*.py` except `nm/`),
  the GUI tests, and the manual. These arrive via vendoring plus `r_patches.py` (what this
  window does differently because it runs R) and `manual_patches.py` (the manual's numbers
  are patched to this window's own run).

## The package and CRAN

- The root R package is the CRAN-bound artefact. Its version lives in `DESCRIPTION`
  (0.3.0 — the first CRAN release, submitted 2026-11-20 and with CRAN for pretest and
  review) and must match `CITATION.cff` and the top `NEWS.md` heading.
- Before a release, build and check the tarball, upload the same file to win-builder for
  R-devel (the form at win-builder.r-project.org), and confirm the `R-CMD-check` matrix
  is green on the commit:

  ```bash
  R CMD build .
  R CMD check --as-cran normet_0.3.0.tar.gz
  ```

  Expect 0 ERROR and 0 WARNING on both. The NOTEs are the ones explained in
  `cran-comments.md` (a new submission; on this Mac, future file timestamps and local
  HTML Tidy); read win-builder's log from the email it sends.
- `cran-comments.md` is the submission's comment file — keep it in step with the check
  results. It, `AGENTS.md` and the built tarballs are kept out of the package by
  `.Rbuildignore`.
- Submit the checked tarball rather than rebuilding:
  `Rscript -e 'devtools:::upload_cran(devtools::as.package("."), normalizePath("normet_0.3.0.tar.gz"))'`
  (`devtools::submit_cran()` prompts interactively and rebuilds). CRAN then mails a
  confirmation link to the maintainer; once confirmed, the package appears in
  `https://cran.r-project.org/incoming/` (`pending/`, then `pretest/`). Answer reviewer
  mail from the `DESCRIPTION` maintainer address.

## Verification gate

Run before saying a change is done, and report the actual output:

```bash
PY=/Users/user/miniforge3/envs/normet/bin/python
cd gui && $PY tools/vendor_py_gui.py ../../normet-py --check   # 0 of 103 would change
cd gui && OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1 $PY -m pytest -q -p no:cacheprovider tests/
```

The GUI suite baseline is **260 passed / 1 skipped** (the 8a85d39 sync brought it to
257; 69144ad added the FLAML-clock test and its R-script counterpart; the H2O
model-bound change adds the legacy-seconds read-back of a recorded call). The SCM test
`test_gui_scm_inference.py::test_the_fit_checks_run_on_the_example`, which used to hit a
QThread `numpy.linalg.inv` bus error on this Mac, now passes: the vendored pre-trend
slope's SE is closed-form (`nm/causal/prediagnostics.py`). A single R-RPC test can flake
on a transient socket/port error (`creation of server socket failed`); re-run just that
test to confirm it is transient before treating it as a regression.

## The figure walks and the manual

- `gui/tools/walk_gui.py` drives the real window and redraws every manual figure (EN to
  `gui/docs/manual/figures/`, ZH with `NORMET_UI_LANGUAGE=zh` to `figures_zh/`). Each walk
  takes ~35 min — run it in the background.
- **Known walk flake:** under heavy concurrent load (e.g. a DMG build) the multi-scale step
  can get a 0-byte result CSV from an R child (`EmptyDataError` in `_rpc._read_df`). Re-run
  the walk on a quiet machine; a replay of the same call succeeds.
- Rebuild the books with `cd gui && bash docs/manual/build.sh en|zh`. The R numbers
  legitimately differ from normet-py's (the analyses run on R); the manual captions are
  number-patched to this window's own printout, which must stay unchanged across a sync.

## CI

- `R-CMD-check` and `Build GUI` run a 3-OS matrix. On ubuntu, R-CMD-check's *Test
  coverage* step uploads to Codecov, which can stall or fail with `Can't request an
  upload from Codecov.` after the R package's own tests pass (`FAIL 0 | PASS 1120`).
  The step is `continue-on-error` with a 20-minute timeout: leave the ubuntu job to
  finish; it no longer needs cancelling. For `Build GUI`, cancel it early — its ubuntu
  smoke test gates the whole matrix.

## Conventions

- Keep tooling out of the repository's record: commit messages carry no attribution
  trailer, branch names are plain, and prose names a coding tool only where the feature
  is about it (the MCP server, the GUI assistant's backends). The GitHub contributors
  list must stay free of tooling.
- One sync per normet-py main commit; record it in `gui/PORTING_PLAN.md` (what changed, the
  py sha, the walk/PDF/suite results).
- The result tabs and the status-bar step lights follow the workflow's order — the
  Decompose-page questions (Multi-scale, Trend, Events, Uncertainty) sit directly after
  Decompose, then the separate steps Rolling and PDP. That order is encoded in the vendored
  `_shell.py` (`_build_tabs`, `STEP_LIGHTS`) and `_session.py` (`_TAB_KEYS`); keep the
  manual's step-light sentences in step with it.
- Code and comments are in English; the manual is published in English and Chinese.
