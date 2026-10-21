# R GUI = normet-py's GUI on the R package — work in progress

Branch `claude/zealous-mendel-4f3qnp`. Steps 1-10 done (see Progress), uncommitted.

## Goal (from the user)

1. GUI in Chinese — **done** (commit "GUI in Chinese…", before this WIP commit).
2. Make the R GUI's interface identical to normet-py's, screen by screen — **in progress**.
3. MCP / agent tool layer for normet-r — **not started in code** (design below).
4. GUI AI Assistant and user manual — **not started** (comes with step 2: py's
   `assistant.py`, `chatview.py`, `manual.py` are already vendored).

## Approach chosen for step 2

The R GUI *is* normet-py's GUI code, vendored, with every analysis routed to R:

- `gui/tools/vendor_py_gui.py <normet-py checkout>` copies `src/normet/gui/*.py` into
  `gui/normet_r_gui/` and the pure-Python library modules it needs into
  `gui/normet_r_gui/nm/` (style, figstyle, plotting, io/tables, io/trajectory, io/gdas,
  utils/*, causal/diagnostics, causal/bands, agent/llm, agent/mcp_http,
  agent/readings), rewrites `normet` imports to `nm`, renames the QSettings key to
  `normet-r-gui`, and applies the patches in `gui/tools/r_patches.py` (fails loudly if
  a patch no longer matches). Re-run it at each future sync.
- Hand-written (not vendored), R-specific:
  - `normet_r_gui/_rpc.py` + `normet_r_gui/rpc.R`: generic call into R
    (`Rscript rpc.R request.json`); DataFrames cross as CSV + column types, models as
    `nm_save_model` folders, other R objects as .rds handles; R log lines stream into
    the window's log; `_rpc.cancel()` kills the running R process.
  - `normet_r_gui/nm/__init__.py`, `nm/_r.py`: normet-py's API (build_model,
    normalise, decompose, rolling, pdp, modStats, ml_predict, fetchers, trajectories,
    make_run, generate_html_report) implemented by calling the R functions, returning
    normet-py's shapes (date index, `(df_prep, model)`, …).
  - `nm/causal/__init__.py` (SCM estimators, placebo, bands, scm_all via R),
    `nm/causal/run_scm.py`, `nm/datasets.py`, `nm/io/__init__.py`,
    `nm/utils/__init__.py`, `nm/agent/__init__.py`.
  - `normet_r_gui/_r_shell.py`: R menu (Locate Rscript…, Check R environment), R
    status label, R cleanup on close.
  - `normet_r_gui/ui_zh_r.py`: Chinese texts only this window has.
- Backends: lightgbm (default) and h2o; py's flaml ↔ R's h2o (time budget +
  include_algos), Chronos-2 not offered (patched in `_chronos.py`).
- R package fix made for this: `nm_feature_importance()` now handles LightGBM
  (`R/nm_utils_features.r`, test in `tests/testthat/test-lightgbm.r`).

### Verified so far
- `_rpc` round trip (types, errors, models) works; R outputs of build_model,
  modStats, normalise, decompose (both methods), pdp, run_scm, placebo_in_space match
  py's column names (R gives `date` as a column; `nm/_r.py` sets it as the index).
- `MainWindow()` constructs offscreen with the vendored code.

### Next steps (in order)
1. Run the vendor script once more and check `app.py` starts (`python -m normet_r_gui`).
2. Walk each workflow offscreen against R on `my1` (as py's
   `docs/manual/make_figures.py` does): open data, train (lightgbm), normalise,
   decompose emission/meteorology, rolling, multi-scale, PDP; fix shape mismatches in
   `nm/_r.py` (weekday factor levels Mon..Sun vs py's 1..7; pdp `grid_points`/`n_cores`
   accepted by `nm_pdp`?; rolling output columns `rolling_*`).
3. SCM Studio: every backend, placebo in space/time, uncertainty bands, all units;
   patch the ML-SCM backend combo (flaml/lightgbm → lightgbm/h2o).
4. Data Studio (UK data fetch, Open-Meteo/ERA5) and Transport Studio (tdump build,
   GDAS1, HYSPLIT run, join).
5. R-specific rewrites of: `commandlog.py` (write the session as an R script of
   nm_* calls), `methods.py` (Methods paragraph naming R functions), `_session.py`
   (save/load: copy model folders into the .normet file), `_examples.py`
   (code strings in R), Help → manual link.
6. Old R-GUI files now unused: `rbridge.py`, `bridge.R` — delete once nothing imports
   them; update `pyproject.toml` package-data (`rpc.R` instead of `bridge.R`) and
   `packaging/normet_r_gui.spec`.
7. Port py's GUI tests (`tests/test_gui_*.py`) that apply; update
   `gui/tests/test_uilang.py` for the new window (tab names have no ①②③ now).
8. Screenshot both GUIs side by side (py: `docs/manual/figures/*.png`) and fix any
   remaining visual difference.
9. Then step 3 (MCP): R-native stdio JSON-RPC server `nm_mcp_server()` in the R
   package mirroring normet-py's `normet-mcp` tools (inspect_data, start_do_all,
   start_decompose, start_scm, start_cv, job_status, cancel_job, list_jobs,
   read_run, read_result, figure, write_report), jobs = R scripts run by Rscript in
   their own folders (job.json/started.json/exit.json as in normet/agent/jobs.py),
   readings as text like normet/agent/readings.py.
10. Then step 4: Assistant (vendored `assistant.py`) on that tool layer; manual for
    the R GUI (adapt py's `docs/manual/*.tex`).

## Progress (2026-10-20): steps 1-7 done, uncommitted on this branch

1. Vendor sync clean (`vendor_py_gui.py ../normet-py --check`: nothing to change);
   the window starts and asks R at startup (`_r_shell.py`).
2. Main window walked on my1 (`gui/tools/walk_gui.py`, offscreen, PNGs to
   `gui/tools/figures_<lang>/`): train, normalise, decompose both ways, rolling,
   multi-scale, PDP. Fixed: rolling shape (`nm/_r.py: rolling_shape`), PDP on the
   weekday factor (R), R's log lines at R's level in the window's log.
3. SCM Studio: every backend on ULEZ against py's manual (scm −18.15 vs −18.14;
   abadie, robust, did as py). R fixes: `nm_scm` ridge augmentation = py's exact LOO
   RidgeCV (`.nm_ridge_loo`); `nm_scm_abadie` simplex weights (quadprog);
   `nm_bayesian_scm` a working MCMC (matches py's NUTS); placebo-in-time candidate
   dates as py; H2O started only when an H2O backend runs. ML backends lightgbm/h2o.
4. Data Studio (UK AQ, Open-Meteo) and Transport Studio (tdump build, join, a stub
   HYSPLIT run and its stop) work; a real GDAS1 + HYSPLIT run not tried here.
   Stopping a run now kills what R started too (`_rpc._kill_tree`).
5. Own modules (not vendored): `commandlog.py` writes the session as R
   (`library(normet)`, `res <- nm_build_model(...)`, multi-scale as its
   `rolled_<days>` runs), recorded by dry-running each `nm/_r.py` call
   (`_rpc.capture`); `_script.py` reads a saved script back through R's parser
   (`.gui_read_calls`) and runs it (`.gui_run_script`). Patches: methods (H2O
   AutoML/LightGBM), examples (`df <- my1`), session/saved (R script), manual root.
   A session (.normet) carries its R model folders inside it (`RObject` pickling).
6. `rbridge.py`/`bridge.R` deleted; pyproject/spec/build_dmg ship `rpc.R`.
7. normet-py's GUI tests vendored into `gui/tests/` by the same script (patches
   under `tests/...` in `r_patches.py`; Chronos tests skipped); plus
   `test_commandlog.py`, `test_trajjoin.py`, `test_uilang.py`. Whole suite:
   `python -m pytest gui/tests` → 105 passed, 6 skipped.

## Progress (2026-10-20, continued): steps 8-10

8. Side by side with normet-py's `docs/manual/figures`: every screen the same. Fixed on
   the way: the R status label kept short (`R 4.4.1`, the rest in its tooltip); the
   command log's dry run no longer logs (`_rpc.capture` mutes the capturing thread);
   Cancel/close end what R started too (`_rpc._kill_tree`: HYSPLIT ran on in a
   process group of its own). Remaining differences are numbers (LightGBM/R vs
   FLAML/py) and normet-py's own newer code (its screenshots predate its "Auto"
   button).
9. `nm_mcp_server()` (R/nm_mcp_server.r) serves normet-py's 13 `normet-mcp` tools by
   the same names over stdio JSON-RPC, with no SDK; jobs are R scripts (`job.R`) run
   by Rscript in their own folders (R/nm_agent_jobs.r, `~/.normet/mcp-r`), readings
   ported from py's readings.py (R/nm_agent_readings.r, identical text on the same
   table), figures in ggplot2 (R/nm_agent_tools.r). `nm_agent_tool()` calls a tool
   from R. Checked with the MCP Python SDK's own client; tests/testthat/test-mcp.r.
   Fixed: `nm_save_run()` recursed forever on the package version.
10. The Assistant works as vendored (its tools read the window, R's results); its
    model-fit reading names nm_modStats. The manual: normet-py's two books vendored
    into `gui/docs/manual/` by the same script and rewritten by
    `gui/tools/manual_patches.py` (installation, LightGBM/H2O, no Chronos-2, R
    function names, the R command log, scripting in R and `nm_mcp_server()`,
    defaults, files, troubleshooting, this window's numbers); figures by
    `gui/tools/walk_gui.py` (now writing to docs/manual/figures, figures_zh); built
    with `gui/docs/manual/build.sh`; bundled by the spec; Help -> User Manual opens
    it (online: this repo's). py's tests/test_manual.py vendored too. Built: English
    54 pages, Chinese 57.
- Also: glmnet, declared but never called, dropped from DESCRIPTION Imports (R CMD
  check's only NOTE); `gui/` added to .Rbuildignore; the pkgdown `docs/` ignore
  anchored to the root (`/docs/`) so gui/docs/manual is tracked.
- Tests: `gui/tests` all pass file by file (6 Chronos tests skipped); R testthat
  0 failures, 668 expectations.

## Sync with normet-py main at 7111b71 (PRs #30-#38)
- Re-vendored: Log and Command Log are windows of their own (View → Log…, Command
  Log…), the Assistant takes the window's whole height and reads as a chat, result
  pages on the window's ground, Decompose keeps both methods (a Method selector; saved
  sessions keep both), Groups shown only for meteorology, Multi-scale has a Resolution.
  py's new tests come with it and pass on R.
- Manual: the "log dock" and "failed task" patches redone for py's new "The log and the
  Assistant" section; walk_gui.py grabs the Command Log window as make_figures.py does.
- Packaging: the GUI declares pyarrow, openpyxl and xlrd (Open Data reads Parquet,
  Feather and Excel through pandas here too), the spec names them as hidden imports and
  leaves torch/chronos out, build_dmg.sh checks for them. Not ported: py's
  collect_data_files (the examples come from the R package) and the NCCL exclusion
  (no xgboost here).

## Sync with normet-py main at ec16d54 (PRs #39-#42)
- The task clock (#39): the status bar says each task's time so far, share done and
  time left. py's share comes from `normet.utils.progress` reports in its library
  loops; here those loops are R's, so the reports were ported to R:
  `R/nm_utils_progress.r` (`.nm_progress_listening/_part/_report`, the same design),
  reported where py reports (normalise's batches, rolling's windows, the emission
  decomposition's steps and the attribution's coalitions, LightGBM's trials, the
  receptor times of `nm_run_back_trajectories`). rpc.R listens and writes
  `NM_PROGRESS <share>` lines; `_rpc._forward` hands them to the thread's listener
  (`nm/utils/progress.py`, vendored), not to the log. H2O's time budget takes FLAML's
  place for `TaskClock.expect`. Tests: tests/testthat/test-progress.r,
  gui/tests/test_rpc_progress.py, and py's tests/test_progress.py (its rolling test,
  of py's Python rolling, skipped).
- #40 (Data Studio always fetches meteorology), #41 (Transport Studio panel in two
  pages), #42 (About with the app's icon): re-vendored; the icon comes over byte for
  byte (`GUI_ASSETS` in vendor_py_gui.py) to `normet_r_gui/assets/`, shipped as
  package data and by the spec. Manual patches redone for the new Cancel and CDS text.
- Rolling's windows keep R's column names (`window_01`…, from 1) in the window's
  table, export and saved sessions, instead of being renamed to normet-py's
  `rolling_0`… (`nm/_r.py: rolling_shape`); the vendored lookups (`_run_analyse.py`,
  `_multiscale.py`) and the multi-scale test are patched to match.
- Then normet-py main at aeff5f3 (#43, #36): the task clock ignores a time budget given
  with no task running (vendored with its test); #36 is py's own figures and PDFs.

## Local setup used here
- R 4.3 + normet installed from this repo (`R CMD INSTALL .`), lightgbm R package
  built from GitHub source (`Rscript build_r.R` in microsoft/LightGBM).
- `pip install -e gui pytest`, plus normet-py (`pip install -e ../normet-py[gui]`) only
  to compare outputs.
