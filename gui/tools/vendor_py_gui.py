"""Bring normet-py's window into this one: ``python gui/tools/vendor_py_gui.py <normet-py>``.

The R GUI is normet-py's GUI, run on the R package. This script copies it across:

- every module of ``normet/gui`` into ``normet_r_gui/``;
- the pure-Python library modules the window draws and reads with (figure style,
  plotting, table reading, trajectory joins, SCM diagnostics, the agent's readings and
  language-model client) into ``normet_r_gui/nm/``, the window's ``normet``;

- normet-py's GUI tests (``tests/test_gui_*.py``) into ``gui/tests/``, pointed at
  this window;
- normet-py's user manual (``docs/manual``: the two books' LaTeX and their build
  script) into ``gui/docs/manual/``, rewritten for this window by the patches in
  ``manual_patches.py`` -- its screenshots are this window's own (``walk_gui.py``);

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
TESTS = HERE.parent / "tests"
MANUAL = HERE.parent / "docs" / "manual"

#: normet-py's manual: the two books and the script that builds them.
MANUAL_FILES = ("normet_manual.tex", "normet_manual_zh.tex", "build.sh")

#: normet-py's GUI modules this window does not take: its own entry points stay, and
#: the modules that write or read the session's code, which here is R (``commandlog``
#: writes it, ``_script`` reads a saved script back, ``_code`` runs the Assistant's
#: carry_out), are this window's own. Nor is ``_chronos``: Chronos-2, a PyTorch model,
#: has no R side (r_patches.py takes out what reads it).
SKIP_GUI = {"__init__.py", "__main__.py", "commandlog.py", "_script.py", "_code.py", "_chronos.py"}

#: normet-py's GUI files that are not code, copied byte for byte: the app's icon, which
#: the window shows (About, every window's icon) from the package itself.
GUI_ASSETS = ("assets/normet.png",)

#: normet-py's GUI tests this window does not take: Chronos-2 is not in it.
SKIP_TESTS = {"test_gui_chronos.py"}

#: normet-py's tests of its manual, which hold for this window's book as they are, and
#: of the progress reports and the task clock that shows them.
TEST_MANUAL = ("test_manual.py", "test_progress.py")

#: Test helpers copied beside the tests, under a name of their own where this window's
#: tests already have one of that name.
TEST_HELPERS = {"_uilang_smoke.py": "_py_uilang_smoke.py"}

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
    "utils/progress.py",
    "causal/diagnostics.py",
    "causal/prediagnostics.py",
    "causal/bands.py",
    "causal/spatial.py",
    "agent/llm.py",
    "agent/mcp_http.py",
    "agent/readings.py",
]


def _imports_to_nm(text: str, depth: int) -> str:
    """``normet`` imports pointed at the window's ``nm`` package. *depth* is how far the
    module sits below ``normet_r_gui`` (0 for the window's own modules)."""
    up = "." * (depth + 1)
    nm = f"{up}nm" if depth == 0 else "." * depth
    # A dotted ``nm`` (a library module) already ends in the separator its path needs.
    sep = "" if nm.endswith(".") else "."
    text = re.sub(r"^(\s*)from normet\.gui\.(\w+) import", rf"\1from {up}\2 import", text, flags=re.M)
    text = re.sub(r"^(\s*)from normet\.gui import", rf"\1from {up} import", text, flags=re.M)
    text = re.sub(r"^(\s*)from normet\.([\w.]+) import", rf"\1from {nm}{sep}\2 import", text, flags=re.M)
    text = re.sub(r"^(\s*)from normet import", rf"\1from {nm} import", text, flags=re.M)
    if depth == 0:
        text = re.sub(r"^(\s*)import normet as (\w+)$", r"\1from . import nm as \2", text, flags=re.M)
        text = re.sub(r"^(\s*)import normet$", r"\1from . import nm as normet", text, flags=re.M)
        # The window's modules reach the library one level up in normet-py.
        text = re.sub(r"^(\s*)from \.\.(\w[\w.]*) import", r"\1from .nm.\2 import", text, flags=re.M)
        text = re.sub(r"^(\s*)from \.\. import", r"\1from .nm import", text, flags=re.M)
    return text


def _test_imports(text: str) -> str:
    """A test's ``normet`` pointed at this window: its GUI at ``normet_r_gui``, the
    library at ``normet_r_gui.nm`` -- in imports, and in names given as text (what a
    test patches)."""
    text = text.replace("normet.gui.", "normet_r_gui.").replace("normet.gui import", "normet_r_gui import")
    text = re.sub(r"^(\s*)import normet as (\w+)$", r"\1from normet_r_gui import nm as \2", text, flags=re.M)
    text = re.sub(r"^(\s*)import normet$", r"\1from normet_r_gui import nm as normet", text, flags=re.M)
    text = re.sub(r"^(\s*)from normet\.([\w.]+) import", r"\1from normet_r_gui.nm.\2 import", text, flags=re.M)
    text = re.sub(r"^(\s*)from normet import", r"\1from normet_r_gui.nm import", text, flags=re.M)
    for name, ours in TEST_HELPERS.items():
        text = text.replace(name, ours)
    return re.sub(r"([\"'])normet\.(?!gui)", r"\1normet_r_gui.nm.", text)


def _patches() -> dict[str, list[tuple[str, str, str]]]:
    """The window's patches (``r_patches.py``) and the manual's (``manual_patches.py``)."""
    out: dict[str, list[tuple[str, str, str]]] = {}
    for name in ("r_patches", "manual_patches"):
        spec = importlib.util.spec_from_file_location(name, HERE / f"{name}.py")
        mod = importlib.util.module_from_spec(spec)
        assert spec.loader is not None
        spec.loader.exec_module(mod)
        for file, edits in mod.PATCHES.items():
            out.setdefault(file, []).extend(edits)
    return out


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
    for f in [*sorted((py_root / "tests").glob("test_gui_*.py")), *(py_root / "tests" / n for n in TEST_MANUAL)]:
        if f.name not in SKIP_TESTS:
            out[TESTS / f.name] = _test_imports(f.read_text(encoding="utf-8"))
    for name, ours in TEST_HELPERS.items():
        out[TESTS / ours] = _test_imports((py_root / "tests" / name).read_text(encoding="utf-8"))
    for name in MANUAL_FILES:
        out[MANUAL / name] = (py_root / "docs" / "manual" / name).read_text(encoding="utf-8")
    failed = []
    for name, edits in _patches().items():
        # A patch to a test or the manual is named by its place under gui/:
        # tests/test_gui_x.py, docs/manual/normet_manual.tex.
        path = HERE.parent / name if name.startswith(("tests/", "docs/")) else GUI / name
        if path not in out:
            failed.append(f"{name}: not among the files copied")
            continue
        text = out[path]
        for label, old, new in edits:
            if isinstance(old, tuple):
                # A passage: from its first words up to (not including) the next's.
                start, end = old
                if text.count(start) != 1 or text.count(end) != 1 or text.find(end) < text.find(start):
                    failed.append(f"{name}: passage {label!r} not found once, in order")
                    continue
                i, j = text.find(start), text.find(end)
                text = text[:i] + new + text[j:]
                continue
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
            if path.suffix == ".sh":
                path.chmod(0o755)
    for rel in GUI_ASSETS:
        data, path = (a.normet_py.resolve() / "src" / "normet" / "gui" / rel).read_bytes(), GUI / rel
        if path.exists() and path.read_bytes() == data:
            continue
        changed += 1
        if a.check:
            print(f"{path}: differs (binary)")
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
    total = len(files) + len(GUI_ASSETS)
    print(f"{changed} of {total} file(s) {'would change' if a.check else 'written'}.")
    return 1 if a.check and changed else 0


if __name__ == "__main__":
    sys.exit(main())
