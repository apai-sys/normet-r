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


patch(
    "tests/test_gui_methods.py",
    "about: (R)",
    'assert f"Version {normet.__version__}" in',
    'assert f"Version {normet.__version__} (R)" in',
)
# The window's normet is the nm package: its window names are there, not in normet.analysis.
patch(
    "_saved.py",
    "window names from nm",
    "    from .nm.analysis.rolling import window_column",
    "    from .nm import window_column",
)
patch(
    "tests/test_gui_multiscale.py",
    "window names from nm",
    "from normet_r_gui.nm.analysis.rolling import window_column",
    "from normet_r_gui.nm import window_column",
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


# -- Chronos-2: not in this window ---------------------------------------------------------
# normet-py's zero-shot foundation model (PyTorch) has no R counterpart: its module
# (_chronos.py) is not copied, and what reads it is taken out -- the backend, its device
# and fine-tuning, its seeded rows, its Model tab and Methods sentence, the SCM Studio's
# similarity ranking, its texts and its tests.
def passage(file: str, label: str, start: str, end: str, new: str) -> None:
    """The text from ``start`` up to (not including) ``end`` replaced by ``new``."""
    PATCHES.setdefault(file, []).append((label, (start, end), new))


# Step 1's box
patch(
    "_panel_train.py",
    "chronos: docstring",
    r'''"""Step 1's box: backend, split, budget, seed, device -- and fine-tuning.

Also the three questions the rest of the window asks about that box: which
estimators are ticked, where Chronos-2 runs, and whether it is the backend in
use.  They read the box this mixin built, which is an attribute of the window.
"""''',
    r'''"""Step 1's box: backend, split, budget, seed.

Also the question the rest of the window asks about that box: which estimators
are ticked.  It reads the box this mixin built, which is an attribute of the window.
"""''',
)
patch(
    "_panel_train.py",
    "chronos: QWidget",
    "    QMainWindow,\n    QWidget,\n)",
    "    QMainWindow,\n)",
)
patch(
    "_panel_train.py",
    "chronos: import",
    "from . import _chronos\nfrom ._lists",
    "from ._lists",
)
patch(
    "_panel_train.py",
    "chronos: hint_label",
    "    NoWheelSpinBox,\n    hint_label,\n",
    "    NoWheelSpinBox,\n",
)
patch(
    "_panel_train.py",
    "chronos: parked samples",
    r"""        # Parked value for the "Samples" spin box on the other side of the
        # chronos-2 divide; see _train_backend_changed.
        self._norm_samples_parked = _chronos.DEFAULT_SAMPLES
        self._decom_samples_parked = _chronos.DEFAULT_SAMPLES
        self._norm_samples_is_chronos = False
""",
    "",
)
passage(
    "_panel_train.py",
    "chronos: hint and device",
    "        self._chronos_hint = hint_label(",
    "        self.train_button = run_button(",
    "",
)
passage(
    "_panel_train.py",
    "chronos: fine-tuning",
    "        # Chronos-2 only: adapt the loaded checkpoint to this site's own record.",
    "        return box\n\n    def _train_backend_changed",
    "",
)
passage(
    "_panel_train.py",
    "chronos: backend change",
    "    def _train_backend_changed(self, backend: str) -> None:",
    "        self._budget_values[self._prev_backend] = self.budget_spin.value()",
    r'''    def _train_backend_changed(self, backend: str) -> None:
        """The budget row means seconds for H2O, search trials for LightGBM; the
        algorithm checklist only applies to H2O's AutoML search."""
''',
)
patch(
    "_panel_train.py",
    "chronos: device and _is_chronos",
    r'''

    def _selected_device(self) -> str | None:
        """``None`` means let :func:`normet.foundation.resolve_device` choose."""
        choice = self.device_combo.currentText()
        return None if choice == "auto" else choice

    def _is_chronos(self) -> bool:
        return self.backend_combo.currentText() == _chronos.BACKEND''',
    "",
)

# training and the Model tab
patch(
    "_run_train.py",
    "chronos: docstring",
    r'''"""Training, Chronos-2 loading and the Model tab.

Step 1's run handler, what it does when the task comes back, and the two
renderers for the Model tab (one for a trained estimator, one for Chronos-2's
zero-shot check).  Mixed into :class:`~.main_window.MainWindow`.
"""''',
    r'''"""Training and the Model tab.

Step 1's run handler, what it does when the task comes back, and the Model tab's
renderer.  Mixed into :class:`~.main_window.MainWindow`.
"""''',
)
patch(
    "_run_train.py",
    "chronos: import",
    "from . import _chronos\nfrom ._constants",
    "from ._constants",
)
patch(
    "_run_train.py",
    "chronos: load",
    r"""        if backend == _chronos.BACKEND:
            self._run_load_chronos(target, features)
            return
""",
    "",
)
passage(
    "_run_train.py",
    "chronos: load and its tab",
    "    def _run_load_chronos(",
    "    def _train_done(",
    "",
)
patch(
    "_run_train.py",
    "chronos: which tab",
    r"""        if self._is_chronos():
            self._render_chronos_model_tab()
        else:
            self._render_model_tab()""",
    "        self._render_model_tab()",
)
patch(
    "_run_train.py",
    "chronos: fine-tuning",
    r'''

    def _run_finetune(self) -> None:
        """Adapt the loaded Chronos-2 checkpoint to this site's record (on a worker)."""
        if not self._check_model() or not self._is_chronos():
            return
        self.runner.submit(
            f"fine-tune ({self.ft_mode.currentText()}, {self.ft_steps.value()} steps)",
            _chronos.finetune,
            self._finetune_done,
            self._show_error,
            self.model,
            self.df_prep,
            self.ft_mode.currentText(),
            self.ft_steps.value(),
        )

    def _finetune_done(self, estimator: object) -> None:
        self.model = estimator
        self.results.pop("normalise", None)
        self.results.pop("decompose", None)
        self._render_chronos_model_tab()
        self._sync_enabled()
        self.tabs.setCurrentWidget(self.tab_model)
        self.statusBar().showMessage("Fine-tuned — normalise again to use the tuned weights.")
        log.info("Fine-tuning finished")''',
    "",
)

# steps 2-5
patch(
    "_run_analyse.py",
    "chronos: import",
    "from . import _chronos\nfrom ._constants",
    "from ._constants",
)
passage(
    "_run_analyse.py",
    "chronos: de-weather",
    "        if self._is_chronos():\n            self.runner.submit(",
    "        from .nm import normalise\n",
    "\n",
)
patch(
    "_run_analyse.py",
    "chronos: seeded rows",
    r"""        # Chronos-2 has no history to condition on for the first context_length
        # rows, so deweather() seeds them with the observed values: normalised
        # equals observed there by construction, not by result. Averaging across
        # them drags the reported effect toward zero, and on a record not much
        # longer than the context that is most of the series -- so say how many
        # rows are seeded and take the mean over the rest.
        seeded = min(int(self.model.context_length), len(result)) if self._is_chronos() else 0
        projected = result.iloc[seeded:]""",
    "        projected = result",
)
patch(
    "_run_analyse.py",
    "chronos: seeded span",
    r"""            if seeded:
                ax.axvspan(
                    result.index[0],
                    result.index[seeded - 1],
                    color="#E5E5EA",
                    lw=0,
                    zorder=0,
                    label="seeded (= observed)",
                )
                S.legend(ax, loc="upper right", ncols=4)
""",
    "",
)
passage(
    "_run_analyse.py",
    "chronos: seeded note",
    "        if seeded:\n            pct = 100.0 * seeded / len(result)",
    "        self.tab_norm.show_timeseries(render, result, lines=lines)",
    "",
)
patch(
    "_run_analyse.py",
    "chronos: decompose",
    r"""        if self._is_chronos():
            # The zero-shot path: each coalition is a de-weathering of the
            # estimator's own, over the meteorology it was loaded with.
            options.update(target="value", backend=_chronos.BACKEND)
            covariates = [f for f in self.trained_features if f not in TIME_VARS]
        else:
            covariates = self.trained_features + list(TIME_VARS)""",
    "        covariates = self.trained_features + list(TIME_VARS)",
)

# which controls a task leaves enabled
patch(
    "_tasks.py",
    "chronos: fine-tune button",
    "        self.ft_button.setEnabled(not busy and has_model and self._is_chronos())\n",
    "",
)
patch(
    "_tasks.py",
    "chronos: rolling and PDP",
    r"""        elif self._is_chronos():
            # Rolling and PDP call ml_predict() on a fitted scikit-learn-style
            # estimator. Chronos-2 forecasts autoregressively from a context
            # window instead, so there is nothing for them to call. The
            # meteorological decomposition has its own zero-shot path.
            tip = "Not available for chronos-2 — use flaml or lightgbm for this step."
            for b in (self.roll_button, self.pdp_button):
                b.setEnabled(False)
                b.setToolTip(tip)
""",
    "",
)
patch(
    "main_window.py",
    "chronos: check",
    r"""        #: Chronos-2's covariate-sensitivity check of the model loaded: (numbers, verdict).
        self.chronos_check: tuple[dict, tuple[str, str]] | None = None
""",
    "",
)
patch(
    "main_window.py", "chronos: fine-tune button", "            self.ft_button,\n", ""
)
patch("_panel_inputs.py", "chronos: check", "        self.chronos_check = None\n", "")

# a saved session, the settings and the Methods paragraph
patch(
    "_saved.py",
    "chronos: docstring",
    r"""A Chronos-2 checkpoint is not written: it is the pretrained model, half a gigabyte, and
is loaded again from its cache with *Load Chronos-2*. A file of this kind is a pickle:
open only one you or the window wrote.""",
    "A file of this kind is a pickle: open only one you or the window wrote.",
)
patch(
    "_saved.py",
    "chronos: import",
    "from . import _chronos, _settings",
    "from . import _settings",
)
patch("_saved.py", "chronos: bundle", "        chronos = self._is_chronos()\n", "")
patch(
    "_saved.py",
    "chronos: model",
    """            "model": None if chronos else self.model,
            "chronos": chronos and self.model is not None,
""",
    '            "model": self.model,\n',
)
patch("_saved.py", "chronos: script bundle", '            "chronos": False,\n', "")
patch(
    "_saved.py",
    "chronos: restored",
    r"""        if bundle.get("chronos"):
            self.backend_combo.setCurrentText(_chronos.BACKEND)
            self.notify(
                f"Session of {when} restored without its Chronos-2 model, which is not "
                "saved: Load Chronos-2 again to go on.",
                key="restored",
                kind="warn",
                actions=(("Load Chronos-2", self._run_train),),
            )
        else:
            steps = [s for s in ("train", *_STEPS, "multiscale") if s in self.results]
            self.notify(
                f"Session of {when} restored: "
                + (", ".join(steps) if steps else "the table and its settings")
                + ".",
                key="restored",
            )""",
    r"""        steps = [s for s in ("train", *_STEPS, "multiscale") if s in self.results]
        self.notify(
            f"Session of {when} restored: "
            + (", ".join(steps) if steps else "the table and its settings")
            + ".",
            key="restored",
        )""",
)
patch(
    "_saved.py",
    "chronos: script trains",
    'if "build_model" not in calls and "load_estimator" not in calls:',
    'if "build_model" not in calls:',
)
patch(
    "_session.py",
    "chronos: import",
    "from . import _chronos, _settings, commandlog",
    "from . import _settings, commandlog",
)
patch(
    "_session.py",
    "chronos: methods info",
    r"""        if self.chronos_check is not None:
            info["chronos_pct"] = float(self.chronos_check[0].get("pct_of_prediction", 0.0))
""",
    "",
)
patch(
    "_session.py",
    "chronos: samples",
    r"""        # An explicit saved count wins; the fallback follows the restored backend,
        # so a config written before chronos-2 existed does not push 300 forward
        # passes onto it.
        self.norm_samples.setValue(
            c.get("norm_samples", _chronos.DEFAULT_SAMPLES if self._is_chronos() else 300)
        )""",
    '        self.norm_samples.setValue(c.get("norm_samples", 300))',
)
patch(
    "_session.py",
    "chronos: a new model",
    'if step == "build_model" or step == "load_estimator":',
    'if step == "build_model":',
)
patch(
    "methods.py",
    "chronos: info",
    r'''the held-out ``r2``, ``rmse`` and ``n``; ``chronos_pct`` -- the forecast's shift, as a
    share of the prediction, when the weather is shuffled (Chronos-2)."""''',
    r'''the held-out ``r2``, ``rmse`` and ``n``."""''',
)
patch(
    "methods.py",
    "chronos: no model",
    'if "build_model" not in ran and "load_estimator" not in ran:',
    'if "build_model" not in ran:',
)
passage(
    "methods.py",
    "chronos: model",
    '    else:\n        call = ran["load_estimator"]',
    "    # -- normalisation",
    "\n",
)
passage(
    "methods.py",
    "chronos: normalisation",
    '    elif "deweather" in ran:',
    "    # -- decomposition",
    "\n",
)
patch(
    "methods.py",
    "chronos: references",
    'REFERENCES["en"] if any(k in ran for k in ("normalise", "deweather")) else []',
    'REFERENCES["en"] if "normalise" in ran else []',
)

# the Assistant
patch(
    "assistant.py",
    "chronos: chain",
    r"""    "decompose": "the decomposition: decompose (method='meteorology' on chronos-2, where "
    "the emission one is not available)",""",
    """    "decompose": "the decomposition: decompose",""",
)
patch(
    "assistant.py",
    "chronos: model fit",
    r"""            if self.win._is_chronos():
                return chronos_reading(self.win)
            return readings.model_reading""",
    "            return readings.model_reading",
)
patch(
    "assistant.py",
    "chronos: fit now",
    r"""    def _fit_now(self) -> str:
        if self.win._is_chronos():
            return chronos_reading(self.win)
""",
    "    def _fit_now(self) -> str:\n",
)
patch(
    "assistant.py",
    "chronos: emission",
    r"""        if method == "emission" and self._gui(self.win._is_chronos):
            raise ValueError(
                "the emission decomposition is not available on chronos-2: it reads the "
                "calendar off the target's own history, so the time-scale components would "
                "come back near zero. Use method='meteorology', or train with flaml or lightgbm."
            )
""",
    "",
)
passage(
    "assistant.py",
    "chronos: reading",
    "def chronos_reading(win: MainWindow) -> str:",
    "#: The box written in before its first turn",
    "",
)

# the SCM Studio: ranking donors by their Chronos-2 embeddings
passage(
    "scm_window.py",
    "chronos: similarity controls",
    "        from . import _chronos\n\n        chronos_ok, chronos_why",
    "\n        # ---- Estimator",
    "",
)
patch(
    "scm_window.py",
    "chronos: similarity tab",
    r"""        self.tab_sim = CanvasTab(
            "Rank donors by similarity (Chronos-2) to compare every unit's pre-period with the treated unit's."
        )
        self.tabs.addTab(self.tab_sim, "Similarity")
""",
    "",
)
patch(
    "scm_window.py",
    "chronos: similarity buttons",
    r"""        self.sim_btn.setEnabled(not busy and has_df and self._chronos_ok)
        self.sim_tick_btn.setEnabled(not busy and self._similarity is not None)
""",
    "",
)
passage(
    "scm_window.py",
    "chronos: similarity",
    "    def _run_similarity(self) -> None:",
    "    def _run_all_units(self) -> None:",
    "",
)

# the Chinese texts of what is gone
patch(
    "ui_zh.py",
    "chronos: names",
    "backend and model names (flaml, lightgbm, chronos-2)",
    "backend and model names (lightgbm, h2o)",
)
#: Their entries, each a whole line.
_CHRONOS_ZH = (
    '    "Similarity": "相似度",\n',
    '    "flaml = AutoML search (uses the time budget below). lightgbm = LightGBM with random hyperparameter search. chronos-2 = zero-shot foundation model; nothing is trained.": "flaml = AutoML 搜索（使用下方的时间预算）。lightgbm = 带随机超参数搜索的 LightGBM。chronos-2 = 零样本基础模型，无需训练。",\n',
    '    "Device": "设备",\n',
    '    "Where Chronos-2 runs. auto: CUDA, else Apple Silicon (mps), else CPU. Every Monte-Carlo sample is a full forward pass, so this is the difference between minutes and hours.": "Chronos-2 的运行设备。auto：优先 CUDA，其次 Apple Silicon（mps），否则 CPU。每个蒙特卡洛样本都是一次完整的前向计算，因此这决定了耗时是几分钟还是几小时。",\n',
    '    "Chronos-2 is zero-shot — nothing is trained, so there is no budget, search space or train/test split. The first run downloads about 500 MB of weights. Meteorology enters through the model\'s covariate channel; the ticked features below are what it sees.": "Chronos-2 是零样本模型——无需训练，因此没有时间预算、搜索空间或训练/测试划分。首次运行会下载约 500 MB 的权重。气象通过模型的协变量通道输入；下方勾选的特征就是它看到的内容。",\n',
    '    "Chronos-2 conditions on meteorology through its covariate channel. Tick at least one meteorological feature — without any, the run is a plain forecast, not a de-weathering.": "Chronos-2 通过协变量通道以气象为条件。请至少勾选一个气象特征——否则只是普通预测，而非去气象化。",\n',
    '    "Fine-tune": "微调",\n',
    '    "▶ Fine-tune Chronos-2": "▶ 微调 Chronos-2",\n',
    '    "Adapt the loaded checkpoint to this site\'s own record. The tuned weights replace the model for this session; Load Chronos-2 again to go back.": "用本站点自身的数据微调已载入的检查点。微调后的权重在本次会话中替换原模型；重新载入 Chronos-2 即可恢复。",\n',
    '    "Steps": "步数",\n',
    '    "Optimiser steps. On a CPU this takes a while; a GPU or Apple Silicon helps.": "优化器步数。在 CPU 上需要一段时间；GPU 或 Apple Silicon 会快很多。",\n',
    '    "lora: train small adapters, leave the base weights alone (needs peft). full: update all 119M parameters; overfits a single site\'s record more easily.": "lora：只训练小型适配器，不改动基础权重（需要 peft）。full：更新全部 1.19 亿个参数，更容易对单个站点的数据过拟合。",\n',
    '    "Loading Chronos-2 — first run downloads the checkpoint…": "正在载入 Chronos-2——首次运行会下载检查点…",\n',
    '    "Fine-tuned — normalise again to use the tuned weights.": "已微调——重新归一化以使用微调后的权重。",\n',
    '    "Checkpoint: {s0}": "检查点：{s0}",\n',
    '    "device: {s0}": "设备：{s0}",\n',
    '    "context: {s0} h": "上下文：{s0} 小时",\n',
    '    "horizon: {s0} h": "预测步长：{s0} 小时",\n',
    '    "Covariates: {n0} met + 6 calendar": "协变量：{n0} 个气象 + 6 个日历",\n',
    '    "Rank donors by similarity (Chronos-2)": "按相似度排列供体（Chronos-2）",\n',
    '    "Rank donors by similarity (Chronos-2) to compare every unit\'s pre-period with the treated unit\'s.": "按相似度排列供体（Chronos-2），比较每个单元与处理单元在干预前的表现。",\n',
    '    "Embed every unit\'s outcome before the cutoff with Chronos-2 and rank the others by how alike their dynamics are to the treated unit\'s (cosine). Only the pre-period is read, so the effect cannot leak into the choice.": "用 Chronos-2 对每个单元干预前的结果进行嵌入，并按其动态与处理单元的相似程度（余弦）排序。只读取干预前的数据，因此效应不会影响供体的选择。",\n',
    '        "seeded (= observed)": "种子段（= 观测）",\n',
    '        "Units ranked by Chronos-2 embedding similarity": "按 Chronos-2 嵌入相似度排列的单元",\n',
    '        "Similarity to {s0} before the cutoff (cosine)": "干预前与 {s0} 的相似度（余弦）",\n',
    '        "Session of {s0} restored without its Chronos-2 model, which is not saved: Load Chronos-2 again to go on.": "已恢复 {s0} 的会话，但不含 Chronos-2 模型（模型不保存）：请重新载入 Chronos-2 以继续。",\n',
    '        "Load Chronos-2": "载入 Chronos-2",\n',
    '        "▶ Load Chronos-2": "▶ 载入 Chronos-2",\n',
    '        "Not on chronos-2: it reads the calendar off the target\'s own history.": "chronos-2 不适用：它从目标自身的历史中读取日历。",\n',
    '        "Needs the foundation extra: {s0}": "需要 foundation 扩展：{s0}",\n',
)
for _i, _line in enumerate(_CHRONOS_ZH):
    patch("ui_zh.py", f"chronos: text {_i}", _line, "")
patch(
    "ui_zh.py",
    "chronos: availability texts",
    '        "Chronos-2 needs the \'foundation\' extra ({s0} not installed).": "Chronos-2 需要 \'foundation\' 扩展（未安装 {s0}）。",\n        "Install with: pip install normet[foundation]": "安装方法：pip install normet[foundation]",\n        "Unknown error": "未知错误",\n',
    '        "Unknown error": "未知错误",\n',
)
patch(
    "ui_zh.py",
    "chronos: availability texts, alone",
    'INNER.update(\n    {\n        "Chronos-2 needs the \'foundation\' extra ({s0} not installed).": "Chronos-2 需要 \'foundation\' 扩展（未安装 {s0}）。",\n        "Install with: pip install normet[foundation]": "安装方法：pip install normet[foundation]",\n    }\n)\n',
    "",
)

# normet-py's tests of the backend
passage(
    "tests/test_gui_smoke.py",
    "chronos: tests",
    "def test_chronos_backend_hides_the_training_controls(qapp):",
    "def test_scm_fit_verdict_reads_the_pre_fit_only_when_a_shuffled_series_cannot_match_it(qapp):",
    "",
)
