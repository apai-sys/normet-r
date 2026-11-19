"""Transport Studio's join onto the window's data: normet-py's join_trajectory_features,
vendored (normet_r_gui.nm.io.trajectory)."""

from __future__ import annotations

import numpy as np
import pandas as pd

from normet_r_gui.nm.io.trajectory import join_trajectory_features


def _hourly(start, hours, **cols):
    return pd.DataFrame({"date": pd.date_range(start, periods=hours, freq="h"), **cols})


def test_each_row_takes_the_latest_trajectory_to_have_arrived():
    panel = _hourly("2020-01-01 22:00", 26)
    feats = pd.DataFrame(
        {
            "date": pd.to_datetime(["2020-01-02 00:00", "2020-01-02 06:00", "2020-01-02 18:00"]),
            "traj_x": [0.0, 6.0, 18.0],
        }
    )
    out = join_trajectory_features(panel, feats)
    got = dict(zip(out["date"].dt.strftime("%d %H"), out["traj_x"]))
    assert np.isnan(got["01 23"])  # before the first trajectory
    assert got["02 04"] == 0.0  # not 06:00's, which has not arrived yet
    assert np.isnan(got["02 12"])  # 12:00's trajectory is missing
    assert got["02 23"] == 18.0
    assert out["traj_x"].notna().sum() == 18 and len(out) == len(panel)


def test_sites_are_matched_and_a_column_sent_again_is_replaced():
    panel = pd.concat(
        [_hourly("2020-01-01", 3, site="MY1"), _hourly("2020-01-01", 3, site="KC1")],
        ignore_index=True,
    )
    t = pd.date_range("2020-01-01", periods=3, freq="h")
    out = join_trajectory_features(panel, pd.DataFrame({"date": t, "site": "MY1", "traj_x": [1.0, 2, 3]}))
    out = join_trajectory_features(out, pd.DataFrame({"date": t, "site": "KC1", "traj_x": [7.0, 8, 9]}))
    assert list(out.columns) == ["date", "site", "traj_x"]
    assert out["traj_x"].tolist() == [1.0, 2.0, 3.0, 7.0, 8.0, 9.0]


def test_zoned_dates_are_compared_as_utc():
    feats = pd.DataFrame({"date": pd.to_datetime(["2020-07-01 06:00"]), "traj_x": [6.0]})
    panel = pd.DataFrame({"date": ["2020-07-01T07:00+01:00", "2020-07-01T05:00+00:00"]})
    out = join_trajectory_features(panel, feats)
    assert out["traj_x"].iloc[0] == 6.0 and np.isnan(out["traj_x"].iloc[1])
