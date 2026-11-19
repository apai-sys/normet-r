"""The app as packaged (packaging/normet_r_gui.spec): what it reaches only by name at
run time is named for PyInstaller, which cannot see it."""

from __future__ import annotations

from pathlib import Path

import pytest

SPEC = Path(__file__).resolve().parents[1] / "packaging" / "normet_r_gui.spec"

#: The backend matplotlib saves each of Figure for Print's file types with.
_SAVED_BY = {
    "pdf": "backend_pdf",
    "eps": "backend_ps",
    "svg": "backend_svg",
    "png": "backend_agg",
    "tiff": "backend_agg",
}


def test_every_file_type_figure_for_print_saves_is_packaged():
    pytest.importorskip("PySide6")
    from normet_r_gui.printview import KINDS

    spec = SPEC.read_text(encoding="utf-8")
    assert set(KINDS) <= set(_SAVED_BY), "a file type this test does not know"
    for kind in KINDS:
        assert f'"matplotlib.backends.{_SAVED_BY[kind]}"' in spec, kind
