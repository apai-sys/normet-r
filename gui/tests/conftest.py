"""Shared set-up for the window's tests (normet-py's GUI tests among them, vendored by
tools/vendor_py_gui.py)."""

from __future__ import annotations

import gc
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

# The window from this checkout, installed or not -- here and in the processes a test
# starts of its own (the Chinese window's smoke runs).
GUI = str(Path(__file__).resolve().parents[1])
if GUI not in sys.path:
    sys.path.insert(0, GUI)
os.environ["PYTHONPATH"] = os.pathsep.join(p for p in (GUI, os.environ.get("PYTHONPATH")) if p)

_MACOS = sys.platform == "darwin"


def _kill_cfprefsd() -> None:
    """Stop macOS's preferences daemon and wait for it to actually go.

    It keeps the settings in memory and flushes them to the file *as it exits*: with
    only a fixed sleep, a copy made underneath it can be overwritten by the cached
    values a moment later (which is how tests' scraps survive a restore). Waiting for
    ``pgrep`` to come back empty closes that race. It restarts by itself when next used.
    Only ever called on macOS.
    """
    try:
        subprocess.run(["killall", "cfprefsd"], capture_output=True, check=False)
    except OSError:
        return
    # Only this user's daemon: killall (run without sudo here) cannot stop the copies
    # other accounts keep, and a bare `pgrep cfprefsd` would wait for those forever.
    for _ in range(100):  # up to 10 s; the flush is a few hundred milliseconds
        try:
            gone = subprocess.run(
                ["pgrep", "-u", str(os.getuid()), "cfprefsd"], capture_output=True
            )
            if gone.returncode != 0:
                return
        except OSError:
            return
        time.sleep(0.1)


def _plist_dict(path: str) -> dict | None:
    """The plist as a dict, or None if there is no file (the file is read directly:
    ``defaults``/QSettings go through the daemon)."""
    try:
        with open(path, "rb") as f:
            return dict(plistlib.load(f))
    except (FileNotFoundError, ValueError, OSError):
        return None


def _window_plist() -> str:
    """Where macOS keeps this window's settings: ``QSettings("apai-sys", "normet-r-gui")``."""
    return os.path.join(
        os.path.expanduser("~"), "Library", "Preferences", "com.apai-sys.normet-r-gui.plist"
    )


def _restore_window_plist(config) -> None:
    """Put the user's real settings back (macOS only; a no-op elsewhere): the file as it
    was, or gone again if the run is what made it.

    cfprefsd can still have a cached copy that outlives one kill, so the file is read
    back after the second kill and, if the daemon overwrote it again, the sequence is
    retried. This is what keeps a test run from leaving its panel page, result tab or
    geometry in the settings of the window the user works in.
    """
    plist = getattr(config, "_window_plist_path", None)
    if not plist:
        return
    backup = getattr(config, "_window_plist_backup", None)
    want = None
    if backup and os.path.exists(backup):
        with open(backup, "rb") as f:
            want = dict(plistlib.load(f))
    for _ in range(5):
        _kill_cfprefsd()
        if want is not None and backup:
            shutil.copy(str(backup), plist)
        elif os.path.exists(plist):
            os.remove(plist)
        _kill_cfprefsd()
        if _plist_dict(plist) == want:
            return


def _headless_guard() -> None:
    """No modal dialog may open in these tests: they run offscreen, where nobody could
    click it, and an uncovered dialog would hang the run (this is how CI's smoke job
    sat for hours at one test). A dialog that appears is a bug the test should report,
    so the call fails at once instead of blocking."""
    from PySide6.QtWidgets import QDialog, QFileDialog, QInputDialog, QMessageBox

    def blocked(kind):
        def _raise(*args, **kwargs):
            texts = [a for a in args if isinstance(a, str)]
            raise AssertionError(f"modal {kind} would block a headless run: {texts}")

        return staticmethod(_raise)

    for name in ("information", "warning", "critical", "question", "about"):
        setattr(QMessageBox, name, blocked(f"QMessageBox.{name}"))
    for name in ("getOpenFileName", "getOpenFileNames", "getSaveFileName", "getExistingDirectory"):
        setattr(QFileDialog, name, blocked(f"QFileDialog.{name}"))
    for name in ("getText", "getInt", "getDouble", "getItem", "getMultiLineText"):
        setattr(QInputDialog, name, blocked(f"QInputDialog.{name}"))

    def _exec(self, *args, **kwargs):
        raise AssertionError(
            f"modal {type(self).__name__}.exec() would block a headless run: {self.windowTitle()!r}"
        )

    QDialog.exec = _exec


def pytest_configure(config):
    """Snapshot the user's real settings before any test touches them, and bar modal
    dialogs (see :func:`_headless_guard`).

    The window keeps its geometry, panel page, result tab, Assistant model and the rest
    in QSettings, which on macOS writes straight to the user's plist whatever ``$HOME``
    or ``QSettings.setPath`` say -- so every test that builds a window would otherwise
    leave its scraps in the settings of the window the user works in. The snapshot goes
    back in ``pytest_sessionfinish``, after the windows are closed. Other platforms keep
    their settings elsewhere (an ini file, the registry) and are left alone.

    The file's path is worked out here, once: some tests move ``$HOME`` to a folder of
    their own, and a run interrupted inside one would otherwise look for the file there.
    """
    try:
        _headless_guard()
    except ImportError:  # noqa: BLE001 - no PySide6: nothing to guard
        pass
    if not _MACOS:
        return
    _kill_cfprefsd()
    plist = config._window_plist_path = _window_plist()
    if os.path.exists(plist):
        config._window_plist_backup = os.path.join(
            tempfile.mkdtemp(prefix="normet_r_plist_bak_"), "backup.plist"
        )
        shutil.copy(plist, config._window_plist_backup)


@pytest.hookimpl(hookwrapper=True)
def pytest_runtest_makereport(item, call):
    """A step that reaches for R where none is installed (CI's smoke job before the R
    setup, a machine without R) is reported skipped, not failed: the R side is covered
    by the R package's own tests; what matters here is that the window runs headless.
    Everything else -- including R *errors* -- still fails as before."""
    outcome = yield
    rep = outcome.get_result()
    if rep.when != "call" or not rep.failed:
        return
    text = str(rep.longrepr)
    if "RNotFound" not in text and "Rscript was not found" not in text:
        return
    rep.outcome = "skipped"
    rep.longrepr = (
        "skipped",
        "R is not installed: the R side is covered by the R package's own tests",
        1,
    )


@pytest.fixture(autouse=True)
def _config_dir_of_its_own(request, monkeypatch, tmp_path_factory):
    """No test writes into the user's ``~/.normet``: the recent files, the run history and
    the last session (which the end of every step rewrites) are the user's own, and a test
    that runs a step would append to the first and overwrite the last. Each test gets a
    folder of its own for them. The tests that make a home of their own (``home``) keep
    it: there ``config_dir`` follows ``$HOME``."""
    if "home" in request.fixturenames:
        return
    try:
        from normet_r_gui import _settings
    except Exception:  # noqa: BLE001 - not the window's tests
        return
    config = str(tmp_path_factory.mktemp("config"))
    monkeypatch.setattr(_settings, "config_dir", lambda: config)


@pytest.fixture(autouse=True)
def _close_figures():
    """Every matplotlib figure a test leaves behind released, as normet-py's suite does."""
    yield
    if "matplotlib.pyplot" in sys.modules:
        sys.modules["matplotlib.pyplot"].close("all")


def _close_windows() -> None:
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
    # Cycles the tests left are freed while the QApplication still exists. Left to
    # the interpreter's own final GC, shiboken frees them after Qt has begun to
    # tear down, and the run can abort after every test passed (`none_dealloc` on
    # Linux CI, 2026-11-13).
    gc.collect()


def pytest_sessionfinish(session, exitstatus):
    """The windows the tests left open deleted while the QApplication still runs: left
    to the interpreter's exit, Python and Qt free them in no fixed order, and the run
    can abort after every test passed (normet-py's conftest).

    Then, on macOS, the user's real settings go back: the windows' closeEvents write
    them, so it has to be after the windows are closed -- and whether or not there was
    a QApplication to close them in."""
    try:
        _close_windows()
    finally:
        _restore_window_plist(session.config)
    session.config._window_exitstatus = int(exitstatus)


def pytest_unconfigure(config):
    """Leave before the interpreter's final collection.

    After every test passed, PySide6 6.11.1 on Linux aborted in finalization
    (``Fatal Python error: none_dealloc: deallocating None``; the pytest process
    exited 134, so the GUI job failed although its summary read "255 passed").
    The crash is inside the C extensions' own teardown, below anything a test can
    release, and the windows are closed and the settings restored by now. The
    summary has been printed when this hook runs; the process leaves with the
    session's status before that collection (2026-11-13).
    """
    sys.stdout.flush()
    sys.stderr.flush()
    os._exit(getattr(config, "_window_exitstatus", 0))
