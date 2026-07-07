"""PyInstaller entry point for the normet-r GUI."""

import multiprocessing

multiprocessing.freeze_support()

from normet_r_gui import main  # noqa: E402

raise SystemExit(main())
