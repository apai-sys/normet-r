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
  include_algos). Chronos-2 is not in this window: `_chronos.py` is not vendored, and
  `r_patches.py` takes out everything that read it (backend, device, fine-tuning,
  seeded rows, Model tab, Methods sentence, the SCM Studio's similarity ranking,
  its Chinese texts and tests; the manual's Chronos sections too).
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
   under `tests/...` in `r_patches.py`; Chronos tests removed); plus
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
- Tests: `gui/tests` all pass file by file (the 6 Chronos tests removed); R testthat
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
  leaves torch/chronos out (build_dmg.sh too), build_dmg.sh checks for them. Not ported: py's
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

## Sync with normet-py gui/assistant-like-cume (#48) and gui/data-overview
- The Assistant as cume's (next message on Tab, Apply that trains, copies, find, the
  status line, the whole API as tools, cume's harness) comes over as it is. Its
  carry_out and api_help run R here: `normet_r_gui/_code.py` is this window's own
  (SKIP_GUI), calling rpc.R's `.gui_run_code` (the code in an env with df, df_prep,
  model) and `.gui_api_help` (the package's Rd pages). Test: tests/test_r_assistant.py.
- normet-py #44-#47 adopted R's window names: the window-name patches are gone;
  `nm.window_column(s)` stand in for normet.analysis.rolling's; nm_rolling pads to two
  digits at least, as normet-py does.
- Start-up: `packaging/launcher.py` is normet-py's (a kept font cache, a splash):
  21.5 s to the window before, 3.0 s after (measured on the DMG).
- The Data tab (overview with rows picked and left out, cycles, wind, statistics) is
  vendored; the rows left out are written by this window's own `commandlog.exclude`
  as R (`df_kept <- df[!left_out, , drop = FALSE]`).
- Bilingual as cume's (normet-py #49): the report's language is picked under File →
  Export HTML Report or the HTML report button (kept in this window's settings,
  `normet-r-gui`); uilang's label heads and multi-line texts; a Chinese walk of the
  window leaves only names and codes in English. ui_data.png grabbed from this window
  (both languages).
- workers.py: a task's thread that ended after its window was gone raised "Signal
  source has been deleted" (the end of the transport tests); fixed in normet-py.

## Sync with normet-py main at af8bf22 (PRs #52, #53, #56, #57)
- Vendor source is the committed tree at `af8bf22`, extracted with `git archive`
  (the normet-py working tree carries uncommitted uncertainty-tab work that is not
  ported; its delta over af8bf22 is only that tab).
- R core first: `nm_trend` / `nm_trend_breaks` (Mann-Kendall with the seasonal variant,
  Theil-Sen with the Sen 1968 interval, the AR(1) residual diagnostic, the moving-block
  bootstrap; the segmented fit is a greedy search gated by BIC and by the block-bootstrap
  p of the search over every candidate position), `nm_verification`, `nm_uncertainty`;
  the agent readings and tools, the MCP registration; the testthat suite green.
- The GUI re-vendors af8bf22: `_trend.py` (the series, the auto seasonal, the verdicts,
  the figures), the Trend tab and its box, the runner's `_run_trend` (segments 1 is the
  single-slope test, 2-4 the segmented fit, which moves an emission-part choice to the
  separated long-term trend), the session's saved trend result, the Assistant's trend
  tools, the methods paragraph. normet-py's own GUI tests come over too
  (`tests/test_gui_trend.py`), running R here.
- R-own: `nm/analysis/trend.py` holds normet-py's dataclasses as they are (the window
  reads the results as those, and `_saved.py` checks their names); `nm/_r.py`'s
  `trend` / `detect_trend_breaks` call `nm_trend` / `nm_trend_breaks`. A datetime-indexed
  series crosses as a frame with its date column and the series' own column (a bare
  vector would lose its index); a positional one crosses as its values.
- `rpc.R` encodes the `nm_trend*` results plain (the window's dataclasses read them; a
  classed object would cross as an .rds handle); `commandlog` writes
  `nm_trend(df_prep, value_col = "column", ...)` in place of the window's constructed
  series (`'long-term'` is the separated component R computes from `date_unix + emi_base`).
- `r_patches.py`: the trend's chronos tooltip and the Assistant's two chronos guards
  (the vendored trend tools call the deleted `_is_chronos`), the methods paragraph's R
  names, the readings' R names. `vendor_py_gui.py` fixed: its import rewrite added a
  superfluous dot to a library module's dotted subpaths (`nm/agent/readings.py`'s trend
  import came back as `...analysis.trend`); `nm/__init__.py` now exports
  `scm_diagnostics` at the top level, as normet-py's `normet` does (the readings reach
  it there).
- The manual: the run-buttons table re-patched for af8bf22 (its new trend row, the
  Chronos rows out); the English book was missing the trend section's cross-reference
  the Chinese one has (af8bf22's own mismatch); the trend section's quoted numbers and
  both screenshots are this window's (`walk_gui.py` gained the trend walk, and restores
  the visible tab before the decomposition's figure, where the ticked
  run-after-each-decomposition tick has already started the trend).

## Sync with normet-py main at 0569833 (PRs #58, #59, #60)
- Only PR #58 (the uncertainty step in the window) has a part for this window. PRs #59
  and #60 (quantile calibration on a held-out span, and the counterfactual's
  calibrated band) are `foundation`-only — they calibrate Chronos-2's zero-shot
  quantile bands and are used by nothing the window or the R package can reach — so
  they are not ported. The vendor source is the committed tree at `0569833`
  (`git archive`); the GUI files it copies differ from af8bf22's by exactly #58's.
- The R core was already here from af8bf22 (`nm_uncertainty.r`, its result class with
  summary/as.data.frame/plot/print, tests green). Fixed on the way:
  `nm_decompose_uncertainty` now hands `nm_prepare_data` only the external covariates
  and checks the full list after preparing, as `nm_build_model` does — the window
  names the calendar columns with the met ones and they are not in the raw table.
- The GUI re-vendors #58: `_uncertainty.py` (the tab's words and verdicts), the
  Uncertainty box under Trend on the Decompose page (Models, Samples, Member
  backend), the Uncertainty tab and its light, the runner's `_run_unc`, the session's
  saved run and its config rows, the Methods lines. normet-py's own GUI test comes
  over too (`tests/test_gui_uncertainty.py`), running R here — and it runs: the
  window's covariates, three members and their verdicts come from R.
- R-own: `nm/analysis/uncertainty.py` holds normet-py's `UncDecomposition` as it is
  (the tab reads its `summary()`/`plot()`; the saved session pickles it whole);
  `nm/_r.py`'s `decompose_uncertainty` calls `nm_decompose_uncertainty` and fills it.
  `rpc.R` encodes `nm_unc_decomposition` plain, like the trend results (a classed
  object would cross as an .rds handle); `commandlog` writes
  `nm_decompose_uncertainty(df, target = "column", ...)`.
- `r_patches.py`: the Member backends are lightgbm/h2o (normet-py's lightgbm/flaml)
  and h2o's budget is its runtime, as on the Train page; the step's and the enable
  rule's chronos guards go (the vendored code calls the deleted `_is_chronos`); the
  Methods paragraph says R's name and cites H2O where normet-py cites FLAML; the
  Chinese line of the chronos refusal goes. The vendored test: the chronos row goes,
  and its flaml settings are this window's h2o.
- The manual: the Uncertainty section lands in both books with R's names, h2o for
  flaml and `nm_do_all_unc` for py's pipeline; its quoted numbers and both
  screenshots are this window's own (`walk_gui.py` gained the uncertainty walk: MY1,
  three members sharing 50 draws, lightgbm). The API table row for
  `nm_decompose_uncertainty` is written inside the scripting passage's rewrite,
  which covers that chapter's function table whole — the copied row falls inside it.

## Sync with normet-py main at 48bee46 (PR #61: the SCM pre-trend test)

- PR #61 is `causal`-side and portable: `pre_trend_test`, the pre-period
  parallel-trends check (the OLS slope of the pre-period residuals with its
  classical two-sided t-test, and the RMSPE of the final third over that of
  the first two thirds, read together as a traffic light). It touches no GUI
  file; it lands in the window through the already-vendored `causal/diagnostics.py`
  and `agent/readings.py`.
- GUI: `causal/prediagnostics.py` joins the vendor LIBRARY (it is pure
  numpy/pandas, its scipy import lazy like the trend module's), so
  `scm_diagnostics` gains `pre_trend` and the vendored reading quotes it
  unchanged; `nm/causal/__init__.py` and `nm/__init__.py` export `pre_trend_test`
  and `PreTrend` the way normet-py's `normet` does.
- R core: `R/nm_causal_pre_trend.r` ports `pre_trend_test` (and the `PreTrend`
  dataclass as a classed list with a `print` method) — the t-test is `pt()`,
  so the R port needs no scipy; the verdict strings are normet-py's bytes,
  `nan`/`inf` included. `nm_scm_diagnostics` gained the `pre_trend` element and
  the R agent's SCM reading the two rows and the verdict line (mirroring the
  `readings.py` diff). `rpc.R` encodes `nm_pre_trend` plain, as it does the
  other classed results.
- Tests: `tests/testthat/test-pre-trend.r` mirrors `tests/test_prediagnostics.py`
  on the same fixture (the clean panel stays quiet; an injected ramp fails;
  late noise says caution-deteriorates; a bare frame and a list read the same;
  four pre-period points are `insufficient`; `nm_scm_diagnostics` and
  `nm_run_scm` feed it).

## Sync with normet-py main at 6e8555d (PR #62: the event-study figure)

- PR #62 adds `plot_event_study` to `causal/bands.py` — the visual companion
  of #61's pre-trend test — and touches no GUI file and no manual file (its
  guide and notebook changes are not vendored). The window takes it with the
  re-vendored `bands.py`; `nm/causal/__init__.py` exports it beside the other
  bands figures (the window's `nm/__init__` top level mirrors only what the
  readings reach, and `effect_bands_*` never did, so neither does this).
- R core: `nm_plot_event_study()` in `R/nm_causal_bands.r`, a ggplot mirror —
  event time (a period count), pre-period `neutral` and post-period
  `modelled`, the band's `lw=0` alpha-0.18 ribbon over the post period only,
  `.zero_line()` and `.cutoff_line(0)`, the labels through `.say()`. A
  date-carrying band matches post rows on the shared epoch scale (a Date band
  meets a POSIXct frame); an event-time band aligns by row position, as in
  normet-py. `tests/testthat/test-event-study.r` mirrors the four
  `test_bands.py` additions (event-time split, ci_lo/ci_hi winning, date
  alignment, the four rejections).

## Local setup used here
- R 4.3 + normet installed from this repo (`R CMD INSTALL .`), lightgbm R package
  built from GitHub source (`Rscript build_r.R` in microsoft/LightGBM).
- `pip install -e gui pytest`, plus normet-py (`pip install -e ../normet-py[gui]`) only
  to compare outputs.
