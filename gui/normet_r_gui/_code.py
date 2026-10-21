"""The Assistant's carry_out in this window: normet's R API, written as R, run in R.

normet-py's window runs carry_out's code as Python (its ``_code``); this one runs it in
R, through rpc.R's ``.gui_run_code``, with the window's table bound as ``df`` -- and
reads the API (``api_help``) from the R package's own help pages (``.gui_api_help``).
Not copied from normet-py (``tools/vendor_py_gui.py``): the window's own.
"""

from __future__ import annotations

from typing import Any

import pandas as pd

from . import _rpc

#: The language carry_out's code is written in, as the system prompt says it.
LANGUAGE = "R"
#: How the code is written, for the system prompt: what is loaded and what is bound.
CONVENTIONS = (
    "R: library(normet) is loaded; `df` is the table open (a data.frame, a copy), `df_prep` "
    "and `model` the prepared table and the model trained (NULL before training). normet's "
    "calls are named nm_* (nm_rolling, nm_decompose, nm_detect_events, ...). A value left "
    "visible is printed as R's console prints it; print() what the analyst should read; a "
    "data.frame left in a variable is listed with its head. No files are written unless "
    "the code writes them."
)
#: How much of what it gave is handed back.
MAX_OUTPUT = 6000


def _cut(text: str, most: int = MAX_OUTPUT) -> str:
    return text if len(text) <= most else text[:most] + f"\n… ({len(text) - most:,} more characters)"


def api_help(name: str = "") -> str:
    """normet's API: with no name, its calls listed, a line each; with a name, the call's
    arguments and its help page."""
    try:
        said = str(_rpc.call(".gui_api_help", name.strip()))
        # The list whole (a line a call); a call's page cut where it runs long.
        return said if not name.strip() else _cut(said)
    except _rpc.RError as exc:  # a name it does not have: said to the model
        raise ValueError(str(exc)) from None


def run_code(code: str, df: pd.DataFrame | None, df_prep: Any = None, model: Any = None) -> str:
    """Run *code* in R with normet on the window's table and say what it made: what it
    printed, then each data.frame it left in a variable (its size and head). An error is
    said rather than raised: the model reads it."""
    path = _rpc.session_dir() / "carry_out.R"
    path.write_text(code, encoding="utf-8")
    try:
        said = _rpc.call(".gui_run_code", str(path), df=df, df_prep=df_prep, model=model)
    except _rpc.RError as exc:
        return f"Error:\n{exc}"
    return _cut(str(said))
