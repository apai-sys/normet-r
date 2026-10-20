"""normet's bundled examples, read from the R package (``normet::my1`` and the rest):
the same tables normet-py ships."""

from __future__ import annotations

import functools

import pandas as pd

from .. import _rpc


@functools.cache
def _load(name: str) -> pd.DataFrame:
    return _rpc.call(".gui_dataset", name)


def load_my1() -> pd.DataFrame:
    """Hourly NO2 and meteorology at London Marylebone Road (MY1), Jan-Aug 2020."""
    return _load("my1").copy()


def load_my1_pm25() -> pd.DataFrame:
    """Hourly PM2.5 and ERA5 meteorology at MY1, Jan-Aug 2020."""
    return _load("my1_pm25").copy()


def load_scm() -> pd.DataFrame:
    """Monthly NO2 at 104 UK sites, 2016-2021: the synthetic-control panel."""
    return _load("scm").copy()


def load_traj_my1() -> pd.DataFrame:
    """HYSPLIT trajectory features at MY1, 6-hourly, Jan-Aug 2020."""
    return _load("traj_my1").copy()
