# gui/normet_r_gui/nm/analysis/trend.py
"""The trend results the window reads: normet-py's dataclasses, copied as they are.

The window is normet-py's GUI and reads the trend step's results as these
classes. The arithmetic that fills them is the normet R package's
(``nm_trend`` and ``nm_trend_breaks``, reached through :mod:`nm._r`); this
module holds the shapes alone, field for field and method for method, so the
window cannot tell the two apart.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

import pandas as pd

__all__ = [
    "TrendTest",
    "TrendSlope",
    "TrendResult",
    "TrendBreaks",
]


@dataclass(frozen=True)
class TrendTest:
    """Result of a Mann-Kendall trend test.

    Attributes
    ----------
    S : int
        The Mann-Kendall S statistic (sum of sign terms over all pairs).
    var_S : float
        Variance of S under H0, with tie correction.
    z : float
        Normalised statistic with continuity correction.
    p : float
        Two-sided p-value.
    n : int
        Number of values used (missing values dropped before testing).
    seasonal : bool, default False
        Whether the seasonal (Sen 1968) variant was used.
    n_periods : int or None
        Number of calendar periods (groups) the seasonal test was run on,
        when ``seasonal`` -- for hourly data with ``seasonal_period=24``
        that is 24 (one group per hour-of-day), not the number of days.
    """

    S: int
    var_S: float
    z: float
    p: float
    n: int
    seasonal: bool = False
    n_periods: int | None = None

    @property
    def direction(self) -> str:
        """``"increasing"`` / ``"decreasing"`` at the 5 % level, else ``"none"``."""
        if self.p < 0.05 and self.S > 0:
            return "increasing"
        if self.p < 0.05 and self.S < 0:
            return "decreasing"
        return "none"


@dataclass(frozen=True)
class TrendSlope:
    """Theil-Sen slope of a series against time.

    ``slope`` is per day when the input carried a datetime index, per index
    step otherwise; ``slope_per_year`` converts it to the analyst's units.
    """

    slope: float
    ci_low: float
    ci_high: float
    n: int
    time_unit: str = "step"
    slope_per_year: float | None = None
    ci_low_per_year: float | None = None
    ci_high_per_year: float | None = None


@dataclass
class TrendResult:
    """Everything ``trend`` computed for one series.

    ``boot_*`` fields are ``None`` unless the AR(1) diagnostic flagged
    serial correlation and the bootstrap ran.
    """

    name: str
    n: int
    n_dropped: int
    test: TrendTest
    slope: TrendSlope
    ar1_acf: float
    ar1_p: float
    ar_autocorrelated: bool
    boot_slope_se: float | None = None
    boot_ci_low: float | None = None
    boot_ci_high: float | None = None
    p_wald_boot: float | None = None
    block_length: int | None = None
    n_bootstrap: int | None = None
    notes: list[str] = field(default_factory=list)

    def summary(self) -> pd.DataFrame:
        """Tidy two-column summary: metric / value, report-ready."""
        rows = [
            ("n", self.n),
            ("n_missing_dropped", self.n_dropped),
            ("MK_S", self.test.S),
            ("MK_z", round(self.test.z, 3)),
            ("MK_p_two_sided", round(self.test.p, 5)),
            ("direction", self.test.direction),
            (
                "slope_per_day" if self.slope.time_unit == "day" else "slope_per_step",
                self.slope.slope,
            ),
            (
                "slope_95ci",
                f"[{self.slope.ci_low:.4g}, {self.slope.ci_high:.4g}]"
                + (" /day" if self.slope.time_unit == "day" else " /step"),
            ),
            ("ar1_residual_acf", round(self.ar1_acf, 3)),
            ("ar1_p", round(self.ar1_p, 5)),
        ]
        if self.ar_autocorrelated:
            rows += [
                (
                    "bootstrap_SE",
                    None if self.boot_slope_se is None else round(self.boot_slope_se, 4),
                ),
                (
                    "bootstrap_95ci",
                    None
                    if self.boot_ci_low is None
                    else f"[{self.boot_ci_low:.4g}, {self.boot_ci_high:.4g}]",
                ),
                (
                    "p_wald_block_bootstrap",
                    None if self.p_wald_boot is None else round(self.p_wald_boot, 5),
                ),
                ("block_length", self.block_length),
                ("n_bootstrap", self.n_bootstrap),
            ]
        return pd.DataFrame(rows, columns=["metric", "value"])

    def __str__(self) -> str:
        s = self.slope
        unit = "u/m3/day" if s.time_unit == "day" else "u/step"
        line = (
            f"{self.name}: n={self.n}"
            + (f" (dropped {self.n_dropped} missing)" if self.n_dropped else "")
            + f" | MK p={self.test.p:.3g} ({self.test.direction})"
            + f" | slope {s.slope:.4g} {unit}"
            + f" | 95% CI [{s.ci_low:.4g}, {s.ci_high:.4g}]"
        )
        if self.ar_autocorrelated:
            # The AR(1) trigger can fire yet leave no bootstrap -- e.g. more
            # than n_bootstrap replicates are finite when many bootstrap
            # blocks land entirely on a single repeated timestamp (collinear
            # x -> undefined OLS slope, filtered out below). Then report the
            # trigger and say the interval is unavailable rather than
            # formatting None.
            if self.boot_slope_se is not None and self.p_wald_boot is not None:
                line += (
                    f" | AR(1) acf={self.ar1_acf:.2f} -> block bootstrap: "
                    f"SE={self.boot_slope_se:.4g}, p={self.p_wald_boot:.3g}"
                )
            else:
                line += (
                    f" | AR(1) acf={self.ar1_acf:.2f} -> block bootstrap unavailable (see notes)"
                )
        return line


@dataclass
class TrendBreaks:
    """Piecewise (segmented) trend: where the series changes regime, if at all.

    ``starts`` / ``ends`` hold the index value of each segment's first and
    last point -- timestamps for a datetime-indexed series, positions for a
    positional one -- and ``segments`` the matching Theil-Sen slope with its
    Sen (1968) interval. ``p_value`` is the moving-block bootstrap p-value
    for "is the best split better than pure noise searched over every
    candidate position", and ``significant`` whether it passed ``alpha``.
    When the gate fails, ``n_segments`` is 1 and the gate's numbers stay in
    ``sse_single`` / ``sse_segmented`` / ``p_value`` / ``notes`` so a report
    can say why the record was kept as one regime. ``best_break`` is the
    position (index value) of the first round's best cut -- the start of the
    would-be second regime -- and ``best_split_pct`` its SSE reduction,
    reported even when the gates rejected it.
    """

    name: str
    n: int
    n_dropped: int
    time_unit: str
    starts: list[Any]
    ends: list[Any]
    segments: list[TrendSlope]
    n_segments: int
    best_break: Any | None = None
    best_split_pct: float = 0.0
    sse_single: float | None = None
    sse_segmented: float | None = None
    improvement_pct: float | None = None
    bic_single: float | None = None
    bic_segmented: float | None = None
    p_value: float | None = None
    significant: bool = False
    alpha: float = 0.05
    max_segments: int = 2
    min_segment: int | None = None
    block_length: int | None = None
    n_bootstrap: int | None = None
    notes: list[str] = field(default_factory=list)

    def summary(self) -> pd.DataFrame:
        """One row per segment, report-ready (start, end, n, slope, CI)."""
        rows = []
        per_year = self.time_unit == "day"
        for seg, start, end in zip(self.segments, self.starts, self.ends, strict=True):
            row: dict[str, Any] = {
                "start": start,
                "end": end,
                "n": seg.n,
                "slope": seg.slope,
                "ci_low": seg.ci_low,
                "ci_high": seg.ci_high,
            }
            if per_year and seg.slope_per_year is not None:
                row = {
                    **row,
                    "slope_per_year": seg.slope_per_year,
                    "ci_low_per_year": seg.ci_low_per_year,
                    "ci_high_per_year": seg.ci_high_per_year,
                }
            rows.append(row)
        return pd.DataFrame(rows)

    def __str__(self) -> str:
        unit = "u/m3/day" if self.time_unit == "day" else "u/step"
        line = f"{self.name}: n={self.n}"
        if self.n_dropped:
            line += f" (dropped {self.n_dropped} missing)"
        if self.n_segments > 1:
            line += (
                f" | {self.n_segments} segments | break at {_fmt_index(self.best_break)}"
                f" | SSE -{self.improvement_pct:.1f}%"
            )
            for i, seg in enumerate(self.segments, 1):
                line += f" | seg{i} slope {seg.slope:.3g} {unit}"
            line += f" | p={self.p_value:.3g}"
            if not self.significant:
                line += " (no break; single regime reported)"
        else:
            seg = self.segments[0]
            line += (
                f" | 1 segment | slope {seg.slope:.3g} {unit}"
                f" | 95% CI [{seg.ci_low:.3g}, {seg.ci_high:.3g}]"
            )
            if self.best_break is not None:
                ptxt = f", p={self.p_value:.3g}" if self.p_value is not None else ""
                line += (
                    f" | best cut at {_fmt_index(self.best_break)} (SSE "
                    f"{self.best_split_pct:.1f}% lower{ptxt}) -- not reported as a break"
                )
        return line


def _fmt_index(value: Any) -> str:
    """Format an index value for the one-line report (timestamps as date)."""
    if isinstance(value, pd.Timestamp):
        return value.strftime("%Y-%m-%d %H:%M")
    return str(value)
