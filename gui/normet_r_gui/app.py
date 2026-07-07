"""Application entry point for the normet-r GUI."""

from __future__ import annotations

import sys


def _install_excepthook() -> None:
    """Show a dialog instead of letting an unhandled slot exception abort the app."""
    import traceback

    from PySide6.QtWidgets import QMessageBox

    def hook(exc_type, exc, tb):
        msg = "".join(traceback.format_exception(exc_type, exc, tb))
        sys.stderr.write(msg)
        try:
            QMessageBox.critical(
                None,
                "Unexpected error",
                f"{exc_type.__name__}: {exc}\n\nThe app stayed open; your results "
                "are unaffected. Details were logged to the console.",
            )
        except Exception:
            pass

    sys.excepthook = hook


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv if argv is None else argv)
    from PySide6.QtWidgets import QApplication

    import matplotlib

    matplotlib.use("QtAgg")
    import matplotlib.pyplot as plt

    plt.rcParams.update({"savefig.bbox": "tight"})

    app = QApplication(argv)
    # Cross-platform Fusion style so the layout is tidy and identical on every
    # OS (native macOS style sizes/aligns controls differently).
    app.setStyle("Fusion")
    app.setApplicationName("Normet")
    app.setApplicationDisplayName("Normet")
    app.setOrganizationName("apai-sys")
    _install_excepthook()

    from .main_window import MainWindow

    window = MainWindow()
    window.show()

    # `normet-r-gui data.csv` opens the file straight away.
    for arg in argv[1:]:
        if arg.lower().endswith((".csv", ".csv.gz")):
            window.load_csv(arg, remember=True)
            break

    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main())
