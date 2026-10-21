"""Shared set-up for the window's tests (normet-py's GUI tests among them, vendored by
tools/vendor_py_gui.py)."""

from __future__ import annotations

import os
import sys
from pathlib import Path

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

# The window from this checkout, installed or not -- here and in the processes a test
# starts of its own (the Chinese window's smoke runs).
GUI = str(Path(__file__).resolve().parents[1])
if GUI not in sys.path:
    sys.path.insert(0, GUI)
os.environ["PYTHONPATH"] = os.pathsep.join(p for p in (GUI, os.environ.get("PYTHONPATH")) if p)


@pytest.fixture(autouse=True)
def _close_figures():
    """Every matplotlib figure a test leaves behind released, as normet-py's suite does."""
    yield
    if "matplotlib.pyplot" in sys.modules:
        sys.modules["matplotlib.pyplot"].close("all")


def pytest_sessionfinish(session, exitstatus):
    """The windows the tests left open deleted while the QApplication still runs: left
    to the interpreter's exit, Python and Qt free them in no fixed order, and the run
    can abort after every test passed (normet-py's conftest)."""
    if "PySide6.QtWidgets" not in sys.modules:
        return
    from PySide6.QtCore import QCoreApplication, QEvent
    from PySide6.QtWidgets import QApplication

    if QApplication.instance() is None:
        return
    for w in QApplication.topLevelWidgets():
        w.close()
        w.deleteLater()
    QCoreApplication.sendPostedEvents(None, QEvent.Type.DeferredDelete)
    QCoreApplication.processEvents()
