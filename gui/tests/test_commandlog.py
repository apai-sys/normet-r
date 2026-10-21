"""The command log in R (normet_r_gui.commandlog), its script read back (._script), and
what the window keeps of R between sessions (._rpc.RObject pickled with its files)."""

from __future__ import annotations

import logging
import pickle
import shutil
import subprocess

import pandas as pd
import pytest

from normet_r_gui import _rpc, _script
from normet_r_gui import commandlog as C
from normet_r_gui._multiscale import compute_multiscale
from normet_r_gui.nm import _r


@pytest.mark.parametrize(
    ("value", "r"),
    [
        (None, "NULL"),
        (True, "TRUE"),
        (300, "300"),
        (0.1 + 0.2, "0.3"),
        (float("nan"), "NA"),
        (float("-inf"), "-Inf"),
        ('a "quoted" path', '"a \\"quoted\\" path"'),
        (["ws", "temp"], 'c("ws", "temp")'),
        ([0.05, 0.95], "c(0.05, 0.95)"),
        ({"n_trials": 10}, "list(n_trials = 10)"),
        ({"Temperature and humidity": ["temp", "RH"]}, 'list(`Temperature and humidity` = c("temp", "RH"))'),
    ],
)
def test_literals_are_r(value, r):
    assert C.literal(value) == r


def test_long_calls_wrap_under_the_bracket():
    code = C.call("normalised", "nm_normalise", ["df_prep", "model"], [(f"arg{i}", "1") for i in range(12)])
    lines = code.splitlines()
    assert lines[0].startswith("normalised <- nm_normalise(df_prep, model,")
    assert all(len(line) <= C.WIDTH for line in lines)
    assert all(line.startswith(" " * len("normalised <- nm_normalise(")) for line in lines[1:])


@pytest.fixture
def held():
    df = pd.DataFrame({"date": pd.date_range("2020-01-01", periods=24 * 200, freq="h"), "NO2": 1.0, "ws": 2.0})
    df_prep = df.rename(columns={"NO2": "value"})
    model = _r.RModel("/nowhere", {"backend": "lightgbm", "features": ["ws"]})
    return df, df_prep, model, [(df, "df"), (df_prep, "df_prep"), (model, "model")]


def test_a_task_is_written_as_the_r_call_it_makes(held):
    df, df_prep, model, names = held
    entry = C.task(
        _r.build_model,
        (df, "NO2"),
        {"backend": "lightgbm", "covariates": ["ws", "hour"], "model_config": {"n_trials": 5}, "seed": 1},
        names,
    )
    assert entry.title == "Train model"
    assert entry.code.startswith('res <- nm_build_model(df, target = "NO2", backend = "lightgbm"')
    assert entry.code.endswith("df_prep <- res$df_prep\nmodel <- res$model")
    norm = C.task(_r.normalise, (df_prep, model), {"variables_resample": ["ws"], "n_samples": 50}, names)
    # R's own argument names, and the tables and the model by the names the script gives them.
    assert norm.code.startswith('normalised <- nm_normalise(df_prep, model, resample_vars = c("ws"), n_samples = 50')


def test_the_multi_scale_helper_is_written_as_its_rolling_runs(held):
    _df, df_prep, model, names = held
    entry = C.task(
        compute_multiscale,
        (),
        {"df_prep": df_prep, "model": model, "covariates": ["ws"], "variables_resample": ["ws"],
         "y_inf": None, "fast_days": 14, "meso_days": 60, "slow_days": 120, "n_samples": 10},
        names,
    )
    lines = [line for line in entry.code.splitlines() if "<- nm_rolling(" in line]
    assert [line.split(" <- ")[0] for line in lines] == ["rolled_14", "rolled_60", "rolled_120"]
    assert entry.notes


def test_a_dry_run_says_nothing_in_the_log(held, caplog):
    """The multi-scale helper, run on empty answers, would log every scale skipped."""
    _df, df_prep, model, names = held
    with caplog.at_level("INFO"):
        C.task(compute_multiscale, (), {"df_prep": df_prep, "model": model, "covariates": ["ws"],
                                        "variables_resample": ["ws"], "y_inf": None}, names)
        logging.getLogger("normet").info("after the dry run")
    assert [r.getMessage() for r in caplog.records] == ["after the dry run"]


def test_what_the_log_does_not_know_is_not_written(held):
    assert C.task(_r.ml_predict, (held[2], held[1]), {}, held[3]) is None


def test_capture_records_without_r():
    with _rpc.capture() as calls:
        with pytest.raises(_rpc.Captured):
            _rpc.call("nm_pdp", "x", var_list=["ws"], grid_points=None)
    assert calls == [("nm_pdp", ("x",), {"var_list": ["ws"]})]
    with _rpc.capture(lambda: 42) as calls:
        assert _rpc.call("nm_rolling", window_days=14) == 42
    assert calls[0][0] == "nm_rolling"


def test_an_r_object_travels_with_its_files(tmp_path):
    folder = tmp_path / "call_0001_model_1.d"
    (folder / "sub").mkdir(parents=True)
    (folder / "model.txt").write_text("booster")
    (folder / "sub" / "meta.json").write_text("{}")
    obj = _r.RModel(str(folder), {"backend": "lightgbm", "features": ["ws"]})
    blob = pickle.dumps(obj)
    shutil.rmtree(folder)  # the window that saved it has closed
    back = pickle.loads(blob)
    assert isinstance(back, _r.RModel) and back.feature_names == ["ws"]
    assert back.path != str(folder)
    assert open(f"{back.path}/model.txt").read() == "booster"
    assert open(f"{back.path}/sub/meta.json").read() == "{}"


needs_r = pytest.mark.skipif(not _rpc.rscript(), reason="Rscript not found")


@needs_r
def test_the_script_parses_in_r_and_reads_back(held, tmp_path):
    df, df_prep, model, names = held
    log = C.CommandLog()
    log.add(C.open_table("/data/my site.csv", "Europe/London"))
    log.add(C.task(_r.build_model, (df, "NO2"), {"backend": "lightgbm", "covariates": ["ws", "hour"],
                                                 "model_config": {"n_trials": 5}, "seed": 1}, names))
    log.add(C.task(_r.decompose, (df_prep, model), {"method": "meteorology", "covariates": ["ws"],
                                                   "groups": {"Wind": ["ws"]}, "n_samples": 20}, names))
    log.add(C.task(_r.pdp, (df_prep, model), {"var_list": ["ws"], "grid_points": 20}, names))
    path = tmp_path / "session.R"
    path.write_text(log.script())
    out = subprocess.run([_rpc.rscript(), "-e", f"invisible(parse('{path}'))"], capture_output=True, text=True)
    assert out.returncode == 0, out.stderr
    calls = _script.read_calls(path.read_text())
    assert calls["build_model"]["covariates"] == ["ws", "hour"]
    assert calls["decompose"]["groups"] == {"Wind": ["ws"]}
    assert calls["pdp"]["var_list"] == ["ws"]  # one name read back as a vector still
    config = _script.config_from_calls(calls)
    assert config["target"] == "NO2" and config["features"] == ["ws"] and config["lgb_trials"] == 5


@needs_r
def test_a_script_that_is_not_r_says_so():
    with pytest.raises(SyntaxError):
        _script.read_calls("res <- nm_build_model(df,")
