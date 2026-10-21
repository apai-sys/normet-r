"""The R GUI in Chinese (normet_r_gui.uilang), offscreen."""

from __future__ import annotations

import os
import re
import subprocess
import sys

import pytest

pytest.importorskip("PySide6")

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")


@pytest.mark.parametrize("module", ["ui_zh", "ui_zh_r"])
def test_every_translation_keeps_its_templates_marks(module):
    import importlib

    texts = importlib.import_module(f"normet_r_gui.{module}").TEXTS
    for en, tr in texts.items():
        assert sorted(re.findall(r"\{[ns]\d+\}", en)) == sorted(re.findall(r"\{[ns]\d+\}", tr)), en


def test_the_shared_catalogue_is_normet_pys():
    """ui_zh.py is normet-py's own, so the two windows stay in step; this window's words
    are in ui_zh_r.py, and only add to it."""
    from normet_r_gui import ui_zh, ui_zh_r

    clash = {k for k in ui_zh_r.TEXTS if k in ui_zh.TEXTS and ui_zh.TEXTS[k] != ui_zh_r.TEXTS[k]}
    assert not clash, clash


@pytest.mark.parametrize(
    ("english", "chinese"),
    [
        ("&Check R environment", "检查 R 环境(&C)"),
        ("R: normet package missing", "R：缺少 normet 包"),
        ("Placebo effects (12 donors)", "安慰剂效应（12 个供体）"),
        ("Built 12 transport features for 1,240 receptor times.", "为 1,240 个受体时刻构建了 12 个传输特征。"),
        (
            "R was found but the normet package could not be loaded.\nInstall it in R with:",
            "已找到 R，但无法加载 normet 包。\n请在 R 中运行以下命令安装：",
        ),
        # A tooltip written over several lines is one entry.
        (
            "H2O AutoML algorithms to search over (include_algos), within the\n"
            "time budget. GBM is the fastest and usually sufficient; tick more\n"
            "to widen the search.",
            "H2O AutoML 在时间预算内搜索的算法（include_algos）。GBM 最快，通常已足够；勾选更多可扩大搜索范围。",
        ),
        # Data's own words stay as written.
        ("PM2.5", "PM2.5"),
        ("lightgbm", "lightgbm"),
    ],
)
def test_texts_in_chinese(english, chinese):
    from normet_r_gui import uilang

    assert uilang.tr(english, "zh") == chinese


def test_the_window_in_chinese():
    """tests/_uilang_smoke.py: tabs, buttons, menus, the studios, a switch and back."""
    here = os.path.dirname(os.path.abspath(__file__))
    env = {**os.environ, "QT_QPA_PLATFORM": "offscreen", "NORMET_UI_LANGUAGE": "zh"}
    proc = subprocess.run(
        [sys.executable, os.path.join(here, "_uilang_smoke.py")],
        capture_output=True,
        text=True,
        env=env,
        timeout=300,
    )
    assert proc.returncode == 0 and "uilang smoke OK" in proc.stdout, (
        proc.returncode,
        proc.stdout[-2000:],
        proc.stderr[-4000:],
    )
