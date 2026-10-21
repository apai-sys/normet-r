"""Step 1's box: backend, split, budget, seed.

Also the question the rest of the window asks about that box: which estimators
are ticked.  It reads the box this mixin built, which is an attribute of the window.
"""

from __future__ import annotations

from PySide6.QtCore import Qt
from PySide6.QtWidgets import (
    QAbstractItemView,
    QFormLayout,
    QGroupBox,
    QLabel,
    QListWidget,
    QListWidgetItem,
    QMainWindow,
)

from ._lists import _checked_items
from ._widgets import (
    NoWheelComboBox,
    NoWheelDoubleSpinBox,
    NoWheelSpinBox,
    run_button,
)


class TrainPanelMixin(QMainWindow):
    def _build_train_box(self) -> QGroupBox:
        """Step 1: backend, split, budget, seed, device — and fine-tuning."""
        box = QGroupBox("Train model")
        form = QFormLayout(box)
        form.setLabelAlignment(Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignVCenter)
        self.backend_combo = NoWheelComboBox()
        self.backend_combo.addItems(["lightgbm", "h2o"])
        self.backend_combo.setToolTip(
            "lightgbm = LightGBM with random hyperparameter search (fast, default).\n"
            "h2o = H2O AutoML search (uses the time budget below; needs Java and the h2o R package)."
        )
        self.backend_combo.currentTextChanged.connect(self._train_backend_changed)
        form.addRow("Backend", self.backend_combo)
        self.split_combo = NoWheelComboBox()
        self.split_combo.addItems(["random", "ts", "month_ts", "season_ts"])
        self.split_combo.setToolTip("How the train/test split is drawn.")
        self._split_label = QLabel("Split method")
        form.addRow(self._split_label, self.split_combo)
        self.train_fraction_spin = NoWheelDoubleSpinBox()
        self.train_fraction_spin.setRange(0.1, 0.95)
        self.train_fraction_spin.setSingleStep(0.05)
        self.train_fraction_spin.setValue(0.75)
        self._train_fraction_label = QLabel("Training fraction")
        form.addRow(self._train_fraction_label, self.train_fraction_spin)
        self.budget_spin = NoWheelSpinBox()
        self.budget_spin.setRange(1, 500)
        self.budget_spin.setValue(20)
        self.budget_spin.setToolTip("Random hyperparameter-search trials (LightGBM backend).")
        self._budget_label = QLabel("Search trials")
        self._budget_values = {"h2o": 60, "lightgbm": 20}
        self._prev_backend = "lightgbm"
        form.addRow(self._budget_label, self.budget_spin)
        # H2O only: which AutoML algorithms to search over (include_algos).
        self.estimator_list = QListWidget()
        self.estimator_list.setSelectionMode(QAbstractItemView.SelectionMode.NoSelection)
        self.estimator_list.setMaximumHeight(96)
        self.estimator_list.setToolTip(
            "H2O AutoML algorithms to search over (include_algos), within the time budget.\n"
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
        self.estimator_list.setVisible(False)
        self._train_form = form
        self.seed_spin = NoWheelSpinBox()
        self.seed_spin.setRange(0, 2_147_483_647)
        self.seed_spin.setValue(7_654_321)
        self._seed_label = QLabel("Seed")
        form.addRow(self._seed_label, self.seed_spin)
        self.train_button = run_button(
            "▶  Train model",
            "Prepare the data and train the machine-learning model.\nEverything below needs a trained model.",
        )
        self.train_button.clicked.connect(self._run_train)
        form.addRow(self.train_button)
        return box

    def _train_backend_changed(self, backend: str) -> None:
        """The budget row means seconds for H2O, search trials for LightGBM; the
        algorithm checklist only applies to H2O's AutoML search."""
        self._budget_values[self._prev_backend] = self.budget_spin.value()
        self._prev_backend = backend
        if backend == "h2o":
            self._budget_label.setText("Time budget")
            self.budget_spin.setRange(5, 36_000)
            self.budget_spin.setSuffix(" s")
            self.budget_spin.setToolTip("AutoML search time (H2O backend: max_runtime_secs).")
        else:
            self._budget_label.setText("Search trials")
            self.budget_spin.setRange(1, 500)
            self.budget_spin.setSuffix("")
            self.budget_spin.setToolTip("Random hyperparameter-search trials (LightGBM backend).")
        self.budget_spin.setValue(self._budget_values.get(backend, 20))
        is_h2o = backend == "h2o"
        self._estimator_label.setVisible(is_h2o)
        self.estimator_list.setVisible(is_h2o)

    def _selected_estimators(self) -> list[str]:
        return _checked_items(self.estimator_list)
