"""What this window does differently from normet-py's, as patches to its copied modules.

``PATCHES[file]`` is a list of ``(label, old, new)``: ``old`` must occur exactly once in
the copied file (imports already pointed at ``nm``), and is replaced by ``new``. See
``vendor_py_gui.py``. Each is here because the window runs the R package: its backends
are lightgbm and H2O (normet-py's flaml and Chronos-2 have no R counterpart), it keeps
its settings and its catalogue of Chinese texts beside normet-py's, and it says R where
normet-py says Python.
"""

PATCHES: dict[str, list[tuple[str, str, str]]] = {}


def patch(file: str, label: str, old: str, new: str) -> None:
    PATCHES.setdefault(file, []).append((label, old, new))


# -- the language: this window's settings and its own texts ------------------------------
patch(
    "uilang.py",
    "catalogue",
    """        from . import ui_zh

        return build_catalogue(ui_zh.TEXTS, ui_zh.INNER, ui_zh.DATE_PARTS, sentences=False)""",
    """        from . import ui_zh, ui_zh_r

        # normet-py's catalogue, kept as it is there, and this window's own texts over it.
        texts = {**ui_zh.TEXTS, **ui_zh_r.TEXTS}
        return build_catalogue(texts, ui_zh.INNER, ui_zh.DATE_PARTS, sentences=False)""",
)

# -- Chronos-2: not offered ----------------------------------------------------------------
patch(
    "_chronos.py",
    "availability",
    '''    missing = [p for p in ("chronos", "torch") if importlib.util.find_spec(p) is None]
    if missing:
        return False, (
            f"Chronos-2 needs the 'foundation' extra ({', '.join(missing)} not installed).\\n"
            "Install with:  pip install normet[foundation]"
        )
    return True, ""''',
    '''    return False, (
        "Chronos-2 is normet-py's foundation model (PyTorch); the R package has none.\\n"
        "Use normet-py's window for it."
    )''',
)

# -- Step 1: the R package's backends, lightgbm (default) and H2O AutoML -----------------------
patch(
    "_panel_train.py",
    "backends",
    '''        self.backend_combo.addItems(["flaml", "lightgbm", _chronos.BACKEND])
        self.backend_combo.setToolTip(
            "flaml = AutoML search (uses the time budget below).\\n"
            "lightgbm = LightGBM with random hyperparameter search.\\n"
            "chronos-2 = zero-shot foundation model; nothing is trained."
        )
        chronos_ok, chronos_why = _chronos.chronos_availability()
        if not chronos_ok:
            # Grey the option out rather than letting the pick raise ImportError.
            item = self.backend_combo.model().item(2)
            item.setEnabled(False)
            item.setToolTip(chronos_why)
''',
    '''        self.backend_combo.addItems(["lightgbm", "h2o"])
        self.backend_combo.setToolTip(
            "lightgbm = LightGBM with random hyperparameter search (fast, default).\\n"
            "h2o = H2O AutoML search (uses the time budget below; needs Java and the h2o R package)."
        )
''',
)
patch(
    "_panel_train.py",
    "budget",
    '''        self.budget_spin.setRange(5, 36_000)
        self.budget_spin.setValue(60)
        self.budget_spin.setSuffix(" s")
        self.budget_spin.setToolTip("AutoML search time (flaml backend).")
        self._budget_label = QLabel("Time budget")
        self._budget_values = {"flaml": 60, "lightgbm": 20}
        self._prev_backend = "flaml"''',
    '''        self.budget_spin.setRange(1, 500)
        self.budget_spin.setValue(20)
        self.budget_spin.setToolTip("Random hyperparameter-search trials (LightGBM backend).")
        self._budget_label = QLabel("Search trials")
        self._budget_values = {"h2o": 60, "lightgbm": 20}
        self._prev_backend = "lightgbm"''',
)
patch(
    "_panel_train.py",
    "estimators",
    '''        # flaml only: which AutoML estimators to search over.
        self.estimator_list = QListWidget()
        self.estimator_list.setSelectionMode(QAbstractItemView.SelectionMode.NoSelection)
        self.estimator_list.setMaximumHeight(96)
        self.estimator_list.setToolTip(
            "AutoML estimators flaml may try (searched within the time budget).\\n"
            "lgbm is the fastest and usually sufficient; tick more to widen the search."
        )
        for name, tip in [
            ("lgbm", "LightGBM (default, fast)"),
            ("xgboost", "XGBoost"),
            ("xgb_limitdepth", "XGBoost, depth-limited"),
            ("rf", "Random forest"),
            ("extra_tree", "Extra trees"),
            ("histgb", "Histogram gradient boosting (sklearn)"),
        ]:
            item = QListWidgetItem(name)
            item.setFlags(item.flags() | Qt.ItemFlag.ItemIsUserCheckable)
            item.setCheckState(Qt.CheckState.Checked if name == "lgbm" else Qt.CheckState.Unchecked)
            item.setToolTip(tip)
            self.estimator_list.addItem(item)
        self._estimator_label = QLabel("Estimators")
        form.addRow(self._estimator_label, self.estimator_list)''',
    '''        # H2O only: which AutoML algorithms to search over (include_algos).
        self.estimator_list = QListWidget()
        self.estimator_list.setSelectionMode(QAbstractItemView.SelectionMode.NoSelection)
        self.estimator_list.setMaximumHeight(96)
        self.estimator_list.setToolTip(
            "H2O AutoML algorithms to search over (include_algos), within the time budget.\\n"
            "GBM is the fastest and usually sufficient; tick more to widen the search."
        )
        for name, tip in [
            ("GBM", "Gradient boosting machine (default, fast)"),
            ("DRF", "Distributed random forest (+ extremely randomised trees)"),
            ("GLM", "Generalised linear model (elastic net)"),
            ("DeepLearning", "Feed-forward neural network"),
            ("XGBoost", "XGBoost (not available on Apple-Silicon H2O builds)"),
            ("StackedEnsemble", "Ensemble of the other models (needs ≥ 2 base models)"),
        ]:
            item = QListWidgetItem(name)
            item.setFlags(item.flags() | Qt.ItemFlag.ItemIsUserCheckable)
            item.setCheckState(Qt.CheckState.Checked if name == "GBM" else Qt.CheckState.Unchecked)
            item.setToolTip(tip)
            self.estimator_list.addItem(item)
        self._estimator_label = QLabel("Algorithms")
        form.addRow(self._estimator_label, self.estimator_list)
        self._estimator_label.setVisible(False)  # lightgbm first: no search space to pick
        self.estimator_list.setVisible(False)''',
)
patch(
    "_panel_train.py",
    "backend switch",
    '''        if backend == "flaml":
            self._budget_label.setText("Time budget")
            self.budget_spin.setRange(5, 36_000)
            self.budget_spin.setSuffix(" s")
            self.budget_spin.setToolTip("AutoML search time (flaml backend).")''',
    '''        if backend == "h2o":
            self._budget_label.setText("Time budget")
            self.budget_spin.setRange(5, 36_000)
            self.budget_spin.setSuffix(" s")
            self.budget_spin.setToolTip("AutoML search time (H2O backend: max_runtime_secs).")''',
)
patch(
    "_panel_train.py",
    "estimators shown",
    '''        is_flaml = backend == "flaml"
        self._estimator_label.setVisible(is_flaml)
        self.estimator_list.setVisible(is_flaml)''',
    '''        is_h2o = backend == "h2o"
        self._estimator_label.setVisible(is_h2o)
        self.estimator_list.setVisible(is_h2o)''',
)
patch(
    "_run_train.py",
    "model config",
    '''        if backend == "flaml":
            model_config = {
                "time_budget": self.budget_spin.value(),
                "estimator_list": self._selected_estimators() or ["lgbm"],
            }''',
    '''        if backend == "h2o":
            model_config = {
                "max_runtime_secs": self.budget_spin.value(),
                "include_algos": self._selected_estimators() or ["GBM"],
            }''',
)
patch(
    "_run_train.py",
    "task clock: H2O's budget",
    '''        if backend == "flaml":
            # FLAML searches for as long as it is given: its share done is the time.''',
    '''        if backend == "h2o":
            # H2O searches for as long as it is given: its share done is the time (LightGBM
            # reports its trials from R).''',
)


# -- the shell: the R menu, R's state, R cleaned up on close -------------------------------
patch(
    "main_window.py",
    "R mixin",
    "class MainWindow(\n    InputsMixin,",
    "class MainWindow(\n    RShellMixin,\n    InputsMixin,",
)
patch(
    "main_window.py",
    "R mixin import",
    "from ._shell import ShellMixin",
    "from ._r_shell import RShellMixin\nfrom ._shell import ShellMixin",
)
patch(
    "main_window.py",
    "R cleanup",
    "        self.runner.shutdown()\n        if self._scm_window is not None:",
    "        self.runner.shutdown()\n        self._close_r()\n        if self._scm_window is not None:",
)
patch(
    "_shell.py",
    "R menu",
    '        wm = mb.addMenu("&Window")',
    '        self._build_r_menu(mb)\n\n        wm = mb.addMenu("&Window")',
)
patch(
    "_shell.py",
    "about",
    '''        version = QLabel(f"Version {normet.__version__}")''',
    '''        version = QLabel(f"Version {normet.__version__} (R)")''',
)
patch(
    "_shell.py",
    "about: what",
    '''            "Normalisation, decomposition and counterfactual modelling "
            "for environmental time series."''',
    '''            "Normalisation, decomposition and counterfactual modelling "
            "for environmental time series, run on the normet R package."''',
)
patch(
    "_widgets.py",
    "icon",
    'return str(files("normet.gui").joinpath("assets", "normet.png"))',
    'return str(files("normet_r_gui").joinpath("assets", "normet.png"))',
)
patch(
    "_constants.py",
    "docs",
    'DOCS_URL = "https://github.com/apai-sys/normet-py"',
    'DOCS_URL = "https://github.com/apai-sys/normet-r"',
)
patch(
    "workers.py",
    "cancel stops R",
    '''        if self._active is None:
            return
        _thread, worker = self._active''',
    '''        if self._active is None:
            return
        from . import _rpc

        _rpc.cancel()  # the R process doing the work is stopped, not left to finish
        _thread, worker = self._active''',
)
patch(
    "app.py",
    "warm up",
    '''    def load() -> None:
        for name in ("scipy.stats", "sklearn.linear_model", "flaml.automl"):
            try:
                __import__(name)
            except Exception:  # noqa: BLE001 - a head start, not a step
                pass

    threading.Thread(target=load, name="normet-warm-up", daemon=True).start()''',
    '''    def load() -> None:
        try:
            from .nm import _r

            _r.r_check()  # R found, normet loaded: asked once, while the user reads the screen
        except Exception:  # noqa: BLE001 - a head start, not a step
            pass

    threading.Thread(target=load, name="normet-warm-up", daemon=True).start()''',
)


# -- SCM Studio: ML-SCM on the R package's backends; the Bayesian SCM is R's own ------------
patch(
    "scm_window.py",
    "ml backends",
    '''        self.ml_backend_combo.addItems(["flaml", "lightgbm"])
        ef.addRow("ML backend", self.ml_backend_combo)
        self.ml_budget = NoWheelSpinBox()
        self.ml_budget.setRange(5, 3600)
        self.ml_budget.setValue(15)
        self.ml_budget.setSuffix(" s")
        self.ml_budget.setToolTip(
            "AutoML time budget per fit (flaml). Placebo tests refit many\\ntimes — keep this small."
        )
        ef.addRow("Time budget", self.ml_budget)''',
    '''        self.ml_backend_combo.addItems(["lightgbm", "h2o"])
        self.ml_backend_combo.setToolTip(
            "lightgbm = LightGBM with random hyperparameter search (fast, default).\\n"
            "h2o = H2O AutoML (uses the time budget; needs Java and the h2o R package)."
        )
        ef.addRow("ML backend", self.ml_backend_combo)
        self.ml_budget = NoWheelSpinBox()
        self._ml_budget_label = QLabel()
        self._ml_budget_values = {"lightgbm": 5, "h2o": 15}
        self._ml_prev_backend: str | None = None  # the first switch keeps nothing
        ef.addRow(self._ml_budget_label, self.ml_budget)
        self.ml_backend_combo.currentTextChanged.connect(self._ml_backend_changed)
        self._ml_backend_changed("lightgbm")''',
)
patch(
    "scm_window.py",
    "ml backend switch",
    '''    def _backend_changed(self, backend: str) -> None:''',
    '''    def _ml_backend_changed(self, backend: str) -> None:
        """The budget spin is LightGBM's search trials or H2O's time budget, each
        keeping its own value."""
        if self._ml_prev_backend is not None:
            self._ml_budget_values[self._ml_prev_backend] = self.ml_budget.value()
        self._ml_prev_backend = backend
        if backend == "h2o":
            self._ml_budget_label.setText("Time budget")
            self.ml_budget.setRange(5, 3600)
            self.ml_budget.setSuffix(" s")
            self.ml_budget.setToolTip(
                "H2O AutoML time per fit (max_runtime_secs). Placebo tests refit many\\n"
                "times — keep this small."
            )
        else:
            self._ml_budget_label.setText("Search trials")
            self.ml_budget.setRange(1, 100)
            self.ml_budget.setSuffix("")
            self.ml_budget.setToolTip(
                "LightGBM random-search trials per fit. Placebo tests refit many\\n"
                "times — keep this small."
            )
        self.ml_budget.setValue(self._ml_budget_values[backend])

    def _backend_changed(self, backend: str) -> None:''',
)
patch(
    "scm_window.py",
    "ml model config",
    '''        if ml_backend == "flaml":
            model_config = {
                "time_budget": self.ml_budget.value(),
                "metric": "r2",
                "estimator_list": ["lgbm"],
                "task": "regression",
            }
        else:
            model_config = None''',
    '''        if ml_backend == "h2o":
            model_config = {"max_runtime_secs": self.ml_budget.value(), "include_algos": ["GBM"]}
        else:
            model_config = {"n_trials": self.ml_budget.value(), "cv_folds": 3}''',
)
patch(
    "scm_window.py",
    "bayesian tip",
    '''    "bayesian": "Bayesian simplex SCM — needs pymc, gives credible bands.",''',
    '''    "bayesian": "Bayesian simplex SCM (MCMC) — gives credible bands.",''',
)


# -- Methods paragraph: the R package, its backends (LightGBM, H2O AutoML) -------------------
patch(
    "methods.py",
    "h2o reference",
    '''    "flaml": "Wang, C., Wu, Q., Weimer, M. and Zhu, E. (2021). FLAML: A fast and "
    "lightweight AutoML library. Proceedings of Machine Learning and Systems, 3, 434–447.",''',
    '''    "h2o": "LeDell, E. and Poirier, S. (2020). H2O AutoML: Scalable automatic machine "
    "learning. 7th ICML Workshop on Automated Machine Learning (AutoML).",''',
)
patch(
    "methods.py",
    "the R package",
    '''            f"气象归一化使用 normet {info.get('version', '')} 完成。记录包含 {target} 的 "''',
    '''            f"气象归一化使用 normet R 包 {info.get('version', '')} 完成。记录包含 {target} 的 "''',
)
patch(
    "methods.py",
    "the R package (en)",
    '''            f"Meteorological normalisation was done with normet {info.get('version', '')}. "''',
    '''            f"Meteorological normalisation was done with the normet R package "
            f"{info.get('version', '')}. "''',
)
patch(
    "methods.py",
    "h2o automl",
    '''        backend = call.get("backend", "flaml")
        met = _met(call.get("covariates"))
        cfg = call.get("model_config") or {}
        frac = float(call.get("train_fraction", 0.75))
        split = str(call.get("split_method", "random"))
        seed = call.get("seed")
        if backend == "flaml":
            ests = cfg.get("estimator_list") or ["lgbm"]
            budget = cfg.get("time_budget")
            cites.append(REFERENCES["flaml"])
            how_en = (
                f"by an automated search with FLAML (Wang et al., 2021) over "
                f"{_names([str(e) for e in ests], 'en')} within {budget} s"
            )
            how_zh = f"用 FLAML（Wang 等，2021）在 {budget} 秒内对 {_names([str(e) for e in ests], 'zh')} 进行自动搜索"''',
    '''        backend = call.get("backend", "lightgbm")
        met = _met(call.get("covariates"))
        cfg = call.get("model_config") or {}
        frac = float(call.get("train_fraction", 0.75))
        split = str(call.get("split_method", "random"))
        seed = call.get("seed")
        if backend == "h2o":
            ests = cfg.get("include_algos") or ["GBM"]
            budget = cfg.get("max_runtime_secs")
            cites.append(REFERENCES["h2o"])
            how_en = (
                f"by an automated search with H2O AutoML (LeDell and Poirier, 2020) over "
                f"{_names([str(e) for e in ests], 'en')} within {budget} s"
            )
            how_zh = f"用 H2O AutoML（LeDell 和 Poirier，2020）在 {budget} 秒内对 {_names([str(e) for e in ests], 'zh')} 进行自动搜索"''',
)


# -- the session's code is R: the examples' lines, the script's file -------------------------
patch(
    "_examples.py",
    "my1 in R",
    '''        code="df = nm.datasets.load_my1()",
        imports=("import normet as nm",),''',
    '''        code="df <- my1",
        imports=(),''',
)
patch(
    "_examples.py",
    "my1_pm25 in R",
    '''        code="df = nm.datasets.load_my1_pm25()",
        imports=("import normet as nm",),''',
    '''        code="df <- my1_pm25",
        imports=(),''',
)
patch(
    "_session.py",
    "an R script",
    '''            self, "Save session as script", "normet_session.py", "Python (*.py)"''',
    '''            self, "Save session as script", "normet_session.R", "R script (*.R)"''',
)
patch(
    "_session.py",
    "h2o budget kept",
    '''            "time_budget": (
                self.budget_spin.value()
                if self.backend_combo.currentText() == "flaml"
                else self._budget_values.get("flaml", 60)
            ),''',
    '''            "time_budget": (
                self.budget_spin.value()
                if self.backend_combo.currentText() == "h2o"
                else self._budget_values.get("h2o", 60)
            ),''',
)
patch(
    "_session.py",
    "h2o budget restored",
    '''        self._budget_values["flaml"] = c.get("time_budget", 60)
        self._budget_values["lightgbm"] = c.get("lgb_trials", 20)
        self.backend_combo.setCurrentText(c.get("backend", "flaml"))''',
    '''        self._budget_values["h2o"] = c.get("time_budget", 60)
        self._budget_values["lightgbm"] = c.get("lgb_trials", 20)
        self.backend_combo.setCurrentText(c.get("backend", "lightgbm"))''',
)
patch(
    "_session.py",
    "h2o algorithms restored",
    '''        ests = set(c.get("flaml_estimators") or ["lgbm"])''',
    '''        ests = set(c.get("flaml_estimators") or ["GBM"])  # H2O's include_algos here''',
)
patch(
    "_saved.py",
    "R script read back",
    '''                self, "Load session script", "", "Python (*.py);;All files (*)"''',
    '''                self, "Load session script", "", "R script (*.R *.r);;All files (*)"''',
)
patch(
    "_saved.py",
    "R script run",
    '''                f"{os.path.basename(path)} is Python and runs as it is written, as running "
                "it yourself would. Run only a script you or the window wrote.",''',
    '''                f"{os.path.basename(path)} is R and runs as it is written, as running "
                "it yourself would. Run only a script you or the window wrote.",''',
)
patch(
    "_saved.py",
    "R script docstring",
    '''        its results brought into the window (.\\_script). It is Python, run as written:''',
    '''        its results brought into the window (.\\_script). It is R, run as written:''',
)
patch(
    "_session.py",
    "R script docstring",
    '''        """The command log as a Python file that repeats the session."""''',
    '''        """The command log as an R script that repeats the session."""''',
)


# -- Help -> User Manual: this window's book where the checkout has it -----------------------
patch(
    "manual.py",
    "R checkout",
    '''    roots.append(Path(__file__).resolve().parents[3])  # src/normet/gui -> the checkout''',
    '''    # gui/normet_r_gui -> gui/, whose docs/manual holds this window's own book.
    roots.append(Path(__file__).resolve().parents[1])''',
)
patch(
    "manual.py",
    "R book online",
    '''ONLINE = "https://github.com/apai-sys/normet-py/raw/main/docs/manual/{book}"''',
    '''ONLINE = "https://github.com/apai-sys/normet-r/raw/main/gui/docs/manual/{book}"''',
)
patch(
    "manual.py",
    "R book docstring",
    '''installers (packaging/normet_gui.spec); a checkout of the repository has them in
docs/manual.''',
    '''installers (gui/packaging/normet_r_gui.spec); a checkout of the repository has them in
gui/docs/manual (normet-py's book, rewritten for this window by
gui/tools/manual_patches.py).''',
)


# -- normet-py's GUI tests, run on this window -------------------------------------------------
def skip(file: str, test: str, reason: str) -> None:
    """A test of something this window does not have: kept, and skipped with the reason."""
    patch(file, f"skip {test}", f"def {test}(", f"@pytest.mark.skip(reason={reason!r})\ndef {test}(")


NO_CHRONOS = "Chronos-2 (normet-py's PyTorch foundation model) is not offered in R"
for _test in (
    "test_chronos_backend_hides_the_training_controls",
    "test_chronos_backend_swaps_the_monte_carlo_sample_count",
    "test_chronos_normalise_panel_declares_the_seeded_rows",
    "test_chronos_option_is_greyed_out_without_the_extra",
    "test_chronos_load_requires_a_met_covariate",
    "test_chronos_backend_exposes_a_device_selector",
):
    skip("tests/test_gui_smoke.py", _test, NO_CHRONOS)
patch(
    "tests/test_gui_methods.py",
    "about: (R)",
    'assert f"Version {normet.__version__}" in',
    'assert f"Version {normet.__version__} (R)" in',
)
# A rolling run's windows keep R's names (window_01, from 1), not normet-py's rolling_0.
patch(
    "_run_analyse.py",
    "rolling: R's window names",
    'rolling_cols = [c for c in result.columns if c.startswith("rolling_")]',
    'rolling_cols = [c for c in result.columns if c.startswith("window_")]',
)
patch(
    "_multiscale.py",
    "rolling: R's window names",
    'cols = [c for c in res.columns if c.startswith("rolling_")]',
    'cols = [c for c in res.columns if c.startswith("window_")]',
)
patch(
    "tests/test_gui_multiscale.py",
    "rolling: R's window names (doc)",
    "returning hand-built ``rolling_<i>`` columns",
    "returning hand-built ``window_<i>`` columns, as R names them",
)
patch(
    "tests/test_gui_multiscale.py",
    "rolling: R's window names",
    'result[f"rolling_{i}"] = level',
    'result[f"window_{i + 1:02d}"] = level',
)
skip(
    "tests/test_progress.py",
    "test_rolling_reports_its_windows_and_keeps_a_window_inside_its_share",
    "rolling runs in R here: tests/testthat/test-progress.r checks its reports, "
    "tests/test_rpc_progress.py their way to the window",
)

patch(
    "tests/test_gui_smoke.py",
    "backends",
    '''        assert win._budget_label.text() == "Time budget"
        # flaml shows the estimator sub-selection, default lgbm only
        assert not win.estimator_list.isHidden()
        assert win._selected_estimators() == ["lgbm"]
        win.backend_combo.setCurrentText("lightgbm")
        assert win._budget_label.text() == "Search trials"
        assert win.estimator_list.isHidden()  # not applicable to LightGBM
        win.budget_spin.setValue(7)
        win.backend_combo.setCurrentText("flaml")
        assert win.budget_spin.value() == 60  # flaml default remembered
        assert not win.estimator_list.isHidden()''',
    '''        assert win.backend_combo.currentText() == "lightgbm"
        assert win._budget_label.text() == "Search trials"
        assert win.estimator_list.isHidden()  # not applicable to LightGBM
        win.budget_spin.setValue(7)
        win.backend_combo.setCurrentText("h2o")
        # H2O shows its algorithms, GBM alone by default, and a time budget.
        assert win._budget_label.text() == "Time budget"
        assert win.budget_spin.value() == 60  # h2o default remembered
        assert not win.estimator_list.isHidden()
        assert win._selected_estimators() == ["GBM"]''',
)
patch(
    "tests/test_gui_smoke.py",
    "example in R",
    '''endswith("df = nm.datasets.load_my1()")''',
    '''endswith("df <- my1")''',
)
patch(
    "tests/test_gui_smoke.py",
    "clock in R",
    '''assert "zone='Asia/Shanghai'" in''',
    '''assert 'zone = "Asia/Shanghai"' in''',
)

# Methods: H2O AutoML where normet-py has FLAML.
patch(
    "tests/test_gui_methods.py",
    "h2o run",
    '''            "backend": "flaml",''',
    '''            "backend": "h2o",''',
)
patch(
    "tests/test_gui_methods.py",
    "h2o config",
    '''            "model_config": {"time_budget": 30, "estimator_list": ["lgbm"]},''',
    '''            "model_config": {"max_runtime_secs": 30, "include_algos": ["GBM"]},''',
)
patch(
    "tests/test_gui_methods.py",
    "h2o said",
    '''    assert "FLAML (Wang et al., 2021) over lgbm within 30 s" in text''',
    '''    assert "H2O AutoML (LeDell and Poirier, 2020) over GBM within 30 s" in text''',
)
patch(
    "tests/test_gui_methods.py",
    "h2o cited",
    '''    assert "FLAML" in refs and "Grange" in refs and "LightGBM" not in refs''',
    '''    assert "H2O AutoML" in refs and "Grange" in refs and "LightGBM" not in refs''',
)
patch(
    "tests/test_gui_methods.py",
    "h2o in Chinese",
    '''"FLAML（Wang 等，2021）" in text''',
    '''"H2O AutoML（LeDell 和 Poirier，2020）" in text''',
)

# Saved sessions: a small model (R's lightgbm takes n_trials), and the script is R.
patch(
    "tests/test_gui_saved.py",
    "trials",
    '''model_config={"n_iter": 2}''',
    '''model_config={"n_trials": 1}''',
)
patch(
    "tests/test_gui_saved.py",
    "R script",
    '''SCRIPT = """\\
from normet_r_gui.nm import build_model
from normet_r_gui.nm import normalise
from normet_r_gui._examples import make_deweather_example

# Load example data
df = make_deweather_example()

# Train model
df_prep, model = build_model(df, 'PM2.5', backend='lightgbm',
                             covariates=['t2m', 'blh', 'ws', 'wd', 'date_unix', 'day_julian', 'weekday', 'hour'],
                             split_method='random', train_fraction=0.7,
                             model_config={'n_trials': 2}, seed=7)

# Normalise
normalised = normalise(df_prep, model,
                       covariates=['t2m', 'blh', 'ws', 'wd', 'date_unix', 'day_julian', 'weekday', 'hour'],
                       variables_resample=['t2m', 'blh', 'ws', 'wd'], n_samples=5, n_cores=1)
"""''',
    '''# The example table is read from beside the script (see _example_csv).
SCRIPT = """\\
library(normet)

# Open data
df <- nm_read_time_series("example.csv")

# Train model
res <- nm_build_model(df, target = "PM2.5", backend = "lightgbm",
                      covariates = c("t2m", "blh", "ws", "wd", "date_unix", "day_julian", "weekday", "hour"),
                      split_method = "random", train_fraction = 0.7,
                      model_config = list(n_trials = 2), seed = 7)
df_prep <- res$df_prep
model <- res$model

# Normalise
normalised <- nm_normalise(df_prep, model, resample_vars = c("t2m", "blh", "ws", "wd"),
                           n_samples = 5, n_cores = 1)
"""


def _example_csv(folder):
    from normet_r_gui._examples import make_deweather_example

    make_deweather_example(n_days=120).to_csv(folder / "example.csv", index=False)''',
)
patch(
    "tests/test_gui_saved.py",
    "target read",
    '''    assert calls["build_model"]["args"] == [None, "PM2.5"]  # df is a name, not kept''',
    '''    assert calls["build_model"]["target"] == "PM2.5"''',
)
patch(
    "tests/test_gui_saved.py",
    "R script file",
    '''    path = tmp_path / "session.py"
    path.write_text(SCRIPT, encoding="utf-8")''',
    '''    path = tmp_path / "session.R"
    path.write_text(SCRIPT, encoding="utf-8")
    _example_csv(tmp_path)''',
)
patch(
    "tests/test_gui_methods.py",
    "local manual once built",
    '''    local = manual.manual_location("zh")
    assert local.isLocalFile() and local.toLocalFile().endswith("normet_manual_zh.pdf")''',
    '''    # This window's book is opened from the checkout once built (gui/docs/manual).
    if manual.manual_path("zh") is not None:
        local = manual.manual_location("zh")
        assert local.isLocalFile() and local.toLocalFile().endswith("normet_manual_zh.pdf")''',
)


# -- the Assistant's readings: the statistics are R's -------------------------------------------
patch(
    "nm/agent/readings.py",
    "R's modStats",
    '''        "Model fit (normet.modStats; 'testing' is the rows held out of training):",''',
    '''        "Model fit (nm_modStats; 'testing' is the rows held out of training):",''',
)
