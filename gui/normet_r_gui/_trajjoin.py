"""Join trajectory features onto the window's data, as nm_join_trajectory_features() does.

A row at time t takes the trajectory that arrived last at or before t, and only if it
arrived less than one release interval before (the commonest step between one site's
successive trajectories). A nearest-time join would hand 04:00 and 05:00 the 06:00
trajectory -- air that has not arrived yet -- and, with no tolerance, fill every row
before the first trajectory and after the last.
"""

from __future__ import annotations

import logging

import numpy as np
import pandas as pd

log = logging.getLogger("normet_r_gui")


def _utc(values: pd.Series) -> pd.Series:
    """Times compared as UTC, HYSPLIT's clock; naive times are taken as UTC already."""
    s = pd.to_datetime(values, errors="coerce", utc=True, format="mixed")
    return s.dt.tz_localize(None).reset_index(drop=True)


def _release_interval(times: pd.Series, sites: pd.Series) -> pd.Timedelta | None:
    steps = (
        pd.DataFrame({"t": times.to_numpy(), "s": sites.to_numpy()})
        .sort_values(["s", "t"])
        .groupby("s")["t"]
        .diff()
        .dropna()
    )
    steps = steps[steps > pd.Timedelta(0)]
    return pd.Timedelta(steps.mode().min()) if len(steps) else None


def join_trajectory_features(
    df: pd.DataFrame, features: pd.DataFrame, *, date_col: str = "date", site_col: str = "site"
) -> tuple[pd.DataFrame, int]:
    """``df`` with the feature columns joined (replacing any it had), and how many of
    its rows took a trajectory. With a ``site`` column in both, each row takes only its
    own site's trajectories, and other sites' rows are left as they were."""
    if features.index.name == date_col and date_col not in features.columns:
        features = features.reset_index()
    cols = [c for c in features.columns if c not in (date_col, site_col)]
    when = _utc(df[date_col])
    ftimes = _utc(features[date_col])
    has_fsite = site_col in features.columns
    fsite = (
        features[site_col].astype(str).reset_index(drop=True)
        if has_fsite
        else pd.Series("", index=ftimes.index)
    )
    by_site = has_fsite and site_col in df.columns
    if has_fsite and not by_site and fsite.nunique() > 1:
        raise ValueError(
            f"The features hold {fsite.nunique()} sites but the data has no '{site_col}' column."
        )
    known = ftimes.notna()
    tol = _release_interval(ftimes[known], fsite[known])
    asof_tol = tol - pd.Timedelta(1, "ns") if tol is not None else pd.Timedelta(0)

    left = pd.DataFrame({"_t": when.to_numpy(), "_row": np.arange(len(df))})
    right = pd.DataFrame({"_t": ftimes.to_numpy(), "_pos": np.arange(len(features))})
    if by_site:
        left["_site"] = df[site_col].astype(str).to_numpy()
        right["_site"] = fsite.to_numpy()
    matched = pd.merge_asof(
        left[left["_t"].notna()].sort_values("_t", kind="stable"),
        right[right["_t"].notna()].sort_values("_t", kind="stable"),
        on="_t",
        by="_site" if by_site else None,
        direction="backward",
        tolerance=asof_tol,
    )
    pos = np.full(len(df), -1, dtype=np.int64)
    hit = matched["_pos"].notna().to_numpy()
    pos[matched["_row"].to_numpy()[hit]] = matched["_pos"].to_numpy()[hit].astype(np.int64)

    in_scope = (
        df[site_col].astype(str).isin(set(fsite)).to_numpy()
        if by_site
        else np.ones(len(df), dtype=bool)
    )
    block = features[cols].reset_index(drop=True).reindex(pos)  # -1 -> a row of NaN
    out = df.copy()
    for c in cols:
        values = block[c].to_numpy()
        if not in_scope.all():
            prior = out[c].to_numpy() if c in df.columns else np.full(len(out), np.nan)
            values = np.where(in_scope, values, prior)
        out[c] = values
    if by_site:
        absent = sorted(set(fsite) - set(left["_site"]))
        if absent:
            log.warning(
                "No rows of site(s) %s in the data's '%s' column (it has %s); their "
                "trajectories were not used.",
                ", ".join(absent),
                site_col,
                ", ".join(sorted(set(left["_site"]))),
            )
    return out, int((pos >= 0).sum())
