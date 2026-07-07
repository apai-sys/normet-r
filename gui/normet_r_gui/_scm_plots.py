"""Matplotlib figures for the SCM Studio, ported from normet-py.

The R package returns plain data frames over the bridge; these helpers turn
them into the same dashboard / bands figures the Python GUI shows.
"""

from __future__ import annotations

from typing import Any

import pandas as pd

TREATED_COLOR = "#d7191c"
DONOR_COLOR = "#9a9a9a"


def scm_dashboard(
    synth: pd.DataFrame,
    weights: pd.DataFrame | None,
    *,
    cutoff_date: str,
    diagnostics: dict | None = None,
    title: str = "SCM dashboard",
) -> Any:
    """Observed vs. synthetic + effect path + donor weights."""
    import matplotlib.pyplot as plt

    fig, (a1, a2, a3) = plt.subplots(
        3, 1, figsize=(11, 8), gridspec_kw={"height_ratios": [3, 2, 2]}
    )
    cutoff_ts = pd.to_datetime(cutoff_date)
    idx = synth.index

    a1.plot(idx, synth["observed"], label="observed", lw=1.5)
    a1.plot(idx, synth["synthetic"], label="synthetic", lw=1.5, ls="--")
    a1.axvline(cutoff_ts, color="k", ls=":", lw=1)
    a1.set_title(title)
    a1.set_ylabel("Outcome")
    a1.legend(frameon=False)
    a1.grid(alpha=0.2)

    a2.plot(idx, synth["effect"], color="tab:red", lw=1.5)
    a2.axhline(0.0, color="k", lw=0.5)
    a2.axvline(cutoff_ts, color="k", ls=":", lw=1)
    a2.set_ylabel("Effect (observed − synthetic)")
    a2.grid(alpha=0.2)

    top: list[tuple[str, float]] = []
    if diagnostics and diagnostics.get("top_donors"):
        top = list(diagnostics["top_donors"])
    elif weights is not None and len(weights) >= 2:
        unit_col, w_col = weights.columns[0], weights.columns[-1]
        w = weights.sort_values(w_col, ascending=False).head(10)
        top = list(zip(w[unit_col].astype(str), w[w_col].astype(float), strict=True))
    if top:
        names = [n for n, _ in top][::-1]
        vals = [v for _, v in top][::-1]
        a3.barh(names, vals, color="tab:blue")
        subtitle = "Top donor weights"
        if diagnostics and "hhi" in diagnostics:
            subtitle += (
                f"  |  HHI={diagnostics['hhi']:.3f}"
                f"  |  effective_N={diagnostics.get('effective_n_donors', float('nan')):.1f}"
            )
        a3.set_title(subtitle)
        a3.set_xlabel("weight")
    else:
        a3.text(0.5, 0.5, "No donor weights available", ha="center", va="center")
        a3.axis("off")

    fig.tight_layout()
    return fig


def plot_effect_with_bands(
    bands: pd.DataFrame,
    *,
    cutoff_date: str | pd.Timestamp | None,
    title: str,
    ax: Any,
) -> None:
    """Effect line with a shaded low/high band on an existing axes."""
    low_col = next((c for c in bands.columns if c.lower().startswith("low")), None)
    high_col = next((c for c in bands.columns if c.lower().startswith("high")), None)
    if low_col and high_col:
        ax.fill_between(
            bands.index, bands[low_col], bands[high_col], color=DONOR_COLOR, alpha=0.35,
            label="placebo band",
        )
    if "effect" in bands.columns:
        ax.plot(bands.index, bands["effect"], color=TREATED_COLOR, lw=1.8, label="effect")
    if cutoff_date is not None:
        ax.axvline(pd.to_datetime(cutoff_date), color="k", ls=":", lw=1)
    ax.axhline(0, color="k", lw=0.5)
    ax.set_title(title, fontsize=10, loc="left")
    ax.legend(loc="upper left", frameon=False, fontsize=8)
    ax.grid(alpha=0.2)


def plot_uncertainty_bands(
    export: pd.DataFrame,
    *,
    cutoff_date: str,
    title: str,
) -> Any:
    """Effect path with jackknife/bootstrap band (columns: effect, low, high)."""
    import matplotlib.pyplot as plt

    fig, ax = plt.subplots(figsize=(10, 4.6))
    ax.fill_between(
        export.index, export["low"], export["high"], color=TREATED_COLOR, alpha=0.15,
        label="uncertainty band",
    )
    ax.plot(export.index, export["effect"], color=TREATED_COLOR, lw=1.6, label="effect")
    ax.axvline(pd.to_datetime(cutoff_date), color="k", ls=":", lw=1)
    ax.axhline(0, color="k", lw=0.5)
    ax.set_title(title, fontsize=10, loc="left")
    ax.legend(loc="upper left", frameon=False, fontsize=8)
    ax.grid(alpha=0.2)
    fig.tight_layout()
    return fig
