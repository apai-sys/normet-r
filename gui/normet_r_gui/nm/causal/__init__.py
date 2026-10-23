"""Synthetic control for the window: the R package's estimators and inference, in
normet-py's shapes.

The estimators, the placebo tests, the uncertainty bands and the batch over every unit
are R's (``nm_scm``, ``nm_scm_abadie``, ``nm_placebo_in_space`` …). What is arithmetic on
their results -- the diagnostics (``scm_diagnostics``, ``pre_trend_test``) and the bands
drawn from a placebo test's effects (``effect_bands_space``/``effect_bands_time``) -- and
the figures are normet-py's own, copied (``diagnostics.py``, ``prediagnostics.py``,
``bands.py``).
"""

from __future__ import annotations

from typing import Any

import pandas as pd

from ... import _rpc
from .. import _r
from .bands import (  # noqa: F401 - arithmetic and figures, normet-py's own
    effect_bands_space,
    effect_bands_time,
    plot_effect_with_bands,
    plot_event_study,
    plot_uncertainty_bands,
)
from .diagnostics import scm_diagnostics  # noqa: F401
from .prediagnostics import PreTrend, pre_trend_test  # noqa: F401
from .spatial import (  # noqa: F401 - arithmetic on coordinates, normet-py's own
    bearing,
    donor_spatial_summary,
    haversine,
    spatial_summary,
)


def _design(df: Any, date_col: str, unit_col: str, outcome_col: str, treated_unit: Any,
            cutoff_date: Any, donors: Any) -> dict[str, Any]:
    return {
        "date_col": date_col,
        "unit_col": unit_col,
        "outcome_col": outcome_col,
        "treated_unit": treated_unit,
        "cutoff_date": str(pd.Timestamp(cutoff_date).date()) if cutoff_date is not None else None,
        "donors": [str(d) for d in donors] if donors is not None else None,
    }


def _estimator(r_name: str, *keep: str):
    """A normet-py estimator over R's *r_name*; *keep* are the options passed on."""

    def fit(df: pd.DataFrame, date_col: str = "date", unit_col: str = "code",
            outcome_col: str = "poll", treated_unit: Any = None, cutoff_date: Any = None,
            donors: Any = None, **kwargs: Any) -> dict[str, Any]:
        res = _rpc.call(
            r_name,
            df,
            **_design(df, date_col, unit_col, outcome_col, treated_unit, cutoff_date, donors),
            **{k: kwargs[k] for k in keep if kwargs.get(k) is not None},
        )
        return _r._scm_result(res)

    fit.__name__ = r_name
    fit.__doc__ = f"``{r_name}``: ``synthetic`` (observed, synthetic, effect) and ``weights``."
    return fit


scm = _estimator("nm_scm", "allow_negative_weights", "alphas")
scm_abadie = _estimator("nm_scm_abadie", "allow_negative_weights")
did_baseline = _estimator("nm_did_baseline")
scm_mcnnm = _estimator("nm_scm_mcnnm", "lam", "max_iter", "tol")
scm_robust = _estimator("nm_scm_robust", "rank", "energy")


def mlscm(df: pd.DataFrame, date_col: str, outcome_col: str, unit_col: str, treated_unit: Any,
          donors: Any, cutoff_date: Any, backend: str = "lightgbm",
          model_config: dict[str, Any] | None = None, seed: int = 7_654_321,
          **_: Any) -> pd.DataFrame:
    """``nm_mlscm``: the synthetic table (observed, synthetic, effect), indexed by date."""
    res = _rpc.call(
        "nm_mlscm",
        df,
        **_design(df, date_col, unit_col, outcome_col, treated_unit, cutoff_date, donors),
        backend=backend,
        model_config=model_config,
        seed=seed,
        verbose=False,
    )
    out = _r._scm_result(res)
    return out["synthetic"]


def _mlscm_fit(df: pd.DataFrame, **kwargs: Any) -> dict[str, Any]:
    return {"synthetic": mlscm(df, **kwargs), "weights": None}


#: The estimators by the name the SCM Studio offers them under.
BACKENDS = {
    "scm": scm,
    "mlscm": _mlscm_fit,
    "abadie": scm_abadie,
    "did": did_baseline,
    "mcnnm": scm_mcnnm,
    "robust": scm_robust,
}


def bayesian_scm(df: pd.DataFrame, date_col: str = "date", unit_col: str = "code",
                 outcome_col: str = "poll", treated_unit: Any = None, cutoff_date: Any = None,
                 donors: Any = None, draws: int = 1000, **kwargs: Any) -> dict[str, Any]:
    """``nm_bayesian_scm``: ``synthetic`` with its credible bands, ``weights``."""
    res = _rpc.call(
        "nm_bayesian_scm",
        df,
        **_design(df, date_col, unit_col, outcome_col, treated_unit, cutoff_date, donors),
        draws=int(draws),
        verbose=False,
        **{k: kwargs[k] for k in ("burnin", "ci_level", "seed") if kwargs.get(k) is not None},
    )
    return _r._scm_result(res)


def _inference_options(kwargs: dict[str, Any]) -> dict[str, Any]:
    out = {k: kwargs[k] for k in ("scm_backend", "model_config", "post_agg") if kwargs.get(k) is not None}
    if kwargs.get("backend") is not None and kwargs.get("scm_backend") == "mlscm":
        # An ML-SCM's own model backend: R's inference functions pass it on to
        # nm_run_scm through `...`, and start H2O only when it is h2o.
        out["backend"] = kwargs["backend"]
    return out


def placebo_in_space(df: pd.DataFrame, date_col: str, unit_col: str, outcome_col: str,
                     treated_unit: Any, cutoff_date: Any, donors: Any = None,
                     **kwargs: Any) -> dict[str, Any]:
    """``nm_placebo_in_space``: treated, placebos (by unit), p_value, ref_band."""
    out = _rpc.call(
        "nm_placebo_in_space",
        df,
        **_design(df, date_col, unit_col, outcome_col, treated_unit, cutoff_date, donors),
        verbose=False,
        **_inference_options(kwargs),
    )
    return _r._dated_all(out)


def placebo_in_time(df: pd.DataFrame, date_col: str, unit_col: str, outcome_col: str,
                    treated_unit: Any, cutoff_date: Any, donors: Any = None,
                    min_pre_period: int | None = None, placebo_every: int | None = None,
                    **kwargs: Any) -> dict[str, Any]:
    """``nm_placebo_in_time``: the true cutoff's effect and each fake cutoff's."""
    out = _rpc.call(
        "nm_placebo_in_time",
        df,
        **_design(df, date_col, unit_col, outcome_col, treated_unit, cutoff_date, donors),
        min_pre_period=min_pre_period,
        placebo_every=placebo_every,
        verbose=False,
        **_inference_options(kwargs),
    )
    return _r._dated_all(out)


def uncertainty_bands(df: pd.DataFrame, date_col: str, unit_col: str, outcome_col: str,
                      treated_unit: Any, cutoff_date: Any, donors: Any = None,
                      method: str = "jackknife", B: int = 200, **kwargs: Any) -> dict[str, Any]:  # noqa: N803
    """``nm_uncertainty_bands``: treated, low, high (by date), and the draws."""
    out = _rpc.call(
        "nm_uncertainty_bands",
        df,
        **_design(df, date_col, unit_col, outcome_col, treated_unit, cutoff_date, donors),
        method=method,
        B=int(B),
        verbose=False,
        **_inference_options(kwargs),
    )
    out = _r._dated_all(out)
    for key in ("low", "high"):
        if key in out and not isinstance(out[key], pd.Series):
            out[key] = _r._series(out[key], name=key)
    return out


def scm_all(df: pd.DataFrame, date_col: str, outcome_col: str, unit_col: str, donors: Any,
            cutoff_date: Any, **kwargs: Any) -> pd.DataFrame:
    """``nm_scm_all``: every unit treated in turn."""
    out = _rpc.call(
        "nm_scm_all",
        df,
        date_col=date_col,
        outcome_col=outcome_col,
        unit_col=unit_col,
        donors=[str(d) for d in donors] if donors is not None else None,
        cutoff_date=str(pd.Timestamp(cutoff_date).date()),
        verbose=False,
        **_inference_options(kwargs),
    )
    return out
