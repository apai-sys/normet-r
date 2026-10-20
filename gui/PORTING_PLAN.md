# R GUI = normet-py's GUI on the R package — work in progress

Branch `claude/zealous-mendel-4f3qnp`. Last pushed state: **WIP, not yet runnable end to end.**

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

## Local setup used here
- R 4.3 + normet installed from this repo (`R CMD INSTALL .`), lightgbm R package
  built from GitHub source (`Rscript build_r.R` in microsoft/LightGBM).
- `pip install -e gui pytest`, plus normet-py (`pip install -e ../normet-py[gui]`) only
  to compare outputs.
