# gui/normet_r_gui/nm/analysis/uncertainty.py
"""The uncertainty result the window reads: normet-py's dataclass, copied as it is.

The window is normet-py's GUI and reads the uncertainty step's result as this
class (its tab, its figure, its verdict and the saved session all go through
it). The arithmetic that fills it is the normet R package's
(``nm_decompose_uncertainty``, reached through :mod:`nm._r`); this module
holds the shape alone, field for field and method for method, so the window
cannot tell the two apart. The figure draws from the per-date vectors with
matplotlib, as normet-py's does, in the house style of :mod:`nm.style`.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

import numpy as np
import pandas as pd

from .. import style as S
from ..style import styled

__all__ = ["UncDecomposition"]


@dataclass
class UncDecomposition:
    """The per-date attribution of a run's total variance to its sources.

    ``var_weather``, ``var_model`` and ``var_interaction`` are the per-date (in
    the target's units squared) two-way main effects and their interaction;
    ``var_total`` is their sum exactly. ``pct_*`` are the shares of ``var_total``.
    ``summary()`` reports the median share across the record; ``plot()`` draws
    the stacked bands over time. ``notes`` carry the caveats a report must
    state (the interaction is a residual, the shares are medians).
    """

    var_weather: np.ndarray
    var_model: np.ndarray
    var_interaction: np.ndarray
    var_total: np.ndarray
    index: pd.Index
    target: str
    n_models: int
    n_weather_draws: int
    seed: int
    notes: list[str] = field(default_factory=list)

    @property
    def pct_weather(self) -> np.ndarray:
        return self._pct(self.var_weather)

    @property
    def pct_model(self) -> np.ndarray:
        return self._pct(self.var_model)

    @property
    def pct_interaction(self) -> np.ndarray:
        return self._pct(self.var_interaction)

    def _pct(self, part: np.ndarray) -> np.ndarray:
        with np.errstate(divide="ignore", invalid="ignore"):
            p = np.where(
                self.var_total > 0, part / np.where(self.var_total > 0, self.var_total, 1.0), np.nan
            )
        return p

    def frame(self) -> pd.DataFrame:
        """The per-date rows as a DataFrame, report-ready and directly plottable."""
        df = pd.DataFrame(
            {
                "var_weather": self.var_weather,
                "var_model": self.var_model,
                "var_interaction": self.var_interaction,
                "var_total": self.var_total,
                "pct_weather": self.pct_weather,
                "pct_model": self.pct_model,
                "pct_interaction": self.pct_interaction,
            },
            index=self.index,
        )
        df.index.name = "date"
        return df

    def summary(self) -> pd.DataFrame:
        """The per-source median variance and its median share of the total.

        The shares are the headline of a policy evaluation ("of the band, this
        fraction is weather, that one is model form"), so they are medians
        across the record rather than means: a single extreme day does not
        re-weight the attribution. ``interaction`` is the residual the other
        two do not explain, reported like the others so its size is visible.
        """

        def med(a: np.ndarray) -> float:
            return float(np.nanmedian(a))

        rows = [
            ("weather", med(self.var_weather), med(self.pct_weather)),
            ("model", med(self.var_model), med(self.pct_model)),
            ("interaction", med(self.var_interaction), med(self.pct_interaction)),
            ("total", med(self.var_total), 1.0),
        ]
        return pd.DataFrame(rows, columns=["source", "var_median", "pct_median"])

    @styled
    def plot(
        self,
        *,
        title: str | None = None,
        ylabel: str = "Variance (target units**2)",
        ax: Any | None = None,
    ) -> Any:
        """The stacked per-date variance bands (weather, model, interaction).

        The three sources stack to ``var_total`` on every date, so the height
        of the stack is the total spread the model and the met resampling
        together carry, and each band's height is that source's share. The
        figure is the policy-evaluation deliverable: which band dominates the
        total, date by date and in the median.
        """
        import matplotlib.pyplot as plt

        if ax is None:
            _, ax = plt.subplots(figsize=(8, 3), layout="constrained")
        idx = self.index
        Y = np.vstack([self.var_weather, self.var_model, self.var_interaction])
        labels = ["weather", "model", "interaction"]
        colours = [S.PALETTE[0], S.PALETTE[1], S.PALETTE[3]]
        ax.stackplot(idx, Y, labels=labels, colors=colours, alpha=0.85, lw=0)
        S.line(ax, idx, self.var_total, color=S.INK, emphasis=False, lw=0.8, label="total")
        ax.set_title(title or "Uncertainty: where the spread comes from")
        ax.set_ylabel(ylabel)
        if isinstance(idx, pd.DatetimeIndex):
            S.format_time_axis(ax)
        ax.margins(x=0)
        S.grid(ax)
        S.legend(ax, loc="upper right", ncols=2)
        return ax

    def __str__(self) -> str:
        n = len(self.index)
        med_w = float(np.nanmedian(self.pct_weather))
        med_m = float(np.nanmedian(self.pct_model))
        med_i = float(np.nanmedian(self.pct_interaction))
        return (
            f"{self.target}: {n} dates, {self.n_models} models x "
            f"{self.n_weather_draws} met draws | median spread share: "
            f"weather {100.0 * med_w:.0f}%, model {100.0 * med_m:.0f}%, "
            f"interaction {100.0 * med_i:.0f}%"
        )
