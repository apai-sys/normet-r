"""Data Studio — fetch UK air-quality (+ optional CDS meteorology) via R.

Mirror of normet-py's Data Studio; station discovery and downloads go
through the normet R package (``nm_list_aurn_stations`` /
``nm_fetch_aurn_measurements`` / ``nm_fetch_era5_timeseries``).

1. **Find stations** — tick pollutants, query the UK-AIR (AURN/DEFRA) API,
   browse/search the station table and pick one.
2. **Fetch & merge** — download the hourly measurements for every ticked
   pollutant at that site, optionally add ERA5 meteorology from the
   Copernicus CDS (needs ``~/.cdsapirc``), and outer-join everything on the
   hourly timestamp into the wide table the modelling steps expect.
"""

from __future__ import annotations

import logging
import os

import pandas as pd
from PySide6.QtCore import QDate, Qt
from PySide6.QtWidgets import (
    QAbstractItemView,
    QDateEdit,
    QFileDialog,
    QFormLayout,
    QGroupBox,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QListWidget,
    QListWidgetItem,
    QMainWindow,
    QMessageBox,
    QProgressBar,
    QPushButton,
    QScrollArea,
    QSplitter,
    QTableWidget,
    QTableWidgetItem,
    QTabWidget,
    QVBoxLayout,
    QWidget,
)

from ._widgets import CanvasTab, NoWheelComboBox, hint_label, run_button
from .workers import TaskRunner

log = logging.getLogger(__name__)

POLLUTANTS = ["PM2.5", "PM10", "NO2", "NOX", "NO", "O3", "SO2", "CO"]
DEFAULT_POLLUTANTS = {"PM2.5", "NO2", "O3"}

MET_OPEN_METEO = "Open-Meteo (ERA5, no key needed)"
MET_CDS = "Copernicus CDS (needs ~/.cdsapirc)"
MET_NONE = "None (air quality only)"


def _site_name(station_label: str) -> str:
    """'Manchester Piccadilly-Nitrogen dioxide (air)' → 'Manchester Piccadilly'."""
    return str(station_label).rsplit("-", 1)[0].strip()


def _aggregate_stations(raw: pd.DataFrame, pollutants: list[str]) -> pd.DataFrame:
    """One row per site from the bridge's per-(station, pollutant) rows."""
    if raw.empty:
        return pd.DataFrame(columns=["site", "code", "pollutants", "n", "lat", "lon", "ids"])
    raw = raw.copy()
    raw["site"] = raw["label"].map(_site_name)
    sites: dict[str, dict] = {}
    for _, row in raw.iterrows():
        rec = sites.setdefault(
            row["site"],
            {
                "site": row["site"],
                "code": row.get("code"),
                "lat": row.get("lat"),
                "lon": row.get("lon"),
                "ids": {},
            },
        )
        rec["ids"].setdefault(str(row.get("pollutant")), row.get("id"))
        if pd.isna(rec.get("code")) and pd.notna(row.get("code")):
            rec["code"] = row.get("code")
    rows = [
        {
            "site": r["site"],
            # Official AURN site code (MY1, MAN3, …) from DEFRA metadata.
            "code": r["code"] if pd.notna(r.get("code")) else "",
            "pollutants": ", ".join(p for p in pollutants if p in r["ids"]),
            "n": len(r["ids"]),
            "lat": r["lat"],
            "lon": r["lon"],
            "ids": r["ids"],
        }
        for r in sites.values()
    ]
    return (
        pd.DataFrame(rows)
        .sort_values(["n", "site"], ascending=[False, True])
        .reset_index(drop=True)
    )


class DataWindow(QMainWindow):
    """'Get UK data' window: AURN measurements + optional CDS met, merged in R."""

    def __init__(self, parent: QWidget | None = None, bridge_factory=None) -> None:
        super().__init__(parent)
        self.setWindowTitle("Normet — Data Studio (UK AQ + met)")
        self.resize(1240, 820)
        self._main = parent

        from .rbridge import RBridge

        self.bridge = (bridge_factory or RBridge)()
        self.stations: pd.DataFrame | None = None
        self.merged: pd.DataFrame | None = None

        self.runner = TaskRunner(self)
        self.runner.started.connect(self._task_started)
        self.runner.finished.connect(self._task_finished)

        splitter = QSplitter(Qt.Orientation.Horizontal)
        splitter.addWidget(self._build_panel())
        right = QWidget()
        rv = QVBoxLayout(right)
        rv.setContentsMargins(0, 4, 4, 0)
        rv.addWidget(self._build_action_bar())
        rv.addWidget(self._build_tabs(), 1)
        splitter.addWidget(right)
        splitter.setStretchFactor(0, 0)
        splitter.setStretchFactor(1, 1)
        splitter.setSizes([360, 880])
        self.setCentralWidget(splitter)

        self.progress = QProgressBar()
        self.progress.setRange(0, 1)
        self.progress.setMaximumWidth(220)
        self.cancel_btn = QPushButton("Cancel")
        self.cancel_btn.setEnabled(False)
        self.cancel_btn.setToolTip("Abandon the running download.")
        self.cancel_btn.clicked.connect(self._abandon)
        self.statusBar().addPermanentWidget(self.cancel_btn)
        self.statusBar().addPermanentWidget(self.progress)
        self.statusBar().showMessage(
            "Tick pollutants, click 🔍 Find stations, pick a site, then ▶ Fetch & merge."
        )
        self._sync_enabled()

    # ------------------------------------------------------------- left panel
    def _build_panel(self) -> QWidget:
        panel = QWidget()
        v = QVBoxLayout(panel)

        aq_box = QGroupBox("Air quality (UK AURN)")
        av = QVBoxLayout(aq_box)
        av.addWidget(QLabel("Pollutants"))
        self.pol_list = QListWidget()
        self.pol_list.setSelectionMode(QAbstractItemView.SelectionMode.NoSelection)
        self.pol_list.setMaximumHeight(150)
        self.pol_list.setToolTip("Each ticked pollutant becomes one column of the merged table.")
        for pol in POLLUTANTS:
            item = QListWidgetItem(pol)
            item.setFlags(item.flags() | Qt.ItemFlag.ItemIsUserCheckable)
            item.setCheckState(
                Qt.CheckState.Checked if pol in DEFAULT_POLLUTANTS else Qt.CheckState.Unchecked
            )
            self.pol_list.addItem(item)
        av.addWidget(self.pol_list)
        self.find_btn = run_button(
            "🔍  Find stations",
            "Query the UK-AIR API for all AURN sites measuring the ticked\npollutants and list them on the right.",
        )
        self.find_btn.clicked.connect(self._run_find_stations)
        av.addWidget(self.find_btn)
        self.station_hint = hint_label("No station chosen yet", small=False)
        av.addWidget(self.station_hint)
        v.addWidget(aq_box)

        rng_box = QGroupBox("Date range")
        rf = QFormLayout(rng_box)
        rf.setLabelAlignment(Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignVCenter)
        today = QDate.currentDate()
        self.date_from = QDateEdit(today.addDays(-190))
        self.date_to = QDateEdit(today.addDays(-3))
        for de in (self.date_from, self.date_to):
            de.setCalendarPopup(True)
            de.setDisplayFormat("yyyy-MM-dd")
        rf.addRow("From", self.date_from)
        rf.addRow("To", self.date_to)
        rf.addRow(
            hint_label("The UK-AIR API only serves a recent rolling window of data.")
        )
        v.addWidget(rng_box)

        met_box = QGroupBox("Meteorology")
        mf = QFormLayout(met_box)
        mf.setLabelAlignment(Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignVCenter)
        self.met_combo = NoWheelComboBox()
        self.met_combo.addItems([MET_OPEN_METEO, MET_CDS, MET_NONE])
        self.met_combo.setToolTip(
            "Hourly meteorology at the station coordinates.\n"
            "Open-Meteo serves the ERA5 archive without registration;\n"
            "the Copernicus CDS needs an account and ~/.cdsapirc."
        )
        mf.addRow("Source", self.met_combo)
        mf.addRow(
            hint_label(
                "Adds t2m, d2m, sp, tcc, tp, ssrd, u10, v10, blh —\n"
                "the predictors the Train step auto-recognises as met."
            )
        )
        v.addWidget(met_box)

        self.fetch_btn = run_button(
            "▶  Fetch && merge",
            "Download the pollutant series (and the meteorology) in R, and join\nthem into one hourly table ready for Step 1 training.",
        )
        self.fetch_btn.clicked.connect(self._run_fetch)
        v.addWidget(self.fetch_btn)

        v.addStretch(1)
        self._run_buttons = [self.find_btn, self.fetch_btn]

        scroll = QScrollArea()
        scroll.setWidget(panel)
        scroll.setWidgetResizable(True)
        scroll.setFixedWidth(380)
        scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        return scroll

    def _build_action_bar(self) -> QWidget:
        bar = QWidget()
        h = QHBoxLayout(bar)
        h.setContentsMargins(4, 0, 4, 0)
        self.save_btn = QPushButton("💾  Save merged CSV…")
        self.save_btn.clicked.connect(self._save_csv)
        self.save_btn.setEnabled(False)
        self.send_btn = QPushButton("⬆  Send to main window")
        self.send_btn.setToolTip("Load the merged table into the main window, ready for Step 1.")
        self.send_btn.clicked.connect(self._send_to_main)
        self.send_btn.setEnabled(False)
        h.addWidget(self.save_btn)
        h.addWidget(self.send_btn)
        h.addStretch(1)
        return bar

    def _build_tabs(self) -> QTabWidget:
        self.tabs = QTabWidget()

        st_tab = QWidget()
        sl = QVBoxLayout(st_tab)
        search_row = QHBoxLayout()
        search_row.addWidget(QLabel("Search"))
        self.search_edit = QLineEdit()
        self.search_edit.setPlaceholderText("e.g. Manchester")
        self.search_edit.textChanged.connect(self._filter_stations)
        search_row.addWidget(self.search_edit)
        sl.addLayout(search_row)
        self.station_table = QTableWidget()
        self.station_table.setSelectionBehavior(QAbstractItemView.SelectionBehavior.SelectRows)
        self.station_table.setSelectionMode(QAbstractItemView.SelectionMode.SingleSelection)
        self.station_table.setEditTriggers(QTableWidget.EditTrigger.NoEditTriggers)
        self.station_table.itemSelectionChanged.connect(self._station_selected)
        sl.addWidget(self.station_table, 1)
        sl.addWidget(
            hint_label("Click 🔍 Find stations to fill this table, then select the site to use.")
        )
        self.tabs.addTab(st_tab, "① Stations")

        self.tab_preview = CanvasTab("Fetch data to preview the merged table here.")
        self.tabs.addTab(self.tab_preview, "② Preview")

        pv_tab = QWidget()
        pl = QVBoxLayout(pv_tab)
        self.preview_summary = QLabel("No data fetched yet.")
        self.preview_summary.setWordWrap(True)
        pl.addWidget(self.preview_summary)
        self.preview_table = QTableWidget()
        self.preview_table.setEditTriggers(QTableWidget.EditTrigger.NoEditTriggers)
        pl.addWidget(self.preview_table, 1)
        self.tabs.addTab(pv_tab, "③ Table")
        return self.tabs

    # ---------------------------------------------------------------- helpers
    def _checked_pollutants(self) -> list[str]:
        return [
            self.pol_list.item(i).text()
            for i in range(self.pol_list.count())
            if self.pol_list.item(i).checkState() == Qt.CheckState.Checked
        ]

    def _sync_enabled(self) -> None:
        busy = self.runner.busy
        self.find_btn.setEnabled(not busy)
        self.fetch_btn.setEnabled(not busy and self._selected_station() is not None)
        has_data = self.merged is not None
        self.save_btn.setEnabled(has_data)
        self.send_btn.setEnabled(has_data and self._main is not None)
        self.cancel_btn.setEnabled(busy)

    def _task_started(self, name: str) -> None:
        self.progress.setRange(0, 0)
        self.statusBar().showMessage(f"Running in R: {name}…")
        for b in self._run_buttons:
            b.setEnabled(False)
        self.cancel_btn.setEnabled(True)

    def _task_finished(self) -> None:
        self.progress.setRange(0, 1)
        self._sync_enabled()

    def _abandon(self) -> None:
        if self.runner.busy:
            self.runner.abandon()
            self.statusBar().showMessage("Download abandoned.")

    def _show_error(self, tb: str) -> None:
        QMessageBox.critical(
            self, "Download failed", tb.splitlines()[-1] if tb else "Unknown error"
        )
        log.error("%s", tb)

    # ---------------------------------------------------------------- actions
    def _run_find_stations(self) -> None:
        pollutants = self._checked_pollutants()
        if not pollutants:
            QMessageBox.information(self, "No pollutants", "Tick at least one pollutant.")
            return
        self._pending_pollutants = pollutants
        self.runner.submit(
            "find stations",
            self.bridge.find_stations,
            self._stations_done,
            self._show_error,
            pollutants,
        )

    def _stations_done(self, raw: pd.DataFrame) -> None:
        df = _aggregate_stations(raw, self._pending_pollutants)
        self.stations = df
        self._fill_station_table(df)
        self.tabs.setCurrentIndex(0)
        self.statusBar().showMessage(
            f"{len(df)} sites measure the ticked pollutants — search and select one."
        )

    def _fill_station_table(self, df: pd.DataFrame) -> None:
        cols = ["site", "code", "pollutants", "lat", "lon"]
        self.station_table.clear()
        self.station_table.setRowCount(len(df))
        self.station_table.setColumnCount(len(cols))
        self.station_table.setHorizontalHeaderLabels(cols)
        for r, (_, row) in enumerate(df.iterrows()):
            for c, col in enumerate(cols):
                val = row[col]
                if col in ("lat", "lon") and pd.notna(val):
                    val = f"{float(val):.4f}"
                item = QTableWidgetItem(str(val))
                if c == 0:
                    item.setData(Qt.ItemDataRole.UserRole, int(row.name))
                self.station_table.setItem(r, c, item)
        self.station_table.resizeColumnsToContents()

    def _filter_stations(self, text: str) -> None:
        if self.stations is None:
            return
        text = text.strip().lower()
        df = self.stations
        if text:
            df = df[
                df["site"].str.lower().str.contains(text, na=False)
                | df["code"].str.lower().str.contains(text, na=False)
            ]
        self._fill_station_table(df)

    def _selected_station(self) -> dict | None:
        if self.stations is None:
            return None
        items = self.station_table.selectedItems()
        if not items:
            return None
        idx = self.station_table.item(items[0].row(), 0).data(Qt.ItemDataRole.UserRole)
        if idx is None or idx not in self.stations.index:
            return None
        return self.stations.loc[idx].to_dict()

    def _station_selected(self) -> None:
        st = self._selected_station()
        if st:
            self.station_hint.setText(
                f"Selected: {st['site']}\nmeasures: {st['pollutants']}"
            )
            self.station_hint.setStyleSheet("")
        self._sync_enabled()

    def _run_fetch(self) -> None:
        st = self._selected_station()
        if st is None:
            QMessageBox.information(
                self, "No station", "Find stations and select one in the table first."
            )
            return
        pollutants = [p for p in self._checked_pollutants() if p in st["ids"]]
        if not pollutants:
            QMessageBox.information(
                self, "No pollutants at this site", "The selected site measures none of the ticks."
            )
            return
        d_from = self.date_from.date().toString("yyyy-MM-dd")
        d_to = self.date_to.date().toString("yyyy-MM-dd")
        if pd.Timestamp(d_from) >= pd.Timestamp(d_to):
            QMessageBox.information(self, "Bad range", "'From' must be before 'To'.")
            return
        met = {MET_OPEN_METEO: "openmeteo", MET_CDS: "cds"}.get(
            self.met_combo.currentText(), "none"
        )
        # All ticked pollutants share the same site; fetch by the first
        # pollutant's station id (the R fetcher accepts one station id).
        station_id = str(st["ids"][pollutants[0]])
        self.runner.submit(
            f"fetch {st['site']}",
            self.bridge.fetch_merge,
            self._fetch_done,
            self._show_error,
            pollutants=pollutants,
            station_id=station_id,
            site_name=st["site"],
            lat=float(st["lat"]),
            lon=float(st["lon"]),
            date_from=d_from,
            date_to=d_to,
            met_source=met,
        )

    def _fetch_done(self, df: pd.DataFrame) -> None:
        self.merged = df
        n_nan = int(df.isna().sum().sum())
        pol_cols = [c for c in df.columns if c in POLLUTANTS]
        met_cols = [c for c in df.columns if c in ("t2m", "u10", "v10", "sp", "blh")]
        self.preview_summary.setText(
            f"{len(df):,} hourly rows × {df.shape[1]} columns   |   "
            f"{df['date'].min():%Y-%m-%d} → {df['date'].max():%Y-%m-%d}   |   "
            f"pollutants: {', '.join(pol_cols)}   |   missing cells: {n_nan:,}"
        )
        self._fill_preview_table(df)
        self._draw_preview(df, pol_cols)
        self.tabs.setCurrentWidget(self.tab_preview)
        self._sync_enabled()
        verdict_met = "with met" if met_cols else "WITHOUT met"
        self.statusBar().showMessage(
            f"Merged table ready ({verdict_met}) — save it or send it to the main window."
        )

    def _fill_preview_table(self, df: pd.DataFrame, max_rows: int = 300) -> None:
        head = df.head(max_rows)
        self.preview_table.clear()
        self.preview_table.setRowCount(len(head))
        self.preview_table.setColumnCount(df.shape[1])
        self.preview_table.setHorizontalHeaderLabels([str(c) for c in df.columns])
        for r in range(len(head)):
            for c in range(df.shape[1]):
                val = head.iat[r, c]
                if isinstance(val, float):
                    val = f"{val:.4g}"
                self.preview_table.setItem(r, c, QTableWidgetItem(str(val)))
        self.preview_table.resizeColumnsToContents()

    def _draw_preview(self, df: pd.DataFrame, pol_cols: list[str]) -> None:
        import matplotlib.pyplot as plt

        n = max(1, len(pol_cols))
        fig, axes = plt.subplots(n, 1, figsize=(10, 2.2 * n), sharex=True, squeeze=False)
        d = df.set_index("date")
        for ax, pol in zip(axes.ravel(), pol_cols or [None], strict=False):
            if pol is None:
                ax.axis("off")
                continue
            ax.plot(d.index, d[pol], lw=0.6, color="#2c7bb6")
            cov = d[pol].notna().mean() * 100
            ax.set_title(f"{pol} — {cov:.0f} % coverage", fontsize=9, loc="left")
            ax.grid(alpha=0.2)
        fig.tight_layout()
        self.tab_preview.show_result(
            fig,
            verdict=(
                ("ok", f"Fetched {len(df):,} hourly rows for {df['site'].iloc[0]}.")
                if len(df)
                else ("warn", "Empty result.")
            ),
            lines=[
                "Columns follow the modelling convention: met variables are "
                "auto-ticked as features in Step 1."
            ],
        )

    def _save_csv(self) -> None:
        if self.merged is None:
            return
        site = str(self.merged["site"].iloc[0]).replace(" ", "_") if len(self.merged) else "data"
        path, _ = QFileDialog.getSaveFileName(
            self, "Save merged CSV", f"normet_{site}.csv", "CSV (*.csv)"
        )
        if path:
            self.merged.to_csv(path, index=False)
            self.statusBar().showMessage(f"Saved {os.path.basename(path)}")
        # macOS returns focus to the parent (main) window after the file
        # dialog closes; keep this window in front.
        self.raise_()
        self.activateWindow()

    def _send_to_main(self) -> None:
        if self.merged is None or self._main is None:
            return
        self._main.ingest_dataframe(
            self.merged.copy(), f"Data Studio: {self.merged['site'].iloc[0]}"
        )
        self._main.raise_()
        self._main.activateWindow()
        self.statusBar().showMessage("Sent to the main window — continue with Step 1 there.")

    def closeEvent(self, event) -> None:  # noqa: N802
        self.runner.shutdown()
        self.bridge.cleanup()
        super().closeEvent(event)
