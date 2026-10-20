"""Bring normet-py's window into this one: ``python gui/tools/vendor_py_gui.py <normet-py>``.

The R GUI is normet-py's GUI, run on the R package. This script copies it across:

- every module of ``normet/gui`` into ``normet_r_gui/``;
- the pure-Python library modules the window draws and reads with (figure style,
  plotting, table reading, trajectory joins, SCM diagnostics, the agent's readings and
  language-model client) into ``normet_r_gui/nm/``, the window's ``normet``;

with ``normet`` imports pointed at ``normet_r_gui.nm`` and the patches in
``r_patches.py`` applied -- what this window does differently because it runs R
(its backends, its R menu, a command log written in R). A patch whose text a newer
normet-py no longer has stops the script with its name, to be written again; nothing is
copied until every patch applies. The analyses themselves (``nm/__init__.py`` and
``nm/_r.py``: training, normalising, decomposing, SCM, trajectories, fetching) are this
window's own, calling R; they are not copied.

    python gui/tools/vendor_py_gui.py ../normet-py            # copy
    python gui/tools/vendor_py_gui.py ../normet-py --check    # say what would change
"""

from __future__ import annotations

import argparse
import difflib
import importlib.util
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
GUI = HERE.parent / "normet_r_gui"
NM = GUI / "nm"

#: normet-py's GUI modules this window does not take: its own entry points stay.
#: (``_chronos.py`` comes across for the names the window reads from it; Chronos-2, a
#: PyTorch model, is not offered -- see r_patches.py.)
SKIP_GUI = {"__init__.py", "__main__.py"}

#: Library modules copied as they are, by their path under normet/ (pure Python).
LIBRARY = [
    "style.py",
    "figstyle.py",
    "plotting.py",
    "io/tables.py",
    "io/trajectory.py",
    "io/gdas.py",
    "utils/_time.py",
    "utils/logging.py",
    "utils/_config.py",
    "utils/_lazy.py",
    "causal/diagnostics.py",
    "causal/bands.py",
    "agent/llm.py",
    "agent/mcp_http.py",
    "agent/readings.py",
]


def _imports_to_nm(text: str, depth: int) -> str:
    """``normet`` imports pointed at the window's ``nm`` package. *depth* is how far the
    module sits below ``normet_r_gui`` (0 for the window's own modules)."""
    up = "." * (depth + 1)
    nm = f"{up}nm" if depth == 0 else "." * depth
    text = re.sub(r"^(\s*)from normet\.gui\.(\w+) import", rf"\1from {up}\2 import", text, flags=re.M)
    text = re.sub(r"^(\s*)from normet\.gui import", rf"\1from {up} import", text, flags=re.M)
    text = re.sub(r"^(\s*)from normet\.([\w.]+) import", rf"\1from {nm}.\2 import", text, flags=re.M)
    text = re.sub(r"^(\s*)from normet import", rf"\1from {nm} import", text, flags=re.M)
    if depth == 0:
        text = re.sub(r"^(\s*)import normet as (\w+)$", r"\1from . import nm as \2", text, flags=re.M)
        text = re.sub(r"^(\s*)import normet$", r"\1from . import nm as normet", text, flags=re.M)
        # The window's modules reach the library one level up in normet-py.
        text = re.sub(r"^(\s*)from \.\.(\w[\w.]*) import", r"\1from .nm.\2 import", text, flags=re.M)
        text = re.sub(r"^(\s*)from \.\. import", r"\1from .nm import", text, flags=re.M)
    return text


def _patches() -> dict[str, list[tuple[str, str, str]]]:
    spec = importlib.util.spec_from_file_location("r_patches", HERE / "r_patches.py")
    mod = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(mod)
    return mod.PATCHES


def build(py_root: Path) -> dict[Path, str]:
    """Every file this script writes, by path, with its text."""
    src = py_root / "src" / "normet"
    if not (src / "gui" / "main_window.py").is_file():
        raise SystemExit(f"{py_root} is not a normet-py checkout (no src/normet/gui)")
    out: dict[Path, str] = {}
    for f in sorted((src / "gui").glob("*.py")):
        if f.name in SKIP_GUI:
            continue
        text = _imports_to_nm(f.read_text(encoding="utf-8"), 0)
        # This window keeps its settings apart from normet-py's (both can be installed).
        text = text.replace('QSettings("apai-sys", "normet-gui")', 'QSettings("apai-sys", "normet-r-gui")')
        out[GUI / f.name] = text
    for rel in LIBRARY:
        f = src / rel
        depth = rel.count("/") + 1  # nm/x.py is one level below normet_r_gui, nm/io/x.py two
        out[NM / rel] = _imports_to_nm(f.read_text(encoding="utf-8"), depth)
    failed = []
    for name, edits in _patches().items():
        path = GUI / name
        if path not in out:
            failed.append(f"{name}: not among the files copied")
            continue
        text = out[path]
        for label, old, new in edits:
            if text.count(old) != 1:
                failed.append(f"{name}: patch {label!r} matches {text.count(old)} times")
                continue
            text = text.replace(old, new)
        out[path] = text
    if failed:
        raise SystemExit("Patches that no longer apply:\n  " + "\n  ".join(failed))
    return out


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("normet_py", type=Path, help="a normet-py checkout")
    p.add_argument("--check", action="store_true", help="say what would change; write nothing")
    a = p.parse_args(argv)
    files = build(a.normet_py.resolve())
    changed = 0
    for path, text in files.items():
        old = path.read_text(encoding="utf-8") if path.exists() else ""
        if old == text:
            continue
        changed += 1
        if a.check:
            diff = difflib.unified_diff(
                old.splitlines(), text.splitlines(), str(path), str(path), lineterm="", n=1
            )
            print("\n".join(list(diff)[:40]))
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")
    print(f"{changed} of {len(files)} file(s) {'would change' if a.check else 'written'}.")
    return 1 if a.check and changed else 0


if __name__ == "__main__":
    sys.exit(main())
