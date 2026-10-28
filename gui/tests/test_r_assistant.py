"""The Assistant's carry_out and api_help in this window: normet's R API, run in R."""

from __future__ import annotations

import json
import os
import socket
import time

import pandas as pd
import pytest

pytest.importorskip("PySide6")
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from normet_r_gui import _rpc  # noqa: E402

pytestmark = pytest.mark.skipif(not _rpc.rscript(), reason="needs Rscript and the normet R package")


@pytest.fixture(scope="module")
def qapp():
    from PySide6.QtWidgets import QApplication

    return QApplication.instance() or QApplication([])


def test_api_help_reads_the_r_package():
    from normet_r_gui import _code

    listed = _code.api_help("")
    assert "- nm_rolling:" in listed and "- nm_normalise:" in listed
    assert _code.api_help("rolling").startswith("nm_rolling(df")  # nm_ may be left off
    with pytest.raises(ValueError, match="did you mean"):
        _code.api_help("rollng")


def test_code_runs_in_r_on_the_table():
    from normet_r_gui import _code

    df = pd.DataFrame({"date": pd.date_range("2020-01-01", periods=48, freq="h"), "NO2": range(48)})
    said = _code.run_code("nrow(df)\nkept <- df[df$NO2 > 40, ]", df)
    assert "[1] 48" in said and "kept: 7 rows x 2 columns" in said
    assert "Error:\nboom" in _code.run_code("stop('boom')", df)


def test_carry_out_runs_r_from_the_card(qapp, monkeypatch, tmp_path):
    from PySide6.QtCore import QSettings
    from PySide6.QtWidgets import QPushButton

    from normet_r_gui import assistant
    from normet_r_gui.main_window import MainWindow

    ini = str(tmp_path / "normet-r-gui.ini")
    monkeypatch.setattr(assistant, "_settings", lambda: QSettings(ini, QSettings.Format.IniFormat))
    win = MainWindow()
    try:
        win.load_example("my1")
        dock = win.assistant
        assert "R: library(normet)" in assistant.system_prompt()
        dock.tools.carry_out("print(dim(df))", "the table's size")
        qapp.processEvents()
        btn = [b for b in dock.view.findChildren(QPushButton) if b.text() == "Run"][0]
        btn.click()
        t0 = time.time()
        while not dock.notes and time.time() - t0 < 120:
            qapp.processEvents()
            time.sleep(0.05)
        assert f"[1] {len(win.df_raw)}" in dock.notes[-1]
    finally:
        win.close()


def _forward(tmp_path, monkeypatch, cluster="bede", model="hf.co/unsloth/GLM-5.3-Flash-GGUF:UD-Q4_K_XL"):
    """A registry with one live forward (a listening socket), and no OpenCode config."""
    from normet_r_gui.nm.agent import llm

    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    sock.listen()
    port = sock.getsockname()[1]
    reg = tmp_path / "forwards.json"
    reg.write_text(json.dumps([{"cluster": cluster, "model": model, "local": port}]))
    monkeypatch.setenv("NORMET_HPC_FORWARDS", str(reg))
    monkeypatch.setattr(llm, "OPENCODE_DIR", str(tmp_path / "no-opencode"))
    return sock, port, model


def test_a_model_hpc_agent_forwards_is_found_by_cluster(monkeypatch, tmp_path):
    from normet_r_gui.nm.agent import llm

    sock, port, model = _forward(tmp_path, monkeypatch)
    try:
        assert llm.hpc_models() == [f"bede:{model}"]
        m = llm.Model("bede:glm", api_key="k")
        assert (m.model, m.base_url, m.key) == (model, f"http://127.0.0.1:{port}/v1", "k")
        reg = tmp_path / "forwards.json"  # the job restarted on another port
        reg.write_text(json.dumps([{"cluster": "bede", "model": model, "local": 4242}]))
        assert llm.Model("bede:glm", api_key="k").base_url == "http://127.0.0.1:4242/v1"
    finally:
        sock.close()


def test_the_panel_offers_forwards_and_keeps_a_server_of_the_analysts_own(
    qapp, monkeypatch, tmp_path
):
    from PySide6.QtCore import QSettings

    from normet_r_gui import assistant
    from normet_r_gui.main_window import MainWindow
    from normet_r_gui.nm.agent import llm

    ini = str(tmp_path / "normet-r-gui.ini")
    monkeypatch.setattr(assistant, "_settings", lambda: QSettings(ini, QSettings.Format.IniFormat))
    monkeypatch.setattr(assistant, "keychain_get", lambda provider: None)
    monkeypatch.setattr(assistant, "keychain_store", lambda provider, key: False)
    sock, port, model = _forward(tmp_path, monkeypatch)
    win = MainWindow()
    try:
        dock = win.assistant
        items = [dock.model_box.itemText(i) for i in range(dock.model_box.count())]
        assert f"bede:{model}" in items
        dock.model_box.setCurrentText("lab:qwen3")
        assert dock.key_btn.isEnabled()
        assert "kept at http://10.0.0.5:8080/v1" in dock.apply_server("lab", "k1", "http://10.0.0.5:8080/v1")
        m = dock._model()
        assert (m.model, m.base_url, m.key) == ("qwen3", "http://10.0.0.5:8080/v1", "k1")
        assert "removed" in dock.apply_server("lab", "", "")
    finally:
        win.close()
        llm.forget_provider("lab")
        sock.close()
