"""R → Save Figure as R Script… (normet_r_gui._r_figures): a tab's result written as a CSV
and the R that draws it with the normet package's ggplot2 figures; and the command log's
entries drawing each result the same way."""

from __future__ import annotations

import subprocess

import numpy as np
import pandas as pd
import pytest

from normet_r_gui import _r_figures, _rpc
from normet_r_gui import commandlog as C
from normet_r_gui.nm import _r

needs_r = pytest.mark.skipif(not _rpc.rscript(), reason="Rscript not found")


@pytest.fixture(scope="module")
def qapp():
    pytest.importorskip("PySide6")
    from PySide6.QtWidgets import QApplication

    return QApplication.instance() or QApplication([])


def _results() -> dict[str, pd.DataFrame]:
    dates = pd.date_range("2020-01-01", periods=96, freq="h", tz="UTC", name="date")
    rng = np.random.default_rng(0)
    obs = 40 + rng.normal(0, 5, len(dates))
    normalised = pd.DataFrame(
        {
            "observed": obs,
            "normalised": obs * 0.8,
            "q050": obs * 0.7,
            "q500": obs * 0.8,
            "q950": obs * 0.9,
        },
        index=dates,
    )
    decomposition = pd.DataFrame(
        {
            "observed": obs,
            "emi_total": obs - 2,
            "emi_base": 30.0,
            "date_unix": 1.0,
            "day_julian": 1.0,
            "weekday": 1.0,
            "hour": 1.0,
            "emi_noise": obs - 36,
        },
        index=dates,
    )
    rolled = pd.DataFrame(
        {
            "observed": obs,
            "window_01": np.r_[obs[:72], [np.nan] * 24],
            "window_02": np.r_[[np.nan] * 24, obs[24:] + 1],
        },
        index=dates,
    )
    pdp = pd.DataFrame(
        {
            "variable": ["ws"] * 5 + ["hour"] * 5,
            "value": list(range(5)) * 2,
            "pdp_mean": rng.normal(40, 1, 10),
            "pdp_std": 0.5,
        }
    )
    return {
        "normalise": normalised,
        "decompose": decomposition,
        "rolling": rolled,
        "pdp": pdp,
    }


def test_the_script_reads_its_table_and_saves_its_figure(tmp_path):
    result = _results()["normalise"]
    path = _r_figures.write("normalise", result, tmp_path / "fig", target="NO2", lang="zh")
    assert path == tmp_path / "fig.R"
    table = pd.read_csv(tmp_path / "fig.csv")
    assert list(table.columns) == ["date", "observed", "normalised", "q050", "q500", "q950"]
    assert table["date"].iloc[1] == "2020-01-01 01:00:00"  # UTC, written plainly
    code = path.read_text()
    assert 'library(normet)\noptions(normet.lang = "zh")' in code
    assert f'normalised <- read.csv("{tmp_path / "fig.csv"}"' in code
    assert (
        'fig <- nm_plot_normalise(normalised, ylabel = "NO2", ci_low = "q050", ci_high = "q950")'
        in code
    )
    assert (
        f'ggplot2::ggsave("{tmp_path / "fig.pdf"}", fig, width = 180, height = 90, units = "mm", '
        'device = if (capabilities("cairo")) grDevices::cairo_pdf else "pdf")' in code
    )


@needs_r
@pytest.mark.parametrize("key", list(_r_figures.FIGURES))
def test_each_script_draws_its_figure_in_r(tmp_path, key):
    path = _r_figures.write(key, _results()[key], tmp_path / key, target="NO2")
    out = subprocess.run([_rpc.rscript(), str(path)], capture_output=True, text=True, cwd=tmp_path)
    assert out.returncode == 0, out.stderr
    pdf = tmp_path / f"{key}.pdf"
    assert pdf.exists() and pdf.read_bytes()[:4] == b"%PDF"
    assert not (tmp_path / "Rplots.pdf").exists()  # drawn into its own file only


def test_the_log_draws_each_result_as_the_r_package_does():
    df = pd.DataFrame(
        {
            "date": pd.date_range("2020-01-01", periods=48, freq="h"),
            "NO2": 1.0,
            "ws": 2.0,
        }
    )
    df_prep = df.rename(columns={"NO2": "value"})
    model = _r.RModel("/nowhere", {"backend": "lightgbm", "features": ["ws"]})
    names = [(df, "df"), (df_prep, "df_prep"), (model, "model")]
    drawn = {
        _r.normalise: "fig_normalise <- nm_plot_normalise(normalised)\nif (interactive()) print(fig_normalise)",
        _r.decompose: "fig_decomposition <- nm_plot_decomposition_stack(decomposition)\nif (interactive()) print(fig_decomposition)",
        _r.rolling: "fig_rolled <- nm_plot_rolling(rolled, data = df_prep)\nif (interactive()) print(fig_rolled)",
        _r.pdp: "fig_pd <- nm_plot_pdp_grid(pd_values, data = df_prep)\nif (interactive()) print(fig_pd)",
    }
    for fn, lines in drawn.items():
        assert C.task(fn, (df_prep, model), {}, names).code.endswith(lines)
    # Quantiles asked for: the widest as the band.
    entry = C.task(_r.normalise, (df_prep, model), {"return_quantiles": [0.25, 0.05, 0.95]}, names)
    assert 'nm_plot_normalise(normalised, ci_low = "q050", ci_high = "q950")' in entry.code
    # A table the log has no name for: the figure without it.
    other = df_prep.copy()
    entry = C.task(_r.pdp, (other, model), {}, names)
    assert entry.code.endswith(
        "fig_pd <- nm_plot_pdp_grid(pd_values)\nif (interactive()) print(fig_pd)"
    )


def test_the_r_menu_saves_the_open_tabs_figure(qapp, monkeypatch, tmp_path):
    from PySide6.QtWidgets import QFileDialog

    from normet_r_gui.main_window import MainWindow

    results = _results()
    win = MainWindow()
    try:
        action = [a for a in win.menuBar().actions() if a.text() == "&R"][0]
        assert any(a.text() == "Save Figure as R &Script…" for a in action.menu().actions())
        # Not a tab the R package draws: said so, nothing asked.
        asked = []
        monkeypatch.setattr(
            QFileDialog, "getSaveFileName", lambda *a, **k: asked.append(a) or ("", "")
        )
        win.tabs.setCurrentWidget(win.tab_model)
        win._save_figure_r()
        assert not asked
        # The Decomposition tab: the method its selector shows, not the last run.
        met = results["decompose"].rename(columns={"emi_noise": "ws"}).assign(met_total=1.0)
        win.results["decompose"] = met
        win.tab_decom._views = (
            "Method",
            {
                "emission": (None, results["decompose"], {}),
                "meteorology": (None, met, {}),
            },
            "emission",
        )
        win.tabs.setCurrentWidget(win.tab_decom)
        key, shown = win._figure_r_result()
        assert key == "decompose" and shown is results["decompose"]
        target = tmp_path / "decomposition.R"
        monkeypatch.setattr(QFileDialog, "getSaveFileName", lambda *a, **k: (str(target), ""))
        win._save_figure_r()
        assert target.exists() and (tmp_path / "decomposition.csv").exists()
        assert "nm_plot_decomposition_stack(decomposition)" in target.read_text()
        assert "emi_noise" in (tmp_path / "decomposition.csv").read_text().splitlines()[0]
    finally:
        win.close()
