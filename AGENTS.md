# AGENTS.md

Instructions for coding agents (opencode, Claude Code, ...) working in this repository.
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
  change (the sync gate: `0 of 98 file(s) would change`). Do not hand-edit vendored files
  — change them in normet-py and re-vendor.

## The two kinds of change

- **R-own** — the analyses themselves live in `gui/normet_r_gui/nm/` (`__init__.py`,
  `_r.py`): training, normalising, decomposing, SCM, trajectories, fetching. These run on
  the `normet` R package and are this repo's own work, not vendored.
- **Synced from normet-py** — the window (all of `gui/normet_r_gui/*.py` except `nm/`),
  the GUI tests, and the manual. These arrive via vendoring plus `r_patches.py` (what this
  window does differently because it runs R) and `manual_patches.py` (the manual's numbers
  are patched to this window's own run).

## Verification gate

Run before saying a change is done, and report the actual output:

```bash
PY=/Users/user/miniforge3/envs/normet/bin/python
cd gui && $PY tools/vendor_py_gui.py ../normet-py --check   # 0 of 98 would change
cd gui && OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1 $PY -m pytest -q -p no:cacheprovider tests/
```

The GUI suite baseline is **237 passed / 1 skipped**. A single R-RPC test can flake on a
transient socket/port error (`creation of server socket failed`); re-run just that test to
confirm it is transient before treating it as a regression.

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

## CI (skip ubuntu)

- `R-CMD-check` and `Build GUI` run a 3-OS matrix. **ubuntu hangs** (a known, unrelated
  issue): once `macos-latest` and `windows-latest` both pass, cancel the run to drop the
  stuck ubuntu job. For `Build GUI`, cancel it early — its ubuntu smoke test gates the whole
  matrix.

## Conventions

- One sync per normet-py main commit; record it in `gui/PORTING_PLAN.md` (what changed, the
  py sha, the walk/PDF/suite results).
- The result tabs and the status-bar step lights follow the workflow's order — the
  Decompose-page questions (Multi-scale, Trend, Events, Uncertainty) sit directly after
  Decompose, then the separate steps Rolling and PDP. That order is encoded in the vendored
  `_shell.py` (`_build_tabs`, `STEP_LIGHTS`) and `_session.py` (`_TAB_KEYS`); keep the
  manual's step-light sentences in step with it.
- Code and comments are in English; the manual is published in English and Chinese.
