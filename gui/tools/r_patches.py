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
    '''            f"<b>normet {normet.__version__}</b><br>"
            "Normalisation, decomposition and counterfactual modelling "
            "for environmental time series.<br>"''',
    '''            f"<b>normet {normet.__version__} (R)</b><br>"
            "Normalisation, decomposition and counterfactual modelling "
            "for environmental time series, run on the normet R package.<br>"''',
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
