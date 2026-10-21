"""What the window did, written as the normet R calls that do the same.

Every action that decides a result -- opening a table, training, normalising,
decomposing, a rolling run, partial dependence -- is recorded as the R call that
performs it, so an analysis done by clicking can be repeated, changed and handed on as
an R script.

This is the R window's own module (normet-py's writes Python; ``tools/vendor_py_gui.py``
does not copy it over this one), with the same entries and the same interface. An entry
is written from the call the window actually made, once its task succeeded: the task's
function is run with :func:`._rpc.capture` on, so the R call it would send -- the
function and its arguments, named as R names them -- is recorded instead of made. The
tables and the model the window passes are named as the script names them (``df``,
``df_prep``, ``model``). Where the window did something no call expresses (a table
from the Data Studio, held only in memory), the entry says so in a note instead of a
line that would quietly do something else.
"""

from __future__ import annotations

import datetime
import json
import math
import re
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass, field
from typing import Any

import numpy as np
import pandas as pd

#: Width the generated code wraps at.
WIDTH = 88

#: The line every script starts its calls with.
LIBRARY = "library(normet)"

_SYNTACTIC = re.compile(r"^[A-Za-z][A-Za-z0-9._]*$|^\.[A-Za-z._][A-Za-z0-9._]*$")


def _name(key: Any) -> str:
    """A list element's name as R reads it: backquoted where it is not syntactic."""
    key = str(key)
    return key if _SYNTACTIC.match(key) else "`" + key.replace("`", "\\`") + "`"


def literal(value: Any) -> str:
    """An R literal for a parameter value, exact enough to re-run."""
    if value is None:
        return "NULL"
    if isinstance(value, (np.bool_, bool)):
        return "TRUE" if value else "FALSE"
    if isinstance(value, np.integer):
        value = int(value)
    if isinstance(value, np.floating):
        value = float(value)
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        if math.isnan(value):
            return "NA"
        if math.isinf(value):
            return "-Inf" if value < 0 else "Inf"
        # 12 digits keep every value a person types and drop the float noise.
        short = round(value, 12)
        return str(int(short)) if short == int(short) and abs(short) < 1e15 else repr(short)
    if isinstance(value, (pd.Timestamp, datetime.datetime, datetime.date)):
        return json.dumps(str(value))
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, np.ndarray):
        value = value.tolist()
    if isinstance(value, Mapping):
        return "list(" + ", ".join(f"{_name(k)} = {literal(v)}" for k, v in value.items()) + ")"
    if isinstance(value, (list, tuple)):
        items = list(value)
        if all(v is None or isinstance(v, (str, bool, int, float, np.generic)) for v in items):
            return "c(" + ", ".join(literal(v) for v in items) + ")"
        return "list(" + ", ".join(literal(v) for v in items) + ")"
    return json.dumps(str(value), ensure_ascii=False)


def call(
    target: str | None,
    name: str,
    positional: Sequence[str] = (),
    keywords: Sequence[tuple[str, str]] = (),
) -> str:
    """``target <- name(positional, keyword = …)``, wrapped under the open bracket."""
    args = list(positional) + [f"{k} = {v}" for k, v in keywords]
    head = f"{target} <- {name}(" if target else f"{name}("
    one = head + ", ".join(args) + ")"
    if len(one) <= WIDTH or len(args) < 2:
        return one
    pad = " " * len(head)
    lines: list[str] = []
    current = head + args[0] + ("," if len(args) > 1 else ")") + " "
    for i, arg in enumerate(args[1:], start=1):
        piece = arg + ("," if i < len(args) - 1 else ")")
        if len(current) + len(piece) + 1 > WIDTH:
            lines.append(current.rstrip())
            current = pad
        current += piece + " "
    lines.append(current.rstrip())
    return "\n".join(lines)


@dataclass
class Entry:
    """One action: its heading, the code that repeats it, and what the code leaves out."""

    title: str
    code: str
    notes: tuple[str, ...] = ()
    imports: tuple[str, ...] = ()  # whole lines this entry needs first (library(...))
    when: str = ""

    def text(self) -> str:
        """The entry as the panel shows it: heading, notes, code."""
        head = f"# {self.when}  {self.title}" if self.when else f"# {self.title}"
        return "\n".join([head, *(f"#   {n}" for n in self.notes), self.code])


@dataclass
class CommandLog:
    """The session's actions in order, as a panel listing and as a runnable script."""

    entries: list[Entry] = field(default_factory=list)

    def __len__(self) -> int:
        return len(self.entries)

    def add(self, entry: Entry | None) -> Entry | None:
        """Record *entry* (None is ignored, so a caller may hand over what it has)."""
        if entry is None:
            return None
        if not entry.when:
            entry.when = datetime.datetime.now().strftime("%H:%M:%S")
        self.entries.append(entry)
        return entry

    def clear(self) -> None:
        self.entries.clear()

    def text(self) -> str:
        """What the panel shows."""
        if not self.entries:
            return (
                "# Nothing yet. Open a table and run a step: every action appears here as\n"
                "# the normet call that repeats it, and Save as Script… writes them out."
            )
        return "\n\n".join(e.text() for e in self.entries)

    def script(self, *, title: str = "") -> str:
        """The log as a file that runs (``Rscript session.R``): a header, the libraries
        it needs, the entries."""
        imports: list[str] = [LIBRARY]
        for e in self.entries:
            imports += [i for i in e.imports if i not in imports]
        try:
            from .nm import __version__ as version
        except Exception:  # pragma: no cover
            version = "?"
        when = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
        head = [
            "# " + (title or "A normet session") + ".",
            "#",
            f"# Written by normet {version} (R) on {when}, from the window's command log.",
            "# Every command is the call behind one action, in the order they were taken;",
            "# running this file (Rscript, or source() in R) repeats the analysis.",
        ]
        body = "\n\n".join(e.text() for e in self.entries)
        return "\n".join([*head, "", *imports, "", body]) + "\n"


# -- the window's actions, as entries -------------------------------------------------------
def open_table(path: str, zone: str | None = None) -> Entry:
    """A table file read as the window reads one (``nm_read_time_series``): its times
    found, parsed and named 'date', and put on UTC from ``zone``."""
    kw = [("zone", literal(zone))] if zone and zone.upper() != "UTC" else []
    return Entry("Open data", call("df", "nm_read_time_series", [literal(path)], kw))


def load_example(example: Any = None) -> Entry:
    """An example as the window loads one (``._examples.EXAMPLES``); the synthetic site
    where none is named. The synthetic site is made by the window (in Python): the
    script reads it from a CSV the user saves."""
    if example is None:
        from ._examples import EXAMPLES

        example = EXAMPLES["synthetic"]
    if example.key == "synthetic":
        return Entry(
            "Load example data",
            'df <- nm_read_time_series("<the example table, saved as CSV>")  # replace with its path',
            notes=(
                "The synthetic site is made by the window, not by an R function.",
                "Save it as CSV (Data tab → Export result CSV) and read it here.",
            ),
        )
    return Entry(f"Load example: {example.title}", example.code, imports=example.imports)


def from_memory(label: str) -> Entry:
    """A table the window was handed in memory (the Data Studio's), which no call reads."""
    return Entry(
        f"Table from {label}",
        'df <- nm_read_time_series("<the table, saved as CSV>")  # replace with its path',
        notes=(
            "This table was handed to the window in memory, not read from a file.",
            "Save it as CSV where it was made (Data Studio → Save CSV) and read it here.",
        ),
    )


#: The window's tasks, by their function's name: (title, what the R result is assigned
#: to, the lines that follow it). The R call itself is the one the function makes.
_KNOWN: dict[str, tuple[str, str, tuple[str, ...]]] = {
    "build_model": ("Train model", "res", ("df_prep <- res$df_prep", "model <- res$model")),
    "normalise": ("Normalise", "normalised", ()),
    "decompose": ("Decompose", "decomposition", ()),
    "rolling": ("Rolling normalisation", "rolled", ()),
    "pdp": ("Partial dependence", "pd_values", ()),
}


def _r_calls(fn: Callable[..., Any], args: Sequence[Any], kwargs: dict[str, Any], *, all_calls: bool) -> list:
    """The R calls ``fn(*args, **kwargs)`` makes, recorded and not made: the first only
    (the task stops there), or with *all_calls* every one, each answered with an empty
    table (a helper that calls R several times runs through)."""
    from . import _rpc

    answer = (lambda: pd.DataFrame()) if all_calls else None
    with _rpc.capture(answer) as calls:
        try:
            fn(*args, **kwargs)
        except _rpc.Captured:
            pass
        except Exception:  # noqa: BLE001 - what the empty answers make of it is no matter
            if not all_calls:
                return []
    return calls


def _render(names: Sequence[tuple[Any, str]], notes: list[str]) -> Callable[[Any], str]:
    def render(value: Any) -> str:
        for obj, name in names:
            if value is obj:
                # normet-py's ``normalised['normalised']`` is R's ``normalised$normalised``.
                return re.sub(r"\['([^']+)'\]", r"$\1", name)
        if isinstance(value, (pd.DataFrame, pd.Series)) or (
            hasattr(value, "__dict__") and not isinstance(value, type)
        ):
            notes.append(f"An object the window held ({type(value).__name__}) is not named here.")
            return "NULL  # " + type(value).__name__
        return literal(value)

    return render


def _code(r_call: tuple[str, tuple[Any, ...], dict[str, Any]], target: str, render: Callable[[Any], str]) -> str:
    fn, args, kwargs = r_call
    keywords = [(k, render(v)) for k, v in kwargs.items() if k != "verbose"]
    return call(target, fn, [render(a) for a in args], keywords)


def task(
    fn: Callable[..., Any],
    args: Sequence[Any],
    kwargs: dict[str, Any],
    names: Sequence[tuple[Any, str]],
) -> Entry | None:
    """The entry for a task the window ran: the R call ``fn(*args, **kwargs)`` makes.

    *names* pairs each object the window holds (its tables, its model, a series of a
    result) with the name the script gives it; an argument found there is written as
    that name, by identity. A function the log does not know (nothing but the calls
    above decide a result) gives None.
    """
    name = getattr(fn, "__name__", "")
    notes: list[str] = []
    render = _render(names, notes)
    if name == "compute_multiscale":
        calls = [c for c in _r_calls(fn, args, kwargs, all_calls=True) if c[0] == "nm_rolling"]
        if not calls:
            return None
        lines = [_code(c, f"rolled_{c[2].get('window_days', i)}", render) for i, c in enumerate(calls)]
        notes.insert(
            0,
            "The bands are differences of these rolling means (the window's own helper).",
        )
        return Entry("Multi-scale decomposition", "\n".join(lines), notes=tuple(dict.fromkeys(notes)))
    known = _KNOWN.get(name)
    if known is None:
        return None
    title, target, after = known
    calls = _r_calls(fn, args, kwargs, all_calls=False)
    if not calls or calls[0][0].startswith(".gui_"):
        return None
    code = "\n".join([_code(calls[0], target, render), *after])
    return Entry(title, code, notes=tuple(dict.fromkeys(notes)))
