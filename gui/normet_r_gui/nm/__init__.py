"""The window's ``normet``: normet-py's interface, run on the normet R package.

The window's modules are normet-py's GUI, and they import ``normet`` as that GUI does.
This package answers those imports:

- what the window draws and reads with is normet-py's own Python, copied as it is
  (``tools/vendor_py_gui.py``): the figure style (``style``, ``figstyle``), the
  plotting functions, table reading (``io.tables``), trajectory joins, the SCM
  diagnostics and bands' arithmetic, the agent's readings;
- every analysis is the R package's: :mod:`._r` calls ``nm_build_model``,
  ``nm_normalise``, ``nm_decompose``, ``nm_rolling``, ``nm_pdp``, the SCM estimators,
  the fetchers and the trajectory functions through ``Rscript`` (:mod:`normet_r_gui._rpc`)
  and hands back what normet-py's functions hand back -- the same tables, indexed and
  named the same way -- so the window cannot tell the two apart.

A model is an :class:`._r.RModel`: the R model saved in the session's folder, with its
backend and features.
"""

from __future__ import annotations

import re
from typing import Any

from . import figstyle, style  # noqa: F401 - the window imports them from here
from ._r import (  # noqa: F401
    RModel,
    build_model,
    build_trajectory_features,
    decompose,
    fetch_era5_timeseries,
    fetch_gdas1,
    fetch_openmeteo_timeseries,
    fetch_ukaq_measurements,
    gdas1_filenames,
    generate_html_report,
    list_ukaq_stations,
    load_source_regions,
    make_run,
    ml_predict,
    modStats,
    normalise,
    pdp,
    prepare_data,
    rolling,
    run_back_trajectories,
)
from .plotting import (  # noqa: F401
    cycle_profiles,
    decomposition_stack,
    normalise_plot,
    pdp_grid,
    plot_bayesian_scm,
    polar_plot,
    pollution_rose,
    scm_dashboard,
    time_series_plot,
    wind_rose,
)

#: A rolling result's window columns: window_01, window_02, ... (R's names, normet-py's).
_WINDOW_COLUMN = re.compile(r"window_\d+")


def window_column(i: int, total: int) -> str:
    """The column of window *i* (counted from 1) of *total*, as nm_rolling names it:
    ``window_01``, ..., padded to the width of *total* (two digits at least)."""
    return f"window_{i:0{max(2, len(str(total)))}d}"


def window_columns(df: Any) -> list[str]:
    """The window columns of a rolling result, in the windows' order."""
    return [c for c in df.columns if isinstance(c, str) and _WINDOW_COLUMN.fullmatch(c)]


def __getattr__(name: str) -> Any:
    # The version is the R package's, asked of R the first time it is wanted.
    if name == "__version__":
        from ._r import r_version

        return r_version()
    if name == "datasets":
        # Not ``from . import datasets``: its fromlist asks this function again.
        import importlib

        return importlib.import_module(f"{__name__}.datasets")
    raise AttributeError(name)
