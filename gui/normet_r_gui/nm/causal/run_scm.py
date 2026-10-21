"""``run_scm`` for the copied ``bands`` module: the R package's ``nm_run_scm``."""

from __future__ import annotations

from typing import Any

from .. import _r
from ... import _rpc


def run_scm(df: Any, date_col: str, unit_col: str, outcome_col: str, treated_unit: str,
            cutoff_date: Any, donors: Any = None, scm_backend: str = "scm", **kwargs: Any) -> Any:
    out = _rpc.call(
        "nm_run_scm",
        df,
        date_col=date_col,
        unit_col=unit_col,
        outcome_col=outcome_col,
        treated_unit=treated_unit,
        cutoff_date=str(cutoff_date),
        donors=list(donors) if donors is not None else None,
        scm_backend=scm_backend,
        verbose=False,
    )
    return _r._dated(out)
