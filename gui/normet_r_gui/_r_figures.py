"""R → Save Figure as R Script…: the result a tab shows, drawn by the normet R package.

The window draws its figures with matplotlib; the R package draws the same results with
ggplot2 (``nm_plot_normalise``, ``nm_plot_decomposition_stack``, ``nm_plot_rolling``,
``nm_plot_pdp_grid``). This writes the tab's result as a CSV and, beside it, the R that
reads it, draws it and saves it as a PDF -- a figure to change in R, without training
the model again. This window's own module: normet-py has no R to write.
"""

from __future__ import annotations

import datetime
import re
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path

import pandas as pd

from .commandlog import band, literal


@dataclass(frozen=True)
class Figure:
    """A result the R package draws: the name the script gives the table, the call that
    draws it (``{t}`` the table's name, ``{y}`` the y label's argument), and its height
    in mm for one row of panels."""

    title: str
    table: str
    plot: str
    height_mm: float = 90.0


#: The window's results the R package draws, by the result's key (``self.results``).
FIGURES: dict[str, Figure] = {
    "normalise": Figure("Normalised", "normalised", "nm_plot_normalise({t}{y}{band})"),
    "decompose": Figure("Decomposition", "decomposition", "nm_plot_decomposition_stack({t})"),
    "rolling": Figure("Rolling normalisation", "rolled", "nm_plot_rolling({t}{y})"),
    "pdp": Figure("Partial dependence", "pd_values", "nm_plot_pdp_grid({t})", 55.0),
}

#: The figure's width in mm: a double column.
WIDTH_MM = 180.0

#: The PDF device: Cairo's where R has it, which finds a font for every character (R's own
#: pdf() has none for Chinese, and draws dots); R's own where it has not.
DEVICE = 'if (capabilities("cairo")) grDevices::cairo_pdf else "pdf"'


def _table(result: pd.DataFrame) -> pd.DataFrame:
    """The result with its dates as a ``date`` column, in UTC written plainly."""
    out = result.copy()
    if isinstance(out.index, pd.DatetimeIndex):
        out = out.rename_axis("date").reset_index()
    if "date" in out.columns:
        dates = pd.to_datetime(out["date"])
        if dates.dt.tz is not None:
            dates = dates.dt.tz_convert("UTC").dt.tz_localize(None)
        out["date"] = dates.dt.strftime("%Y-%m-%d %H:%M:%S")
    return out


def script(
    key: str,
    csv: Path,
    pdf: Path,
    *,
    target: str = "",
    lang: str = "en",
    columns: Sequence[str] = (),
) -> str:
    """The R that draws result *key* from *csv* (its *columns*) and saves it as *pdf*."""
    fig = FIGURES[key]
    t = fig.table
    y = f", ylabel = {literal(target)}" if target and "{y}" in fig.plot else ""
    # The widest of the quantiles normalising returned (q050 ... q950), as the band.
    quantiles = [int(c[1:]) / 1000 for c in columns if re.fullmatch(r"q\d{3}", str(c))]
    height = fig.height_mm
    try:
        from .nm import __version__ as version
    except Exception:  # pragma: no cover
        version = "?"
    when = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
    lines = [
        f"# {fig.title}: the window's figure, drawn by the normet R package (ggplot2).",
        "#",
        f"# Written by normet {version} (R) on {when}. Run it (Rscript, or source() in R)",
        f"# to read {csv.name} and write {pdf.name}; change the figure as any ggplot.",
        "library(normet)",
    ]
    if lang != "en":
        lines.append(f"options(normet.lang = {literal(lang)})")
    lines += ["", f"{t} <- read.csv({literal(str(csv))}, check.names = FALSE)"]
    if key != "pdp":
        lines.append(f'{t}$date <- as.POSIXct({t}$date, tz = "UTC")')
    lines += [
        "",
        f"fig <- {fig.plot.format(t=t, y=y, band=band(quantiles))}",
        "if (interactive()) print(fig)",
    ]
    if key == "pdp":
        lines += [
            "",
            "# Three panels a row, as nm_plot_pdp_grid lays them out.",
            f"rows <- ceiling(length(unique({t}$variable)) / 3)",
            f"ggplot2::ggsave({literal(str(pdf))}, fig, width = {WIDTH_MM:g}, "
            f'height = {height:g} * rows, units = "mm", device = {DEVICE})',
        ]
    else:
        lines += [
            "",
            f"ggplot2::ggsave({literal(str(pdf))}, fig, width = {WIDTH_MM:g}, "
            f'height = {height:g}, units = "mm", device = {DEVICE})',
        ]
    return "\n".join(lines) + "\n"


def write(
    key: str,
    result: pd.DataFrame,
    path: str | Path,
    *,
    target: str = "",
    lang: str = "en",
) -> Path:
    """Result *key* written as ``<path>.csv`` and the R that draws it as ``<path>.R``
    (the PDF it saves beside them); the script's path."""
    path = Path(path)
    if path.suffix.lower() != ".r":
        path = path.with_name(path.name + ".R")
    csv, pdf = path.with_suffix(".csv"), path.with_suffix(".pdf")
    table = _table(result)
    table.to_csv(csv, index=False)
    code = script(key, csv, pdf, target=target, lang=lang, columns=list(table.columns))
    path.write_text(code, encoding="utf-8")
    return path
