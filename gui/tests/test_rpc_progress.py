"""R's progress reports on their way to the window: rpc.R writes the share of the call
done as a line of its own, which _rpc hands to whoever listens (the task clock)."""

from __future__ import annotations

import io
import logging

import pytest

from normet_r_gui import _rpc
from normet_r_gui.nm.utils import progress


def test_r_progress_lines_are_heard_not_logged(caplog):
    out = io.StringIO("INFO [10:00:00.000] Processing 4 rolling windows\n"
                      "NM_PROGRESS 0.2500\n"
                      "NM_PROGRESS 0.5000\n"
                      "RPC_DONE\n")
    heard: list[float] = []
    lines: list[str] = []
    with caplog.at_level(logging.INFO, logger="normet.R"), progress.listening(heard.append):
        _rpc._forward(out, lines, None)
    assert heard == pytest.approx([0.25, 0.5])
    assert lines == ["INFO [10:00:00.000] Processing 4 rolling windows"]
    assert "NM_PROGRESS" not in caplog.text


def test_an_r_call_made_as_a_part_reports_within_its_share():
    # The multi-scale run's three rolling calls each fill a third of the bar.
    heard: list[float] = []
    with progress.listening(heard.append), progress.part(1, 3):
        _rpc._forward(io.StringIO("NM_PROGRESS 0.5000\n"), [], None)
    assert heard == pytest.approx([0.5])  # half of the second third: halfway


def test_without_a_listener_the_lines_are_dropped():
    lines: list[str] = []
    _rpc._forward(io.StringIO("NM_PROGRESS 0.5000\n"), lines, None)
    assert lines == []
