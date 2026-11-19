"""The window's analysis results: normet-py's shapes, the R package's numbers.

The window is normet-py's GUI, and it reads the trend results as normet-py's
``analysis.trend`` dataclasses and the uncertainty run as its
``analysis.uncertainty`` one. The arithmetic that fills them is the normet R
package's (``nm_trend``, ``nm_trend_breaks``, ``nm_decompose_uncertainty``,
reached through :mod:`nm._r`); this module holds the shapes themselves, copied
as they are from normet-py, so the window cannot tell the two apart.
"""

from __future__ import annotations

from .trend import TrendBreaks, TrendResult, TrendSlope, TrendTest
from .uncertainty import UncDecomposition
from .verification import (  # noqa: F401 - arithmetic, normet-py's own
    crps_from_quantiles,
    crps_from_samples,
    crps_observed,
    pinball_loss,
)

__all__ = [
    "TrendBreaks",
    "TrendResult",
    "TrendSlope",
    "TrendTest",
    "UncDecomposition",
    "crps_from_quantiles",
    "crps_from_samples",
    "crps_observed",
    "pinball_loss",
]
