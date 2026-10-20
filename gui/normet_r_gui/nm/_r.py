"""normet-py's analysis functions, each the normet R package's, called through Rscript.

Every function takes what normet-py's takes -- the same names, so the window's calls
are normet-py's own -- passes the R function the arguments it has (named as R names
them), and hands back what normet-py's hands back: a table indexed by ``date``, a
``(df_prep, model)`` pair, an SCM result's ``synthetic`` table and ``weights`` series.
Arguments R has no counterpart for (normet-py's own tuning) are left out; the docstring
of each says which.
"""

from __future__ import annotations

import functools
import logging
import threading
from collections.abc import Iterable, Mapping
from pathlib import Path
from typing import Any

import numpy as np
import pandas as pd

from .. import _rpc
from .._rpc import RObject

log = logging.getLogger(__name__)

#: The backends the R package trains with; normet-py's flaml has no R counterpart.
BACKENDS = ("lightgbm", "h2o")

_h2o = {"used": False}


def used_h2o() -> bool:
    """Whether an H2O cluster was started (its JVM outlives each R call)."""
    return _h2o["used"]


def _note_backend(backend: Any) -> None:
    if isinstance(backend, str) and backend.startswith("h2o"):
        _h2o["used"] = True


# -- shapes ------------------------------------------------------------------------------


def _dated(df: Any) -> Any:
    """A table with its ``date`` column as its index, as normet-py's results are."""
    if isinstance(df, pd.DataFrame) and "date" in df.columns:
        out = df.set_index(pd.DatetimeIndex(pd.to_datetime(df["date"]), name="date"))
        return out.drop(columns="date")
    return df


def _series(values: Any, name: str | None = None) -> pd.Series:
    """A named vector from R (a dict, a list) as a Series; dates for keys where they are."""
    if isinstance(values, pd.Series):
        return values
    if isinstance(values, Mapping):
        keys = list(values.keys())
        idx: Any = keys
        try:
            parsed = pd.to_datetime(keys, errors="raise")
            idx = pd.DatetimeIndex(parsed, name="date")
        except (ValueError, TypeError):
            pass
        return pd.Series(list(values.values()), index=idx, name=name, dtype=float)
    if values is None:
        return pd.Series(dtype=float, name=name)
    return pd.Series(np.atleast_1d(values), name=name, dtype=float)


def _dated_all(obj: Any) -> Any:
    """Every table in a result (a dict of tables, tables of tables) indexed by date."""
    if isinstance(obj, pd.DataFrame):
        return _dated(obj)
    if isinstance(obj, dict):
        return {k: _dated_all(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [_dated_all(v) for v in obj]
    return obj


def _scm_result(res: Any) -> dict[str, Any]:
    """An estimator's result as normet-py's: ``synthetic`` (indexed by date: observed,
    synthetic, effect) and ``weights`` (a Series named weight, by donor) at least."""
    if isinstance(res, pd.DataFrame):
        res = {"synthetic": res}
    out = dict(res)
    out["synthetic"] = _dated(out.get("synthetic"))
    w = out.get("weights")
    if w is not None and not isinstance(w, pd.Series):
        out["weights"] = pd.Series(w if isinstance(w, Mapping) else {}, name="weight", dtype=float)
    if isinstance(out.get("weights"), pd.Series):
        out["weights"].name = "weight"
    if "alpha" in out and isinstance(out["alpha"], Mapping):
        out["alpha"] = {pd.Timestamp(k): v for k, v in out["alpha"].items()}
    return out


def _kept(kwargs: dict[str, Any], *names: str) -> dict[str, Any]:
    return {k: kwargs[k] for k in names if kwargs.get(k) is not None}


# -- the version -------------------------------------------------------------------------


@functools.cache
def r_check() -> dict[str, Any]:
    """normet's and R's versions, and which backends load."""
    return _rpc.call(".gui_check")


def r_version() -> str:
    try:
        return str(r_check()["normet"])
    except Exception:  # noqa: BLE001 - R not there yet: the window still opens
        return "(R not found)"


# -- a model -----------------------------------------------------------------------------


class RModel(RObject):
    """A model trained in R, saved in the session's folder: what normet-py's models
    answer to (``feature_names``, ``feature_importance()``, ``predict``)."""

    @classmethod
    def of(cls, obj: RObject) -> RModel:
        return cls(obj.path, dict(obj.info))

    def feature_importance(self) -> list[float]:
        """Each feature's importance, in ``feature_names``' order (total gain for a
        LightGBM booster)."""
        fi = _rpc.call(".gui_importance", self)
        if fi is None or not len(fi):
            return [0.0 for _ in self.feature_names]
        by = dict(zip(fi["variable"].astype(str), fi["relative_importance"].astype(float), strict=False))
        return [float(by.get(f, 0.0)) for f in self.feature_names]

    def predict(self, newdata: pd.DataFrame) -> np.ndarray:
        return ml_predict(self, newdata)


def _model(obj: Any) -> RModel:
    return obj if isinstance(obj, RModel) else RModel.of(obj)


# -- training ----------------------------------------------------------------------------


def prepare_data(
    df: pd.DataFrame,
    target: str,
    covariates: list[str],
    dropna: bool = True,
    split_method: str = "random",
    train_fraction: float = 0.75,
    seed: int = 7654321,
) -> pd.DataFrame:
    """``nm_prepare_data``: the target as ``value``, the time features, a ``set`` column."""
    return _rpc.call(
        "nm_prepare_data",
        df,
        target=target,
        covariates=list(covariates),
        dropna=dropna,
        split_method=split_method,
        train_fraction=train_fraction,
        seed=seed,
    )


def build_model(
    df: pd.DataFrame,
    target: str,
    *,
    backend: str = "lightgbm",
    covariates: list[str] | None = None,
    split_method: str = "random",
    train_fraction: float = 0.75,
    model_config: dict[str, Any] | None = None,
    seed: int = 7654321,
    verbose: bool = False,
    **_ignored: Any,
) -> tuple[pd.DataFrame, RModel]:
    """``nm_build_model``: ``(df_prep, model)``."""
    _note_backend(backend)
    out = _rpc.call(
        "nm_build_model",
        df,
        target=target,
        backend=backend,
        covariates=list(covariates or []),
        split_method=split_method,
        train_fraction=train_fraction,
        model_config=model_config,
        seed=seed,
        verbose=verbose,
    )
    return out["df_prep"], _model(out["model"])


def ml_predict(model: Any, newdata: pd.DataFrame, **_ignored: Any) -> np.ndarray:
    """The model's predictions for *newdata*."""
    return np.asarray(_rpc.call(".gui_predict", model, newdata), dtype=float)


def modStats(  # noqa: N802 - normet-py's name
    df: pd.DataFrame,
    model: Any,
    subset: str | None = None,
    statistic: list[str] | None = None,
    **_ignored: Any,
) -> pd.DataFrame:
    """``nm_modStats``: one row per set (training, testing, all)."""
    return _rpc.call("nm_modStats", df, model, subset=subset, statistic=statistic)


# -- the analyses ------------------------------------------------------------------------


def normalise(
    df: pd.DataFrame,
    model: Any,
    *,
    covariates: list[str] | None = None,
    variables_resample: list[str] | None = None,
    n_samples: int = 300,
    n_cores: int | None = None,
    seed: int = 7654321,
    return_quantiles: Iterable[float] | None = None,
    verbose: bool = False,
    **_ignored: Any,
) -> pd.DataFrame:
    """``nm_normalise``: observed and normalised (and ``q05``… for return_quantiles),
    indexed by date."""
    out = _rpc.call(
        "nm_normalise",
        df,
        model,
        resample_vars=list(variables_resample) if variables_resample else None,
        n_samples=int(n_samples),
        n_cores=n_cores,
        seed=seed,
        return_quantiles=list(return_quantiles) if return_quantiles else None,
        verbose=verbose,
    )
    return _dated(out)


def decompose(
    df: pd.DataFrame,
    model: Any | None = None,
    *,
    method: str = "emission",
    covariates: list[str] | None = None,
    n_samples: int = 300,
    seed: int = 7654321,
    groups: Mapping[str, list[str]] | None = None,
    attribution: str | None = None,
    n_permutations: int | None = None,
    target: str = "value",
    verbose: bool = False,
    **_ignored: Any,
) -> pd.DataFrame:
    """``nm_decompose``: its components, indexed by date."""
    out = _rpc.call(
        "nm_decompose",
        method,
        df=df,
        model=model,
        target=target,
        covariates=list(covariates) if covariates else None,
        n_samples=int(n_samples),
        seed=seed,
        groups={k: list(v) for k, v in groups.items()} if groups else None,
        attribution=attribution,
        n_permutations=n_permutations,
        verbose=verbose,
    )
    return _dated(out)


def rolling(
    df: pd.DataFrame | None = None,
    model: Any | None = None,
    *,
    covariates: list[str] | None = None,
    variables_resample: list[str] | None = None,
    window_days: int = 14,
    rolling_every: int = 7,
    n_samples: int = 300,
    seed: int = 7654321,
    n_cores: int | None = None,
    verbose: bool = False,
    **_ignored: Any,
) -> pd.DataFrame:
    """``nm_rolling``: one ``rolling_<i>`` column per window, indexed by date."""
    out = _rpc.call(
        "nm_rolling",
        df,
        model=model,
        covariates=list(covariates) if covariates else None,
        resample_vars=list(variables_resample) if variables_resample else None,
        window_days=int(window_days),
        rolling_every=int(rolling_every),
        n_samples=int(n_samples),
        seed=seed,
        n_cores=n_cores,
        verbose=verbose,
    )
    return _dated(out)


def pdp(
    df: pd.DataFrame,
    model: Any,
    *,
    var_list: list[str] | None = None,
    grid_points: int = 50,
    n_cores: int | None = None,
    verbose: bool = False,
    **_ignored: Any,
) -> pd.DataFrame:
    """``nm_pdp``: variable, value, pdp_mean, pdp_std."""
    return _rpc.call(
        "nm_pdp",
        df,
        model,
        var_list=list(var_list) if var_list else None,
        grid_points=int(grid_points),
        n_cores=n_cores,
        verbose=verbose,
    )


# -- data --------------------------------------------------------------------------------


def list_ukaq_stations(
    source: str = "aurn", pollutant: Any = None, site_type: Any = None, all_variables: bool = False
) -> pd.DataFrame:
    return _rpc.call(
        "nm_list_ukaq_stations",
        source=source,
        pollutant=pollutant,
        site_type=site_type,
        all_variables=all_variables,
    )


def fetch_ukaq_measurements(
    site: Any, year: Any, source: str = "aurn", pollutant: Any = None, on_missing: str = "warn", **_: Any
) -> pd.DataFrame:
    years = [int(y) for y in np.atleast_1d(year)]
    return _rpc.call(
        "nm_fetch_ukaq_measurements",
        site=site,
        year=years,
        source=source,
        pollutant=list(np.atleast_1d(pollutant)) if pollutant is not None else None,
        on_missing=on_missing,
    )


def _sites(sites: Any) -> Any:
    """normet-py's ``{name: (lat, lon)}`` as R's site table."""
    if isinstance(sites, Mapping):
        return pd.DataFrame(
            {
                "site": list(sites.keys()),
                "lat": [float(v[0]) for v in sites.values()],
                "lon": [float(v[1]) for v in sites.values()],
            }
        )
    return sites


def fetch_openmeteo_timeseries(sites: Any, date_from: str, date_to: str, variables: Any = None, **_: Any) -> pd.DataFrame:
    return _rpc.call(
        "nm_fetch_openmeteo_timeseries",
        sites=_sites(sites),
        date_from=str(date_from),
        date_to=str(date_to),
        variables=variables,
    )


def fetch_era5_timeseries(sites: Any, date_from: str, date_to: str, variables: Any = None, **_: Any) -> pd.DataFrame:
    return _rpc.call(
        "nm_fetch_era5_timeseries",
        sites=_sites(sites),
        date_from=str(date_from),
        date_to=str(date_to),
        variables=variables,
    )


def gdas1_filenames(date_from: Any, date_to: Any) -> list[str]:
    """The weekly GDAS1 files a date range touches (computed here: names only)."""
    from .io.gdas import gdas1_filenames as names

    return list(names(date_from, date_to))


def fetch_gdas1(date_from: Any, date_to: Any, cache_dir: str, on_missing: str = "warn", **_: Any) -> list[str]:
    out = _rpc.call(
        "nm_fetch_gdas1",
        date_from=str(pd.Timestamp(date_from).date()),
        date_to=str(pd.Timestamp(date_to).date()),
        cache_dir=str(Path(cache_dir).expanduser()),
        on_missing=on_missing,
    )
    return [str(p) for p in np.atleast_1d(out)] if out is not None else []


# -- trajectories ------------------------------------------------------------------------


class SourceRegion:
    """A region read from a vector file (GeoJSON, Shapefile…): R reads it again, by its
    file and name, when the features are built."""

    def __init__(self, path: str, name: str) -> None:
        self.path, self.name = path, name

    def __repr__(self) -> str:
        return f"<region {self.name} of {Path(self.path).name}>"


def load_source_regions(path: str) -> dict[str, SourceRegion]:
    """``nm_load_source_regions``: the regions a file names, by name."""
    names = _rpc.call(".gui_region_names", str(path))
    return {str(n): SourceRegion(str(path), str(n)) for n in np.atleast_1d(names)}


def _regions(source_regions: Mapping[str, Any] | None) -> dict[str, Any] | None:
    """Boxes as ``c(lon_min, lat_min, lon_max, lat_max)``, file regions by file and name."""
    if not source_regions:
        return None
    out: dict[str, Any] = {}
    for name, region in source_regions.items():
        if isinstance(region, SourceRegion):
            out[name] = {"__region_file__": region.path, "name": region.name}
        else:
            out[name] = [float(v) for v in region]
    return out


def build_trajectory_features(
    tdumps: Any,
    source_regions: Mapping[str, Any] | None = None,
    prefix: str = "traj_",
    min_hours: float | None = None,
    date_col: str = "date",
) -> pd.DataFrame:
    """``nm_build_trajectory_features``: indexed by receptor time."""
    paths = [tdumps] if isinstance(tdumps, str) else [str(p) for p in tdumps]
    out = _rpc.call(
        ".gui_build_trajectory_features",
        paths,
        regions=_regions(source_regions),
        prefix=prefix,
        min_hours=min_hours,
        date_col=date_col,
    )
    return _dated(out) if isinstance(out, pd.DataFrame) and len(out) else pd.DataFrame()


def run_back_trajectories(
    times: Iterable[Any],
    lat: float,
    lon: float,
    met_files: Any,
    hysplit_exec: str,
    height_m: float = 500.0,
    hours_back: int = 72,
    work_dir: str | None = None,
    diagnostics: Iterable[str] | None = None,
    source_regions: Mapping[str, Any] | None = None,
    prefix: str = "traj_",
    min_hours: float | None = None,
    timeout: int = 600,
    stop: threading.Event | None = None,
    **_: Any,
) -> pd.DataFrame:
    """``nm_run_back_trajectories``; setting *stop* stops the R run in progress."""
    watcher = None
    if stop is not None:
        done = threading.Event()

        def watch() -> None:
            while not done.wait(0.3):
                if stop.is_set():
                    _rpc.cancel()
                    return

        watcher = threading.Thread(target=watch, daemon=True)
        watcher.start()
    stamps = [pd.Timestamp(t) for t in times]
    stamps = [t.tz_convert("UTC").tz_localize(None) if t.tzinfo else t for t in stamps if not pd.isna(t)]
    try:
        out = _rpc.call(
            ".gui_run_back_trajectories",
            stamps,
            lat=float(lat),
            lon=float(lon),
            met_files=[str(m) for m in np.atleast_1d(met_files)],
            hysplit_exec=str(hysplit_exec),
            height_m=float(height_m),
            hours_back=int(hours_back),
            work_dir=work_dir,
            diagnostics=list(diagnostics) if diagnostics is not None else None,
            regions=_regions(source_regions),
            prefix=prefix,
            min_hours=min_hours,
            timeout=int(timeout),
        )
    except _rpc.RError:
        if stop is not None and stop.is_set():
            return pd.DataFrame()
        raise
    finally:
        if watcher is not None:
            done.set()
    return _dated(out) if isinstance(out, pd.DataFrame) and len(out) else pd.DataFrame()


# -- a run and its report ----------------------------------------------------------------


def make_run(
    result: Any = None,
    kind: str = "run",
    config: Mapping[str, Any] | None = None,
    df: pd.DataFrame | None = None,
    df_prep: pd.DataFrame | None = None,
    model: Any = None,
    seed: int | None = None,
    **_: Any,
) -> RObject:
    """``nm_make_run``: a result with its provenance, kept in R."""
    res = result.reset_index() if isinstance(result, pd.DataFrame) and result.index.name == "date" else result
    return _rpc.call(
        "nm_make_run",
        res,
        kind=kind,
        config=dict(config) if config else None,
        df=df,
        df_prep=df_prep,
        model=model,
        seed=seed,
    )


def generate_html_report(run: RObject, out_path: str, *, title: str | None = None, lang: str = "en", **_: Any) -> Path:
    """``nm_generate_html``: the run's single-file HTML report."""
    _rpc.call("nm_generate_html", run, out_path=str(out_path), title=title, lang=lang)
    return Path(out_path)
