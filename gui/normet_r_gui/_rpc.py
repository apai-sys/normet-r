"""One call into the normet R package: ``Rscript rpc.R <request.json>``.

The window's analyses are normet's R functions, called one at a time in an R process
of their own. :func:`call` writes the function's name and arguments as a JSON request
in the session's folder, runs ``rpc.R`` on it, and reads its value back:

- a pandas DataFrame crosses as a CSV with each column's type (number, whole number,
  logical, text, time, date, factor and its levels), and comes back as it went;
- a model, or any R object JSON cannot hold, stays an R object: saved as ``.rds`` in
  the folder and handed back as an :class:`RObject`, which is passed again as it is;
- lists, dicts, numbers, text and ``None`` cross as JSON.

R's log lines (normet logs to stderr) are passed on to the window's log as they are
written, an R error is raised here as :class:`RError` in R's words, and
:func:`cancel` stops the call in progress.
"""

from __future__ import annotations

import contextlib
import datetime as _dt
import itertools
import json
import logging
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import numpy as np
import pandas as pd

log = logging.getLogger("normet.R")  # into the window's log, as normet's own lines are


def _rpc_r_path() -> Path:
    """rpc.R in an install, a source tree, or a PyInstaller app."""
    candidates = [Path(__file__).resolve().parent / "rpc.R"]
    if getattr(sys, "frozen", False):
        candidates.append(Path(getattr(sys, "_MEIPASS", "")) / "normet_r_gui" / "rpc.R")
    return next((c for c in candidates if c.is_file()), candidates[0])


RPC_R = _rpc_r_path()


class RError(RuntimeError):
    """An R function failed: its message, as R gave it."""


class RNotFound(RError):
    """No Rscript to run."""


def find_rscript() -> str | None:
    """Rscript on the PATH, the one the window was pointed at, or in R's usual places."""
    chosen = saved_rscript()
    if chosen and Path(chosen).is_file():
        return chosen
    found = shutil.which("Rscript")
    if found:
        return found
    for candidate in (
        "/usr/local/bin/Rscript",
        "/opt/homebrew/bin/Rscript",
        "/Library/Frameworks/R.framework/Resources/bin/Rscript",
        *sorted(Path("C:/Program Files/R").glob("R-*/bin/Rscript.exe"), reverse=True),
    ):
        if Path(candidate).is_file():
            return str(candidate)
    return None


def _qsettings():
    from PySide6.QtCore import QSettings

    return QSettings("apai-sys", "normet-r-gui")


def saved_rscript() -> str | None:
    """The Rscript the window was pointed at (R → Locate Rscript…), if any."""
    try:
        value = _qsettings().value("rscript")
    except Exception:  # noqa: BLE001 - no Qt: no saved choice
        return None
    return str(value) if value else None


def save_rscript(path: str) -> None:
    _qsettings().setValue("rscript", path)


@dataclass
class RObject:
    """An R object kept in the session's folder (a model, a fitted result): its ``.rds``
    file, its R class, and for a model its backend and features."""

    path: str
    info: dict[str, Any] = field(default_factory=dict)

    @property
    def r_class(self) -> list[str]:
        return list(self.info.get("class") or [])

    @property
    def backend(self) -> str | None:
        return self.info.get("backend")

    @property
    def feature_names(self) -> list[str]:
        return list(self.info.get("features") or [])

    def __repr__(self) -> str:
        cls = "/".join(self.r_class) or "R object"
        return f"<R {cls} {os.path.basename(self.path)}>"

    # Pickled (a saved session, the autosave) with its files: the session's folder is
    # gone once the window closes, so the object takes its .rds or model folder along,
    # zipped, and is unpacked into the folder of the window that reads it back.
    def __getstate__(self) -> dict[str, Any]:
        import io
        import zipfile

        src = Path(self.path)
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as zf:
            files = sorted(p for p in src.rglob("*") if p.is_file()) if src.is_dir() else [src]
            for f in files:
                zf.write(f, f.relative_to(src.parent))
        return {"name": src.name, "files": buf.getvalue(), "info": dict(self.info)}

    def __setstate__(self, state: dict[str, Any]) -> None:
        import io
        import zipfile

        dest = Path(tempfile.mkdtemp(prefix="restored_", dir=session_dir()))
        with zipfile.ZipFile(io.BytesIO(state["files"])) as zf:
            zf.extractall(dest)
        self.path = str(dest / state["name"])
        self.info = state["info"]


# -- the session's folder ----------------------------------------------------------------

_state: dict[str, Any] = {"dir": None, "rscript": None, "proc": None}
_lock = threading.Lock()
_ids = itertools.count(1)


def session_dir() -> Path:
    """Where the calls' requests, tables and R objects are kept: one folder per window."""
    if _state["dir"] is None:
        _state["dir"] = Path(tempfile.mkdtemp(prefix="normet_r_gui_"))
    return Path(_state["dir"])


def set_rscript(path: str | None) -> None:
    _state["rscript"] = path


def rscript() -> str | None:
    if _state["rscript"] is None:
        _state["rscript"] = find_rscript()
    return _state["rscript"]


def cleanup() -> None:
    """The session's folder removed (the window closing)."""
    if _state["dir"] is not None:
        shutil.rmtree(_state["dir"], ignore_errors=True)
        _state["dir"] = None


# -- values ------------------------------------------------------------------------------


def _write_df(df: pd.DataFrame, folder: Path, n: int) -> dict[str, Any]:
    out = df.copy()
    if not isinstance(out.index, pd.RangeIndex) and out.index.name is not None:
        out = out.reset_index()
    out.columns = [str(c) for c in out.columns]
    types: dict[str, str] = {}
    levels: dict[str, list[str]] = {}
    for col in out.columns:
        s = out[col]
        if isinstance(s.dtype, pd.CategoricalDtype):
            types[col] = "factor"
            levels[col] = [str(v) for v in s.cat.categories]
            out[col] = s.astype(str).where(s.notna(), None)
        elif pd.api.types.is_datetime64_any_dtype(s):
            types[col] = "datetime"
            if getattr(s.dt, "tz", None) is not None:
                s = s.dt.tz_convert("UTC").dt.tz_localize(None)
            out[col] = s.dt.strftime("%Y-%m-%dT%H:%M:%S.%f").where(s.notna(), None)
        elif pd.api.types.is_bool_dtype(s):
            types[col] = "logical"
            out[col] = s.map({True: "TRUE", False: "FALSE"})
        elif pd.api.types.is_integer_dtype(s):
            types[col] = "integer"
        elif pd.api.types.is_numeric_dtype(s):
            types[col] = "double"
        else:
            types[col] = "character"
    path = folder / f"in_{n}_{next(_ids)}.csv"
    out.to_csv(path, index=False, na_rep="NA", encoding="utf-8")
    return {"__df__": str(path), "types": types, "levels": levels}


def _encode(value: Any, folder: Path, n: int) -> Any:
    if value is None:
        return None
    if isinstance(value, RObject):
        if value.info.get("kind") == "model":
            return {"__model__": value.path, "backend": value.backend}
        return {"__rds__": value.path}
    if isinstance(value, pd.DataFrame):
        return _write_df(value, folder, n)
    if isinstance(value, pd.Series):
        return _encode(value.tolist(), folder, n)
    if isinstance(value, (pd.Timestamp, _dt.datetime)):
        ts = pd.Timestamp(value)
        if ts.tzinfo is not None:
            ts = ts.tz_convert("UTC").tz_localize(None)
        return {"__date__": ts.strftime("%Y-%m-%dT%H:%M:%S.%f")}
    if isinstance(value, _dt.date):
        return value.isoformat()
    if isinstance(value, np.generic):
        return value.item()
    if isinstance(value, np.ndarray):
        return [_encode(v, folder, n) for v in value.tolist()]
    if isinstance(value, dict):
        return {str(k): _encode(v, folder, n) for k, v in value.items() if v is not None}
    if isinstance(value, (list, tuple, set)):
        items = [_encode(v, folder, n) for v in value]
        # A list of tables or objects stays a list in R; plain values become a vector.
        if any(isinstance(v, dict) for v in items):
            return {"__list__": items}
        return items
    return value


def _read_df(spec: dict[str, Any]) -> pd.DataFrame:
    types = spec.get("types") or {}
    levels = spec.get("levels") or {}
    df = pd.read_csv(spec["__df__"], na_values=["NA"], keep_default_na=False, encoding="utf-8")
    for col, kind in types.items():
        if col not in df.columns:
            continue
        s = df[col]
        if kind == "datetime":
            df[col] = pd.to_datetime(s, format="%Y-%m-%dT%H:%M:%S.%f", errors="coerce")
        elif kind == "date":
            df[col] = pd.to_datetime(s, format="%Y-%m-%d", errors="coerce")
        elif kind == "factor":
            cats = [str(v) for v in (levels.get(col) or [])]
            vals = s.astype("string").where(s.notna(), None)
            # Whole-number levels (a weekday 1..7) come back as numbers, as pandas has them.
            if cats and all(c.lstrip("-").isdigit() for c in cats):
                df[col] = pd.Categorical(
                    pd.to_numeric(vals, errors="coerce"), categories=[int(c) for c in cats]
                )
            else:
                df[col] = pd.Categorical(vals, categories=cats or None)
        elif kind == "logical":
            df[col] = s.map({True: True, False: False, "TRUE": True, "FALSE": False})
        elif kind == "integer":
            df[col] = pd.to_numeric(s, errors="coerce")
            if not df[col].isna().any():
                df[col] = df[col].astype("int64")
        elif kind == "double":
            df[col] = pd.to_numeric(s, errors="coerce").astype(float)
        else:
            df[col] = s.astype(object).where(s.notna(), None)
    return df


def _decode(value: Any) -> Any:
    if isinstance(value, dict):
        if "__df__" in value:
            return _read_df(value)
        if "__model__" in value:
            info = {k: v for k, v in value.items() if k != "__model__"}
            return RObject(value["__model__"], {**info, "kind": "model"})
        if "__rds__" in value:
            info = {k: v for k, v in value.items() if k != "__rds__"}
            return RObject(value["__rds__"], info)
        if "__date__" in value:
            return pd.Timestamp(value["__date__"])
        if "__dates__" in value:
            return pd.DatetimeIndex(pd.to_datetime(value["__dates__"], errors="coerce"))
        return {k: _decode(v) for k, v in value.items()}
    if isinstance(value, list):
        return [_decode(v) for v in value]
    return value


# -- the call ----------------------------------------------------------------------------


#: normet's R logger writes ``INFO [17:10:24.727] message``; the window's log has its own
#: level and time, so the line is logged at R's level with only its message.
_R_LINE = re.compile(r"^(TRACE|DEBUG|INFO|WARN|ERROR|FATAL)\s+\[[\d:.]+\]\s?(.*)$")
_R_LEVEL = {"TRACE": logging.DEBUG, "DEBUG": logging.DEBUG, "INFO": logging.INFO,
            "WARN": logging.WARNING, "ERROR": logging.ERROR, "FATAL": logging.ERROR}
#: rpc.R's line for the share of the call done (the package's own reports): passed on to
#: whoever listens on this thread (normet.utils.progress, the window's task clock), not logged.
_PROGRESS = re.compile(r"^NM_PROGRESS ([0-9.]+)$")


def _forward(stream: Any, lines: list[str], on_line: Callable[[str], None] | None) -> None:
    for raw in iter(stream.readline, ""):
        line = raw.rstrip("\n")
        if not line.strip() or line.strip() == "RPC_DONE":
            continue
        share = _PROGRESS.match(line)
        if share:
            from .nm.utils import progress  # here: nm's own imports come through this module

            progress.report(round(10000 * float(share.group(1))), 10000)
            continue
        lines.append(line)
        m = _R_LINE.match(line)
        if m:
            log.log(_R_LEVEL[m.group(1)], "%s", m.group(2))
        else:
            log.info("%s", line)
        if on_line is not None:
            try:
                on_line(line)
            except Exception:  # noqa: BLE001 - a listener's fault is not the call's
                pass


class Captured(Exception):
    """Raised by :func:`call` inside :func:`capture` (without an answer): the call was
    recorded, not made."""


_capturing = threading.local()


@contextlib.contextmanager
def capture(answer: Callable[[], Any] | None = None):
    """Inside it, on this thread, :func:`call` runs no R: it records each call as it
    would send it -- ``(fn, args, kwargs)``, the keywords given as None left out -- in
    the list this yields, then raises :class:`Captured` or, given *answer*, returns
    ``answer()``. The command log writes the R a task runs this way (``commandlog``).
    What the code run logs meanwhile, on this thread, is not shown: run on empty
    answers, it would say what did not happen."""
    calls: list[tuple[str, tuple[Any, ...], dict[str, Any]]] = []
    _capturing.calls, _capturing.answer = calls, answer
    handlers = {*logging.getLogger().handlers, *logging.getLogger("normet").handlers}
    for h in handlers:
        h.addFilter(_not_captured)
    try:
        yield calls
    finally:
        _capturing.calls = _capturing.answer = None
        for h in handlers:
            h.removeFilter(_not_captured)


def _not_captured(record: logging.LogRecord) -> bool:
    """A log record kept unless its thread is inside :func:`capture`."""
    return getattr(_capturing, "calls", None) is None


def call(fn: str, *args: Any, on_line: Callable[[str], None] | None = None, **kwargs: Any) -> Any:
    """``fn(*args, **kwargs)`` in R: a normet function, or one of rpc.R's ``.gui_*``
    helpers. Keyword arguments given as ``None`` are left out, so R's defaults apply."""
    calls = getattr(_capturing, "calls", None)
    if calls is not None:
        calls.append((fn, args, {k: v for k, v in kwargs.items() if v is not None}))
        if _capturing.answer is None:
            raise Captured(fn)
        return _capturing.answer()
    exe = rscript()
    if not exe:
        raise RNotFound(
            "Rscript was not found. Install R (https://cran.r-project.org) and the normet "
            "package, or point the window at Rscript (R → Locate Rscript…)."
        )
    folder = session_dir()
    n = next(_ids)
    request = {
        "fn": fn,
        "args": [_encode(a, folder, n) for a in args],
        "kwargs": {k: _encode(v, folder, n) for k, v in kwargs.items() if v is not None},
    }
    path = folder / f"call_{n:04d}.json"
    path.write_text(json.dumps(request, default=str), encoding="utf-8")
    answer = folder / f"call_{n:04d}.out.json"
    shown = ", ".join([*(k for k in request["kwargs"])])
    log.info("R> %s(%s)", fn, shown)
    env = dict(os.environ, R_DEFAULT_PACKAGES="datasets,utils,grDevices,graphics,stats,methods")
    proc = subprocess.Popen(
        [exe, "--vanilla", str(RPC_R), str(path)],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        encoding="utf-8",
        errors="replace",
        env=env,
        # A group of its own, so a stop ends what R started too (see _kill_tree).
        **_OWN_GROUP,
    )
    with _lock:
        _state["proc"] = proc
    lines: list[str] = []
    try:
        assert proc.stdout is not None
        _forward(proc.stdout, lines, on_line)
        code = proc.wait()
    finally:
        with _lock:
            if _state["proc"] is proc:
                _state["proc"] = None
    if code < 0 or (code != 0 and not answer.is_file()):
        if _state.get("cancelled") is proc:
            raise RError("Stopped.")
        tail = "\n".join(lines[-15:])
        raise RError(f"R stopped while running {fn}:\n{tail}" if tail else f"R stopped running {fn}.")
    out = json.loads(answer.read_text(encoding="utf-8"))
    if "error" in out:
        raise RError(str(out["error"]))
    return _decode(out.get("value"))


_OWN_GROUP: dict[str, Any] = (
    {"creationflags": subprocess.CREATE_NEW_PROCESS_GROUP} if os.name == "nt" else {"start_new_session": True}
)


def cancel() -> bool:
    """Stop the R call in progress, if there is one."""
    with _lock:
        proc = _state["proc"]
    if proc is None or proc.poll() is not None:
        return False
    _state["cancelled"] = proc
    _kill_tree(proc)
    return True


def _kill_tree(proc: subprocess.Popen) -> None:
    """R and every process it started: one left running would hold R's output open,
    and the call would wait on it."""
    if os.name == "nt":
        subprocess.run(["taskkill", "/T", "/F", "/PID", str(proc.pid)], capture_output=True, check=False)
        proc.kill()
        return
    # Found before R is killed: its children are then no longer R's. R runs a command
    # it gives a time limit (HYSPLIT) in a group of its own, so each is killed by name.
    pids = _descendants(proc.pid)
    for kill in (lambda: os.killpg(proc.pid, 9), *(lambda p=p: os.kill(p, 9) for p in pids)):
        with contextlib.suppress(OSError):
            kill()
    proc.kill()


def _descendants(pid: int) -> list[int]:
    try:
        ps = subprocess.run(["ps", "-A", "-o", "pid=,ppid="], capture_output=True, text=True, check=False)
    except OSError:
        return []
    children: dict[int, list[int]] = {}
    for line in ps.stdout.splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[0].isdigit() and parts[1].isdigit():
            children.setdefault(int(parts[1]), []).append(int(parts[0]))
    out, todo = [], [pid]
    while todo:
        for c in children.get(todo.pop(), []):
            out.append(c)
            todo.append(c)
    return out
