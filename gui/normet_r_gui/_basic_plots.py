"""Local ports of normet-py's plotting helpers used by the GUI.

The Python package ships these in ``normet.plotting``; the R package's
equivalents are ggplot-based and cannot be embedded in a matplotlib canvas,
so the GUI re-implements the small set it needs from the bridge's CSV
results.
"""

from __future__ import annotations

from typing import Any

import pandas as pd


def normalise_plot(
    result_df: pd.DataFrame,
    *,
    observed_col: str = "observed",
    normalised_col: str = "normalised",
    ci_low: str | None = None,
    ci_high: str | None = None,
    title: str | None = None,
    ylabel: str = "Concentration",
) -> Any:
    """Observed vs. normalised (deweathered) series, optional quantile band."""
    import matplotlib.pyplot as plt

    df = result_df
    fig, ax = plt.subplots(figsize=(11, 4))
    ax.plot(df.index, df[observed_col], color="#2c7bb6", lw=1.2, alpha=0.7, label="Observed")
    ax.plot(
        df.index, df[normalised_col], color="#d7191c", lw=1.8, label="Normalised (deweathered)"
    )
    if ci_low and ci_high and ci_low in df.columns and ci_high in df.columns:
        ax.fill_between(
            df.index, df[ci_low], df[ci_high], color="#d7191c", alpha=0.15, label="Quantile band"
        )
    ax.set_title(title or "Observed vs. Normalised concentration")
    ax.set_ylabel(ylabel)
    ax.grid(alpha=0.2)
    ax.legend(frameon=False, fontsize=9)
    fig.tight_layout()
    return fig


def pdp_grid(
    pdp_df: pd.DataFrame,
    *,
    cols: int = 3,
    figsize_per: tuple[float, float] = (4.0, 2.8),
    title: str | None = None,
) -> Any:
    """Faceted grid of partial-dependence curves (columns: variable, value,
    pdp_mean[, pdp_std])."""
    import matplotlib.pyplot as plt

    variables = list(pdp_df["variable"].drop_duplicates())
    n = len(variables)
    rows = (n + cols - 1) // cols
    fig, axes = plt.subplots(
        rows, cols, figsize=(figsize_per[0] * cols, figsize_per[1] * rows), squeeze=False
    )
    for k, var in enumerate(variables):
        ax = axes[k // cols, k % cols]
        sub = pdp_df[pdp_df["variable"] == var].sort_values("value")
        ax.plot(sub["value"], sub["pdp_mean"], lw=1.8, color="C0")
        if "pdp_std" in sub.columns and sub["pdp_std"].notna().any():
            ax.fill_between(
                sub["value"],
                sub["pdp_mean"] - sub["pdp_std"],
                sub["pdp_mean"] + sub["pdp_std"],
                alpha=0.18,
                color="C0",
            )
        ax.set_title(var)
        ax.grid(alpha=0.2)
    for k in range(n, rows * cols):
        axes[k // cols, k % cols].set_visible(False)
    if title:
        fig.suptitle(title)
    fig.tight_layout()
    return fig
