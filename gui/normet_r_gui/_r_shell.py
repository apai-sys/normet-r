"""What this window has that normet-py's does not, because it runs R: the R menu
(Locate Rscript…, Check R environment, Save Figure as R Script…), R's state in the status bar, and the R side
cleaned up when the window closes. Mixed into :class:`~.main_window.MainWindow`."""

from __future__ import annotations

import logging
import threading

import pandas as pd
from PySide6.QtCore import QObject, QTimer, Signal
from PySide6.QtWidgets import QFileDialog, QLabel, QMainWindow

from . import _rpc

log = logging.getLogger("normet.R")

INSTALL_HINT = 'remotes::install_github("apai-sys/normet-r")'


class _Checked(QObject):
    done = Signal(object)


class RShellMixin(QMainWindow):
    def _build_r_menu(self, mb) -> None:
        rm = mb.addMenu("&R")
        rm.addAction("&Locate Rscript…", self._locate_rscript)
        rm.addAction("&Check R environment", self._check_r)
        rm.addSeparator()
        save = rm.addAction("Save Figure as R &Script…", self._save_figure_r)
        save.setToolTip(
            "The result the open tab shows, as a CSV and the R that draws it with the normet "
            "package's ggplot2 figures (Normalised, Decomposition, Rolling, PDP)."
        )
        self.r_label = QLabel("R: checking…")
        self.r_label.setStyleSheet("padding: 0 6px;")
        self.statusBar().insertPermanentWidget(0, self.r_label)
        self._r_checked = _Checked(self)
        self._r_checked.done.connect(self._show_r_state)
        # Asked as the window opens; the app's warm-up asks the same, and R answers once.
        # The label as its context: a window closed before then is not asked about.
        QTimer.singleShot(0, self.r_label, lambda: self._check_r(fresh=False))

    def _check_r(self, fresh: bool = True) -> None:
        """Ask R, off the interface thread, which normet and which backends it has;
        *fresh* asks again rather than reading the answer already had."""
        from .nm import _r

        self.r_label.setText("R: checking…")
        if fresh:
            _r.r_check.cache_clear()

        def ask() -> None:
            try:
                state: object = _r.r_check()
            except Exception as exc:  # noqa: BLE001 - shown, not raised
                state = exc
            self._r_checked.done.emit(state)

        threading.Thread(target=ask, name="normet-r-check", daemon=True).start()

    def _show_r_state(self, state: object) -> None:
        if isinstance(state, _rpc.RNotFound):
            self.r_label.setText("R: not found")
            self.notify(
                "R was not found. Install R and the normet package, or point the window at "
                "Rscript (R → Locate Rscript…).",
                key="r-missing",
                kind="warn",
                actions=(("Locate Rscript…", self._locate_rscript),),
            )
            return
        if isinstance(state, Exception):
            self.r_label.setText("R: normet package missing")
            self.notify(
                "R was found but the normet package could not be loaded. Install it in R with: "
                + INSTALL_HINT,
                key="r-missing",
                kind="warn",
            )
            log.warning("%s", state)
            return
        assert isinstance(state, dict)
        backends = [b for b in ("lightgbm", "h2o") if state.get(b)]
        # Short, as the status line's message has the room it has in normet-py's window.
        self.r_label.setText(f"R {state.get('r')}")
        self.r_label.setToolTip(
            f"normet {state.get('normet')} · backends: " + (", ".join(backends) or "none installed")
        )
        log.info("R environment: normet %s (backends: %s)", state.get("normet"), ", ".join(backends) or "none")
        if not backends:
            self.notify(
                "Neither lightgbm nor h2o loads in R: install one to train "
                "(install.packages('lightgbm')).",
                key="r-backends",
                kind="warn",
            )

    def _figure_r_result(self):  # noqa: ANN202 - (key, table) or None
        """The open tab's result that the R package draws, as the tab shows it: for the
        Decomposition, the method its selector shows."""
        from ._r_figures import FIGURES

        tabs = {
            self.tab_norm: "normalise",
            self.tab_decom: "decompose",
            self.tab_roll: "rolling",
            self.tab_pdp: "pdp",
        }
        tab = self.tabs.currentWidget()
        key = tabs.get(tab)
        if key not in FIGURES:
            return None
        result = self.results.get(key)
        views = getattr(tab, "_views", None)
        if key == "decompose" and views and views[2] in views[1]:
            result = views[1][views[2]][1]
        return (key, result) if isinstance(result, pd.DataFrame) and len(result) else None

    def _save_figure_r(self) -> None:
        """R → Save Figure as R Script…: the open tab's result written as a CSV and the R
        that draws it (._r_figures)."""
        from . import _r_figures
        from ._shell import report_language

        found = self._figure_r_result()
        if found is None:
            self.notify(
                "Open the Normalised, Decomposition, Rolling or PDP tab with a result to save "
                "its figure as an R script.",
                key="figure-r",
            )
            return
        key, result = found
        path, _ = QFileDialog.getSaveFileName(
            self, "Save Figure as R Script", f"{_r_figures.FIGURES[key].table}.R", "R script (*.R)"
        )
        if not path:
            return
        try:
            written = _r_figures.write(
                key,
                result,
                path,
                target=self.target_combo.currentText(),
                lang=report_language(),  # a figure for a paper, as the report is written
            )
        except OSError as exc:
            self.notify(f"Could not save: {exc}", key="figure-r", kind="fail")
            return
        self.statusBar().showMessage(f"Saved {written.name} and {written.with_suffix('.csv').name}.")
        log.info("Figure saved as an R script: %s", written)

    def _locate_rscript(self) -> None:
        path, _ = QFileDialog.getOpenFileName(self, "Locate Rscript", "", "Rscript (Rscript*)")
        if not path:
            return
        _rpc.save_rscript(path)
        _rpc.set_rscript(path)
        self._check_r()

    def _close_r(self) -> None:
        """The R side cleaned up: an H2O cluster this window started shut down, the
        session's folder removed."""
        try:
            from .nm import _r

            if _r.used_h2o():
                _rpc.call(".gui_shutdown_h2o")
        except Exception:  # noqa: BLE001 - the window is closing either way
            pass
        _rpc.cleanup()
