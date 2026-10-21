"""The Assistant's carry_out and api_help in this window: normet's R API, run in R."""

from __future__ import annotations

import os
import time

import pandas as pd
import pytest

pytest.importorskip("PySide6")
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from normet_r_gui import _rpc  # noqa: E402

pytestmark = pytest.mark.skipif(not _rpc.rscript(), reason="needs Rscript and the normet R package")


@pytest.fixture(scope="module")
def qapp():
    from PySide6.QtWidgets import QApplication

    return QApplication.instance() or QApplication([])


def test_api_help_reads_the_r_package():
    from normet_r_gui import _code

    listed = _code.api_help("")
    assert "- nm_rolling:" in listed and "- nm_normalise:" in listed
    assert _code.api_help("rolling").startswith("nm_rolling(df")  # nm_ may be left off
    with pytest.raises(ValueError, match="did you mean"):
        _code.api_help("rollng")


def test_code_runs_in_r_on_the_table():
    from normet_r_gui import _code

    df = pd.DataFrame({"date": pd.date_range("2020-01-01", periods=48, freq="h"), "NO2": range(48)})
    said = _code.run_code("nrow(df)\nkept <- df[df$NO2 > 40, ]", df)
    assert "[1] 48" in said and "kept: 7 rows x 2 columns" in said
    assert "Error:\nboom" in _code.run_code("stop('boom')", df)


def test_carry_out_runs_r_from_the_card(qapp, monkeypatch, tmp_path):
    from PySide6.QtCore import QSettings
    from PySide6.QtWidgets import QPushButton

    from normet_r_gui import assistant
    from normet_r_gui.main_window import MainWindow

    ini = str(tmp_path / "normet-r-gui.ini")
    monkeypatch.setattr(assistant, "_settings", lambda: QSettings(ini, QSettings.Format.IniFormat))
    win = MainWindow()
    try:
        win.load_example("my1")
        dock = win.assistant
        assert "R: library(normet)" in assistant.system_prompt()
        dock.tools.carry_out("print(dim(df))", "the table's size")
        qapp.processEvents()
        btn = [b for b in dock.view.findChildren(QPushButton) if b.text() == "Run"][0]
        btn.click()
        t0 = time.time()
        while not dock.notes and time.time() - t0 < 120:
            qapp.processEvents()
            time.sleep(0.05)
        assert f"[1] {len(win.df_raw)}" in dock.notes[-1]
    finally:
        win.close()
