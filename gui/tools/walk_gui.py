"""
Walk the R window's workflows off-screen against R, and grab each tab to a PNG.

normet-py's ``docs/manual/make_figures.py``, on this window: the bundled MY1 record
(hourly NO2 and ERA5 meteorology at London Marylebone Road, January to August 2020)
trained with LightGBM, then normalised, decomposed both ways, rolled, split by time
scale and its partial dependence drawn, each as the panel's buttons do it; the SCM
Studio on the bundled ULEZ panel; the Transport Studio on the tdump files that ship
with normet; the Data Studio as it opens. The tasks run on the calling thread (so a
grab follows the result onto the screen); everything else is the window's own code,
and every analysis is R's.

    QT_QPA_PLATFORM=offscreen python gui/tools/walk_gui.py [out_dir] [--only main,scm,transport,data]

With NORMET_UI_LANGUAGE=zh the window is drawn in Chinese. The PNGs are named as
normet-py's manual figures are, into this window's manual (docs/manual/figures, or
figures_zh), and to be set beside normet-py's.
"""

import argparse
import os
import sys
import tempfile
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

# The window keeps recent tables and its run history under ~/.normet: a home of its own,
# with matplotlib pointed back at the real font cache.
_REAL_HOME = os.path.expanduser("~")
os.environ.setdefault("MPLCONFIGDIR", os.path.join(_REAL_HOME, ".matplotlib"))
_HOME = tempfile.mkdtemp(prefix="normet-r-walk-home-")
os.environ["HOME"] = _HOME
os.environ["USERPROFILE"] = _HOME

import matplotlib  # noqa: E402

matplotlib.use("QtAgg")
from matplotlib.backends.backend_qtagg import FigureCanvasQTAgg  # noqa: E402
from PySide6.QtCore import Qt  # noqa: E402
from PySide6.QtWidgets import QApplication  # noqa: E402

LANG = os.environ.setdefault("NORMET_UI_LANGUAGE", "en")
SIZE = (1320, 860)
OUT = ""

#: MY1's meteorology: every column but the target.
MY1_MET = ["ws", "wd", "temp", "RH", "atmos_pres", "blh", "tcc", "tp", "ssrd"]


def run_inline(runner):
    """Run the window's tasks on this thread, through the same record/commit and
    result handlers its worker thread would call."""

    def submit(name, fn, on_result, on_error, *args, **kwargs):
        commit = runner.record(fn, args, kwargs) if runner.record is not None else None
        runner.task_name = name
        try:
            result = fn(*args, **kwargs)
        except Exception:
            # Printed, not handed to the window: its error box is modal, and off-screen
            # nobody closes it.
            traceback.print_exc(limit=8)
            raise
        if commit is not None:
            commit()
        on_result(result)
        runner.finished.emit()
        return True

    runner.submit = submit


def _settle(win):
    for _ in range(6):
        QApplication.sendPostedEvents()
        QApplication.processEvents()
    for canvas in win.findChildren(FigureCanvasQTAgg):
        if canvas.isVisible():
            canvas.draw()
    for _ in range(6):
        QApplication.sendPostedEvents()
        QApplication.processEvents()
    win.repaint()


def grab(win, name):
    _settle(win)
    win.grab().save(os.path.join(OUT, name))
    print("  wrote", name)


def said(tab):
    """Print what a result tab says above its figure: the verdict and the notes."""
    from PySide6.QtWidgets import QLabel

    for label in tab.findChildren(QLabel):
        if label.isVisible() and label.text().strip():
            print("  |", label.text().strip()[:300])


def tick(widget, names):
    """Tick exactly *names* in a checklist."""
    for i in range(widget.count()):
        item = widget.item(i)
        item.setCheckState(Qt.CheckState.Checked if item.text() in names else Qt.CheckState.Unchecked)


def main_figures():
    from normet_r_gui.main_window import MainWindow

    win = MainWindow()
    win.resize(*SIZE)
    win.show()
    run_inline(win.runner)

    print("welcome")
    win.start_layout()
    grab(win, "ui_welcome.png")
    win.toggle_panel(True)
    win.assistant.hide()

    win.load_example("my1")
    tick(win.feature_list, MY1_MET)
    print("data:", win.data_summary.text())
    grab(win, "ui_data.png")

    print("train")
    win.show_panel_page("Model")
    win.backend_combo.setCurrentText("lightgbm")
    win.budget_spin.setValue(10)
    win.split_combo.setCurrentText("random")
    win._run_train()
    print(win.results["train"].to_string())
    said(win.tab_model)
    grab(win, "ui_model.png")

    print("normalise")
    win.show_panel_page("Normalise")
    tick(win.norm_vars, MY1_MET)
    win.norm_quantiles.setChecked(True)
    win.norm_samples.setValue(300)
    win._run_normalise()
    res = win.results["normalise"]
    print("  columns:", list(res.columns))
    print(res[["observed", "normalised"]].resample("MS").mean().round(1).to_string())
    said(win.tab_norm)
    grab(win, "ui_normalise.png")

    print("decompose: emission")
    win.show_panel_page("Decompose")
    win.decom_method.setCurrentText("emission")
    win.decom_samples.setValue(100)
    win._run_decompose()
    emi = win.results["decompose"]
    print("  columns:", list(emi.columns))
    said(win.tab_decom)
    grab(win, "ui_decompose_emission.png")

    print("decompose: meteorology, four groups")
    win.decom_method.setCurrentText("meteorology")
    win.decom_attribution.setCurrentText("auto")
    win.decom_groups.suggest()
    win._run_decompose()
    met = win.results["decompose"]
    print("  columns:", list(met.columns))
    said(win.tab_decom)
    grab(win, "ui_decompose_met.png")

    print("rolling")
    win.show_panel_page("Rolling")
    win.roll_window.setValue(14)
    win.roll_step.setValue(7)
    win.roll_samples.setValue(50)
    win._run_rolling()
    rolled = win.results["rolling"]
    print("  windows:", sum(c.startswith("window_") for c in rolled.columns), list(rolled.columns)[:6])
    grab(win, "ui_rolling.png")

    print("multi-scale")
    win.show_panel_page("Decompose")
    win.ms_fast.setValue(14)
    win.ms_meso.setValue(60)
    win.ms_slow.setValue(120)
    win._run_multiscale()
    said(win.tab_multiscale)
    grab(win, "ui_multiscale.png")

    print("pdp")
    win.show_panel_page("PDP")
    tick(win.pdp_vars, ["ws", "temp", "blh", "hour"])
    win.pdp_grid.setValue(40)
    win._run_pdp()
    print("  columns:", list(win.results["pdp"].columns))
    grab(win, "ui_pdp.png")

    print("command log")
    win.show_log_page(1)  # View → Command Log…: a window of its own
    grab(win._log_windows[1], "ui_command_log.png")
    win._log_windows[1].close()
    print(win.command_log.script())

    print("print dialog")
    from normet_r_gui.printview import PrintDialog

    canvas = win.tab_norm.findChild(FigureCanvasQTAgg)
    dlg = PrintDialog(canvas, win, settings={"preset": "nature"}, on_settings=lambda s: None)
    dlg.resize(1280, 860)
    dlg.show()
    grab(dlg, "ui_print.png")
    dlg.reject()
    _settle(win)

    print("polar plot")
    win.open_polar_plot()
    polar = win._polar_window
    polar.resize(760, 640)
    polar.show()
    grab(polar, "ui_polar.png")
    polar.close()

    print("methods paragraph")
    win.show_methods_paragraph()
    methods = win._methods_dialog
    methods.resize(760, 560)
    grab(methods, "ui_methods.png")
    methods.close()
    _settle(win)
    return win


def scm_figures():
    from normet_r_gui.scm_window import SCMWindow

    print("scm")
    w = SCMWindow(parent=None)
    w.resize(*SIZE)
    w.show()
    run_inline(w.runner)
    w.load_example("ulez")
    print(f"  {w.donor_list.count()} donors, {w.df['date'].nunique()} months")
    w.panel.show_page("Design")
    said(w.tab_panel)
    grab(w, "ui_scm_panel.png")

    w.panel.show_page("Estimator")
    w.backend_combo.setCurrentText("scm")
    w._run_fit()
    said(w.tab_fit)
    d = w.diagnostics
    keys = ("pre_r2", "pre_rmse", "att", "hhi", "effective_n_donors", "n_donors", "top_donors")
    print("  diagnostics:", {k: d.get(k) for k in keys})
    grab(w, "ui_scm_fit.png")
    w.panel.show_page("Inference")
    w._run_placebo_space()
    said(w.tab_pspace)
    grab(w, "ui_scm_placebo.png")
    w.unc_method.setCurrentText("jackknife")
    w._run_uncertainty()
    said(w.tab_unc)
    grab(w, "ui_scm_bands.png")
    return w


def transport_figures():
    from normet_r_gui import nm
    from normet_r_gui.trajectory_window import TrajectoryWindow

    print("transport")
    w = TrajectoryWindow(parent=None)
    w.resize(*SIZE)
    w.show()
    run_inline(w.runner)
    folder = nm.datasets.example_traj_dir()
    for name in sorted(os.listdir(folder)):
        if name.startswith("tdump"):
            w._tdump_paths.append(os.path.join(str(folder), name))
            w.tdump_list.addItem(name)
    w.build_site_edit.setText("MY1")
    w._sync_enabled()
    w._run_build()
    grab(w, "ui_transport.png")
    return w


def data_studio_figure():
    from normet_r_gui.data_window import DataWindow

    print("data studio")
    w = DataWindow(parent=None)
    w.resize(*SIZE)
    w.show()
    grab(w, "ui_data_studio.png")
    return w


STEPS = {"main": main_figures, "scm": scm_figures, "transport": transport_figures, "data": data_studio_figure}


def main():
    global OUT
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[1])
    # The manual's figures, as normet-py's make_figures.py writes its own.
    manual = os.path.join(HERE, "..", "docs", "manual")
    p.add_argument("out_dir", nargs="?", default=os.path.join(manual, "figures" if LANG == "en" else f"figures_{LANG}"))
    p.add_argument("--only", default=",".join(STEPS), help="comma-separated: " + ", ".join(STEPS))
    a = p.parse_args()
    OUT = os.path.abspath(a.out_dir)
    os.makedirs(OUT, exist_ok=True)

    app = QApplication.instance() or QApplication(sys.argv)
    app.setStyle("Fusion")
    app.setApplicationName("Normet")
    app.setOrganizationName("apai-sys")
    from normet_r_gui import uilang

    uilang.install(app)
    from normet_r_gui.nm.style import apply_style

    apply_style()
    keep = [STEPS[s]() for s in a.only.split(",")]
    print(f"done: {len(keep)} windows -> {OUT}")


if __name__ == "__main__":
    main()
