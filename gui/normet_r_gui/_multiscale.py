"""Multi-scale meteorological-influence decomposition via differencing
between rolling-deweathered series at different window widths.

Port of normet-py's ``normet.gui._multiscale`` — the science is identical
(see that module for the full rationale); the rolling runs go through the
R bridge instead of calling :func:`normet.rolling` directly.
"""

from __future__ import annotations

import logging

import pandas as pd

log = logging.getLogger(__name__)

__all__ = ["rolling_mean_series", "compute_multiscale"]

#: A scale needs at least this many overlapping windows to be "rolling" at
#: all — with exactly one window, Y_W degenerates to Y_inf.
MIN_WINDOWS = 2

DEFAULT_SEED = 7_654_321


def rolling_mean_series(
    *,
    bridge,
    df_prep: pd.DataFrame,
    covariates: list[str],
    resample_vars: list[str] | None,
    backend: str,
    window_days: int,
    n_samples: int,
    seed: int = DEFAULT_SEED,
) -> tuple[pd.Series | None, int, str | None]:
    """``Y_W(t)``: the row-wise mean of nm_rolling's overlapping windows."""
    span_days = (df_prep["date"].max() - df_prep["date"].min()).total_seconds() / 86400.0 + 1
    if span_days < window_days:
        return (
            None,
            0,
            f"the record spans {span_days:.0f} d, shorter than the {window_days} d window",
        )

    step = max(1, window_days // 4)
    res = bridge.rolling(
        covariates=covariates,
        resample_vars=resample_vars,
        backend=backend,
        window_days=window_days,
        rolling_every=step,
        n_samples=n_samples,
        seed=seed,
    )
    if "date" in res.columns:
        res = res.set_index("date")
    cols = [c for c in res.columns if c.startswith(("rolling_", "window_"))]
    if len(cols) < MIN_WINDOWS:
        return (
            None,
            len(cols),
            f"only {len(cols)} window(s) fit in the record — need at least "
            f"{MIN_WINDOWS} for a meaningful {window_days} d scale",
        )
    return res[cols].mean(axis=1, skipna=True), len(cols), None


def compute_multiscale(
    *,
    bridge,
    df_prep: pd.DataFrame,
    covariates: list[str],
    resample_vars: list[str] | None,
    backend: str,
    y_inf: pd.Series,
    fast_days: int = 14,
    meso_days: int = 90,
    slow_days: int = 365,
    n_samples: int = 100,
    seed: int = DEFAULT_SEED,
) -> dict:
    """Compute the fast/meso/slow scale-space family and their differences."""
    scales = {}
    notes: list[str] = []
    for key, days in (("fast", fast_days), ("meso", meso_days), ("slow", slow_days)):
        series, n_windows, reason = rolling_mean_series(
            bridge=bridge,
            df_prep=df_prep,
            covariates=covariates,
            resample_vars=resample_vars,
            backend=backend,
            window_days=days,
            n_samples=n_samples,
            seed=seed + hash(key) % 1000,
        )
        scales[key] = series
        if reason:
            notes.append(f"{days} d scale skipped: {reason}")
        log.info(
            "Multi-scale: Y_%s (%d d) -> %s",
            key,
            days,
            f"{n_windows} windows" if series is not None else f"skipped ({reason})",
        )

    out: dict = {
        "fast_days": fast_days,
        "meso_days": meso_days,
        "slow_days": slow_days,
        "Y_fast": scales["fast"],
        "Y_meso": scales["meso"],
        "Y_slow": scales["slow"],
        "Y_inf": y_inf,
        "notes": notes,
    }

    def _diff(a: pd.Series | None, b: pd.Series | None) -> pd.Series | None:
        if a is None or b is None:
            return None
        idx = a.index.intersection(b.index)
        d = (a.reindex(idx) - b.reindex(idx)).dropna()
        return d if len(d) else None

    out["D_fast"] = _diff(scales["fast"], scales["meso"])
    out["D_meso"] = _diff(scales["meso"], scales["slow"])
    out["D_slow"] = _diff(scales["slow"], y_inf)
    return out
