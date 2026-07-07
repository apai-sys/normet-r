"""Qt (PySide6) graphical interface for the normet R package.

The GUI itself is Python; every computation runs in R via ``Rscript``
subprocesses (see :mod:`normet_r_gui.rbridge`).  Launch with
``normet-r-gui`` or ``python -m normet_r_gui``.
"""

from __future__ import annotations

__all__ = ["main"]


def main() -> int:
    """Start the normet-r GUI application."""
    from .app import main as _main

    return _main()
