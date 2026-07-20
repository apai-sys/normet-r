"""Subprocess bridge between the Qt GUI and the normet R package.

Each analysis step runs ``Rscript bridge.R <task> <session_dir> key=value…``
in a fresh R process.  Data crosses the boundary as CSV files inside a
per-GUI-session temp directory; the trained model persists there via
``nm_save_model`` so later tasks can reload it.
"""

from __future__ import annotations

import logging
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import pandas as pd

log = logging.getLogger(__name__)


def _bridge_r_path() -> Path:
    """Locate bridge.R both in a normal install and inside a PyInstaller app."""
    candidates = [Path(__file__).resolve().parent / "bridge.R"]
    if getattr(sys, "frozen", False):  # PyInstaller: data lands under _MEIPASS
        candidates.append(Path(getattr(sys, "_MEIPASS", "")) / "normet_r_gui" / "bridge.R")
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    return candidates[0]


BRIDGE_R = _bridge_r_path()


class RBridgeError(RuntimeError):
    """Raised when the R subprocess fails; carries its captured output."""


def find_rscript() -> str | None:
    """Locate Rscript on PATH or in the usual macOS install locations."""
    found = shutil.which("Rscript")
    if found:
        return found
    for candidate in (
        "/usr/local/bin/Rscript",
        "/opt/homebrew/bin/Rscript",
        "/Library/Frameworks/R.framework/Resources/bin/Rscript",
    ):
        if Path(candidate).is_file():
            return candidate
    return None


def _fmt(value) -> str:
    if isinstance(value, (list, tuple)):
        return ",".join(str(v) for v in value)
    return str(value)


class RBridge:
    """One GUI session's connection to R: a temp dir plus Rscript calls."""

    def __init__(self, rscript: str | None = None) -> None:
        self.rscript = rscript or find_rscript()
        self.session_dir = Path(tempfile.mkdtemp(prefix="normet_gui_"))
        self._h2o_used = False
        log.info("R session directory: %s", self.session_dir)

    # ------------------------------------------------------------- plumbing
    def _run(self, task: str, **params) -> str:
        if not self.rscript:
            raise RBridgeError(
                "Rscript not found. Install R (https://cran.r-project.org) or "
                "set its path via R → Locate Rscript…"
            )
        cmd = [self.rscript, str(BRIDGE_R), task, str(self.session_dir)]
        cmd += [f"{k}={_fmt(v)}" for k, v in params.items() if v is not None]
        if params.get("backend") == "h2o":
            # The h2o JVM outlives each Rscript call; remember to shut it
            # down when the GUI session ends (see cleanup()).
            self._h2o_used = True
        log.info("R> %s", " ".join(cmd[2:]))

        proc = subprocess.run(cmd, capture_output=True, text=True)
        output = (proc.stdout or "") + (proc.stderr or "")
        for line in output.strip().splitlines():
            log.info("[R] %s", line)
        if proc.returncode != 0 or "BRIDGE_OK" not in (proc.stdout or ""):
            raise RBridgeError(f"R task '{task}' failed:\n{output[-2000:]}")
        return proc.stdout

    def _read(self, name: str = "result.csv", dates: bool = True) -> pd.DataFrame:
        path = self.session_dir / name
        if not path.is_file():
            return pd.DataFrame()
        df = pd.read_csv(path)
        if dates and "date" in df.columns:
            # "mixed" tolerates date-only rows alongside full timestamps.
            df["date"] = pd.to_datetime(df["date"], format="mixed")
        return df

    def _meta(self) -> dict[str, str]:
        path = self.session_dir / "meta.txt"
        out: dict[str, str] = {}
        if path.is_file():
            for line in path.read_text().splitlines():
                if "=" in line:
                    k, v = line.split("=", 1)
                    out[k] = v
        return out

    def _write_input(self, df: pd.DataFrame) -> None:
        out = df.copy()
        if "date" in out.columns:
            out["date"] = pd.to_datetime(out["date"]).dt.strftime("%Y-%m-%d %H:%M:%S")
        out.to_csv(self.session_dir / "data.csv", index=False)

    def cleanup(self) -> None:
        if self._h2o_used and self.rscript:
            try:
                subprocess.run(
                    [self.rscript, str(BRIDGE_R), "shutdown_h2o", str(self.session_dir)],
                    capture_output=True,
                    timeout=30,
                )
            except Exception:
                pass
        shutil.rmtree(self.session_dir, ignore_errors=True)

    # ------------------------------------------------------------ workflow
    def check(self) -> str:
        """Return a version banner, e.g. 'normet 0.1.0 | lightgbm yes | h2o yes'."""
        return self._run("check").strip().splitlines()[-2]

    def train(
        self,
        df: pd.DataFrame,
        *,
        target: str,
        covariates: list[str],
        backend: str = "lightgbm",
        split_method: str = "random",
        train_fraction: float = 0.75,
        seed: int = 7_654_321,
        n_trials: int | None = None,
        max_runtime_secs: int | None = None,
        include_algos: list[str] | None = None,
    ) -> dict:
        """nm_build_model → {'df_prep', 'stats', 'importance'}."""
        self._write_input(df)
        self._run(
            "train",
            target=target,
            covariates=covariates,
            backend=backend,
            split_method=split_method,
            train_fraction=train_fraction,
            seed=seed,
            n_trials=n_trials,
            max_runtime_secs=max_runtime_secs,
            include_algos=include_algos,
        )
        return {
            "df_prep": self._read("df_prep.csv"),
            "stats": self._read("stats.csv", dates=False),
            "importance": self._read("importance.csv", dates=False),
        }

    def normalise(
        self,
        *,
        resample_vars: list[str],
        backend: str,
        n_samples: int = 300,
        n_cores: int | None = None,
        seed: int = 7_654_321,
        return_quantiles: list[float] | None = None,
    ) -> pd.DataFrame:
        self._run(
            "normalise",
            resample_vars=resample_vars,
            backend=backend,
            n_samples=n_samples,
            n_cores=n_cores,
            seed=seed,
            return_quantiles=return_quantiles,
        )
        return self._read()

    def decompose(
        self,
        *,
        method: str,
        covariates: list[str],
        backend: str,
        n_samples: int = 300,
        seed: int = 7_654_321,
    ) -> pd.DataFrame:
        self._run(
            "decompose",
            method=method,
            covariates=covariates,
            backend=backend,
            n_samples=n_samples,
            seed=seed,
        )
        return self._read()

    def pdp(self, *, var_list: list[str], backend: str) -> pd.DataFrame:
        self._run("pdp", var_list=var_list, backend=backend)
        return self._read()

    def rolling(
        self,
        *,
        covariates: list[str],
        resample_vars: list[str] | None,
        backend: str,
        window_days: int = 14,
        rolling_every: int = 7,
        n_samples: int = 100,
        seed: int = 7_654_321,
    ) -> pd.DataFrame:
        self._run(
            "rolling",
            covariates=covariates,
            resample_vars=resample_vars,
            backend=backend,
            window_days=window_days,
            rolling_every=rolling_every,
            n_samples=n_samples,
            seed=seed,
        )
        return self._read()

    # ------------------------------------------------------------------ SCM
    def scm_fit(self, df: pd.DataFrame, design: dict, **extra) -> dict:
        """nm_scm / nm_run_scm → {'synthetic', 'weights', 'diagnostics'}."""
        self._write_input(df)
        self._run("scm_fit", **design, **extra)
        synth = self._read().set_index("date")
        weights = self._read("weights.csv", dates=False)
        meta = self._meta()
        diagnostics: dict = {}
        for k, v in meta.items():
            if k == "top_donors":
                pairs = [p.split(":") for p in v.split(";") if ":" in p]
                diagnostics["top_donors"] = [(n, float(w)) for n, w in pairs]
            else:
                try:
                    diagnostics[k] = float(v)
                except ValueError:
                    diagnostics[k] = v
        return {
            "synthetic": synth,
            "weights": weights if len(weights) else None,
            "diagnostics": diagnostics or None,
        }

    def placebo_space(self, df: pd.DataFrame, design: dict) -> dict:
        self._write_input(df)
        self._run("placebo_space", **design)
        meta = self._meta()
        return {
            "treated": self._read("treated.csv").set_index("date"),
            "placebos": self._read("placebos.csv"),
            "bands": self._read("bands.csv").set_index("date"),
            "p_value": float(meta.get("p_value", "nan")),
        }

    def placebo_time(self, df: pd.DataFrame, design: dict, *, min_pre_period: int, placebo_every: int) -> dict:
        self._write_input(df)
        self._run(
            "placebo_time", **design, min_pre_period=min_pre_period, placebo_every=placebo_every
        )
        meta = self._meta()
        n_placebos = int(float(meta.get("n_placebos", "0")))
        out = {
            "treated": self._read("treated.csv").set_index("date"),
            "p_value": float(meta.get("p_value", "nan")),
            "n_placebos": n_placebos,
            "bands": None,
            "segments": None,
        }
        if n_placebos > 0:
            bands = self._read("bands.csv", dates=False)
            if "step" in bands.columns:
                bands = bands.set_index("step")
            out["bands"] = bands
            segments = self._read("segments.csv", dates=False)
            if len(segments):
                if "step" in segments.columns:
                    segments = segments.set_index("step")
                out["segments"] = segments
        return out

    def uncertainty(self, df: pd.DataFrame, design: dict, *, method: str, B: int) -> pd.DataFrame | None:
        self._write_input(df)
        self._run("uncertainty", **design, method=method, B=B)
        if self._meta().get("ok") != "1":
            return None
        return self._read().set_index("date")

    def scm_all(self, df: pd.DataFrame, design: dict) -> pd.DataFrame:
        self._write_input(df)
        self._run("scm_all", **design)
        return self._read()

    # ----------------------------------------------------------- Data Studio
    def find_stations(self, pollutants: list[str]) -> pd.DataFrame:
        """One row per (station, pollutant) with id/label/lat/lon."""
        self._run("find_stations", pollutants=pollutants)
        return self._read(dates=False)

    def fetch_merge(
        self,
        *,
        pollutants: list[str],
        station_id: str,
        site_name: str,
        lat: float,
        lon: float,
        date_from: str,
        date_to: str,
        met_source: str,
    ) -> pd.DataFrame:
        self._run(
            "fetch_merge",
            pollutants=pollutants,
            station_id=station_id,
            site_name=site_name.replace("=", " ").replace(",", " "),
            lat=lat,
            lon=lon,
            date_from=date_from,
            date_to=date_to,
            met_source=met_source,
        )
        return self._read()

    # ---------------------------------------------------------- Transport Studio
    @staticmethod
    def _fmt_regions(regions: dict[str, tuple[float, float, float, float]] | None) -> str | None:
        if not regions:
            return None
        return ";".join(f"{name}:{':'.join(str(v) for v in box)}" for name, box in regions.items())

    @staticmethod
    def _fmt_region_files(
        region_files: list[tuple[str, str]] | None,
    ) -> tuple[list[str] | None, list[str] | None]:
        """(name, path) pairs -> parallel comma-joined lists for the bridge CLI."""
        if not region_files:
            return None, None
        names, paths = zip(*region_files, strict=True)
        return list(names), list(paths)

    def build_trajectory_features(
        self,
        tdumps: list[str],
        *,
        source_regions: dict[str, tuple[float, float, float, float]] | None = None,
        region_files: list[tuple[str, str]] | None = None,
        site: str | None = None,
        prefix: str = "traj_",
    ) -> pd.DataFrame:
        """nm_build_trajectory_features → date-indexed transport feature table."""
        names, paths = self._fmt_region_files(region_files)
        self._run(
            "traj_build",
            tdumps=tdumps,
            regions=self._fmt_regions(source_regions),
            region_file_names=names,
            region_file_paths=paths,
            site=site,
            prefix=prefix,
        )
        return self._read().set_index("date")

    def fetch_gdas1(self, date_from: str, date_to: str, cache_dir: str) -> list[str]:
        """nm_fetch_gdas1 → local paths of the downloaded/cached ARL files."""
        self._run("gdas_fetch", date_from=date_from, date_to=date_to, cache_dir=cache_dir)
        return self._read("gdas_paths.csv", dates=False)["path"].tolist()

    def run_back_trajectories(
        self,
        times: list[pd.Timestamp],
        lat: float,
        lon: float,
        *,
        met_files: list[str],
        hysplit_exec: str,
        height_m: float = 500.0,
        hours_back: int = 72,
        diagnostics: list[str] | None = None,
        source_regions: dict[str, tuple[float, float, float, float]] | None = None,
        region_files: list[tuple[str, str]] | None = None,
        prefix: str = "traj_",
    ) -> pd.DataFrame:
        """nm_run_back_trajectories → date-indexed transport feature table."""
        times_path = self.session_dir / "receptor_times.txt"
        times_path.write_text(
            "\n".join(pd.Timestamp(t).strftime("%Y-%m-%d %H:%M:%S") for t in times)
        )
        names, paths = self._fmt_region_files(region_files)
        self._run(
            "traj_run",
            lat=lat,
            lon=lon,
            met_files=met_files,
            hysplit_exec=hysplit_exec,
            height_m=height_m,
            hours_back=hours_back,
            diagnostics=diagnostics,
            regions=self._fmt_regions(source_regions),
            region_file_names=names,
            region_file_paths=paths,
            prefix=prefix,
        )
        return self._read().set_index("date")
