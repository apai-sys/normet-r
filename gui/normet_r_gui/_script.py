"""A session script read back (File -> Load Session Script): what its calls set.

The script the command log writes (:mod:`.commandlog`) is R, run as it is to repeat the
session. Before it runs, its calls are read as written -- R parses it, without running
anything (``rpc.R``'s ``.gui_read_calls``) -- for what the panel should show afterwards:
the target and predictors the model was trained on, each step's settings. Each known
call's literal arguments are kept by the window's name for the step (``build_model``,
``normalise``...), as the window keeps what it ran (the Methods paragraph is written
from them); an argument that is a name (``df``, ``model``) is kept as None.

This is the R window's own module (normet-py's reads Python); the names and shapes it
hands back are normet-py's.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

import pandas as pd

from . import _rpc

#: The R functions a session script calls, by the window's name for the step.
KNOWN = {
    "nm_build_model": "build_model",
    "nm_normalise": "normalise",
    "nm_decompose": "decompose",
    "nm_rolling": "rolling",
    "nm_pdp": "pdp",
}

#: What the window's tasks return, by the name the script assigns it to.
RESULTS = {
    "normalised": "normalise",
    "decomposition": "decompose",
    "rolled": "rolling",
    "pd_values": "pdp",
}

CALENDAR = ("date_unix", "day_julian", "weekday", "hour")

#: normet-py's names for R's arguments, where they differ.
_PY_ARGS = {"resample_vars": "variables_resample"}

#: Arguments that are vectors in R: one value reads back from R as a bare value.
_VECTORS = {"covariates", "variables_resample", "var_list", "return_quantiles", "include_algos"}


def _as_list(v: Any) -> Any:
    return [v] if v is not None and not isinstance(v, list) else v


def _py_call(args: dict[str, Any]) -> dict[str, Any]:
    out: dict[str, Any] = {}
    for k, v in (args or {}).items():
        k = _PY_ARGS.get(k, k)
        if k in _VECTORS:
            v = _as_list(v)
        elif k == "groups" and isinstance(v, dict):
            v = {g: _as_list(m) for g, m in v.items()}
        elif k == "model_config" and isinstance(v, dict) and "include_algos" in v:
            v = {**v, "include_algos": _as_list(v["include_algos"])}
        out[k] = v
    out.setdefault("args", [])
    return out


def _script_file(text: str) -> Path:
    path = _rpc.session_dir() / "session_script.R"
    path.write_text(text, encoding="utf-8")
    return path


def read_calls(text: str) -> dict[str, dict[str, Any]]:
    """Each known call in ``text``, the last of each: its arguments by name (normet-py's
    names), and the multi-scale entry's rolling runs as ``compute_multiscale``. R that
    does not parse raises SyntaxError, in R's words."""
    try:
        got = _rpc.call(".gui_read_calls", str(_script_file(text)))
    except _rpc.RError as exc:
        raise SyntaxError(str(exc)) from None
    out: dict[str, dict[str, Any]] = {}
    for r_name, args in (got.get("calls") or {}).items():
        if r_name in KNOWN:
            out[KNOWN[r_name]] = _py_call(args)
    runs = [_py_call(a) for a in got.get("multiscale") or []]
    if runs:
        days = [r.get("window_days") for r in runs]
        ms = dict(runs[0])
        ms.update(zip(("fast_days", "meso_days", "slow_days"), days))
        out["compute_multiscale"] = ms
    return out


def config_from_calls(calls: dict[str, dict[str, Any]]) -> dict[str, Any]:
    """The panel's settings (as get_config writes them) the calls ran with."""
    c: dict[str, Any] = {}
    train = calls.get("build_model")
    if train:
        if isinstance(train.get("target"), str):
            c["target"] = train["target"]
        covs = train.get("covariates") or []
        c["features"] = [v for v in covs if v not in CALENDAR]
        c["backend"] = train.get("backend") or "lightgbm"
        for key in ("split_method", "train_fraction", "seed"):
            if train.get(key) is not None:
                c[key] = train[key]
        cfg = train.get("model_config") or {}
        if "max_runtime_secs" in cfg:
            c["time_budget"] = cfg["max_runtime_secs"]
        if cfg.get("include_algos"):
            c["flaml_estimators"] = list(cfg["include_algos"])  # the H2O algorithms' list
        if "n_trials" in cfg:
            c["lgb_trials"] = cfg["n_trials"]
    norm = calls.get("normalise")
    if norm:
        if norm.get("variables_resample"):
            c["norm_vars"] = list(norm["variables_resample"])
        if norm.get("n_samples") is not None:
            c["norm_samples"] = norm["n_samples"]
        c["norm_quantiles"] = bool(norm.get("return_quantiles"))
    dec = calls.get("decompose")
    if dec:
        c["decom_method"] = dec.get("method") or "emission"
        if dec.get("n_samples") is not None:
            c["decom_samples"] = dec["n_samples"]
        if dec.get("attribution"):
            c["decom_attribution"] = dec["attribution"]
        groups = dec.get("groups")
        if isinstance(groups, dict):
            c["decom_groups"] = "; ".join(f"{k}: {', '.join(v)}" for k, v in groups.items())
    roll = calls.get("rolling")
    if roll:
        for src, dst in (
            ("window_days", "roll_window"),
            ("rolling_every", "roll_step"),
            ("n_samples", "roll_samples"),
        ):
            if roll.get(src) is not None:
                c[dst] = roll[src]
    ms = calls.get("compute_multiscale")
    if ms:
        for src, dst in (
            ("fast_days", "ms_fast"),
            ("meso_days", "ms_meso"),
            ("slow_days", "ms_slow"),
        ):
            if ms.get(src) is not None:
                c[dst] = ms[src]
    pdp = calls.get("pdp")
    if pdp and pdp.get("grid_points") is not None:
        c["pdp_grid"] = pdp["grid_points"]
    return c


def _rolled(res: Any, df_prep: Any) -> pd.DataFrame | None:
    """A rolling run as the window's rolling() hands it back."""
    from .nm._r import rolling_shape

    return rolling_shape(res, df_prep) if isinstance(res, pd.DataFrame) else None


def _r_dated(df: pd.DataFrame) -> pd.DataFrame:
    from .nm._r import _dated

    return _dated(df)


def _multiscale(runs: dict[str, Any], df_prep: Any, y_inf: Any) -> dict[str, Any] | None:
    """The multi-scale result rebuilt from its rolling runs (``rolled_<days>``), as
    ``._multiscale.compute_multiscale`` makes it: each scale the windows' mean, the
    bands the differences of neighbouring scales and of the slowest from Y_inf."""
    from ._multiscale import MIN_WINDOWS

    scales: list[tuple[int, pd.Series | None, int]] = []
    for name, res in sorted(runs.items(), key=lambda kv: int(kv[0].split("_")[1])):
        rolled = _rolled(res, df_prep)
        cols = [c for c in rolled.columns if str(c).startswith("window_")] if rolled is not None else []
        series = rolled[cols].mean(axis=1, skipna=True) if len(cols) >= MIN_WINDOWS else None
        scales.append((int(name.split("_")[1]), series, len(cols)))
    if len(scales) != 3:
        return None

    def diff(a: pd.Series | None, b: pd.Series | None) -> pd.Series | None:
        if a is None or b is None:
            return None
        idx = a.index.intersection(b.index)
        d = (a.reindex(idx) - b.reindex(idx)).dropna()
        return d if len(d) else None

    (fd, fast, nf), (md, meso, nmeso), (sd, slow, ns) = scales
    return {
        "fast_days": fd,
        "meso_days": md,
        "slow_days": sd,
        "Y_fast": fast,
        "Y_meso": meso,
        "Y_slow": slow,
        "Y_inf": y_inf,
        "notes": [],
        "D_fast": diff(fast, meso),
        "D_meso": diff(meso, slow),
        "D_slow": diff(slow, y_inf),
        "n_fast": nf,
        "n_meso": nmeso,
        "n_slow": ns,
    }


def run_script(text: str, workdir: str | None = None) -> dict[str, Any]:
    """Run a session script in R and return what it made, by the names the log gives
    them (``df``, ``df_prep``, ``model``, ``normalised``, ...), shaped as the window's
    own steps hand them back. It runs as the analyst's own R does -- the window asks
    first -- in the folder it was saved in, so a CSV it reads by a relative path is
    found."""
    from .nm import _r

    made = _rpc.call(".gui_run_script", str(_script_file(text)), workdir=workdir) or {}
    out: dict[str, Any] = {}
    df_prep = made.get("df_prep")
    for key in ("df", "df_prep", "pd_values"):
        if isinstance(made.get(key), pd.DataFrame):
            out[key] = made[key]
    if made.get("model") is not None:
        out["model"] = _r.RModel.of(made["model"])
    for key in ("normalised", "decomposition"):
        if isinstance(made.get(key), pd.DataFrame):
            out[key] = _r_dated(made[key])
    rolled = _rolled(made.get("rolled"), df_prep)
    if rolled is not None:
        out["rolled"] = rolled
    if isinstance(made.get("multiscale"), dict):
        y_inf = out["normalised"]["normalised"] if "normalised" in out else None
        ms = _multiscale(made["multiscale"], df_prep, y_inf)
        if ms is not None:
            out["multiscale"] = ms
    return out
