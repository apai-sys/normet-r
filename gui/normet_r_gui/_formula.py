"""Mathtext written out in Unicode's sub- and superscripts: $\\mathregular{NO_{2}}$ as NO₂.

A figure's text in Chinese is drawn as plain text, because mathtext sets the whole text in
its own face, which has no Chinese; a formula in it is written out this way instead.
"""

from __future__ import annotations

import re

_SUB = str.maketrans("0123456789+-−=()", "₀₁₂₃₄₅₆₇₈₉₊₋₋₌₍₎")
_SUP = str.maketrans("0123456789+-−=()", "⁰¹²³⁴⁵⁶⁷⁸⁹⁺⁻⁻⁼⁽⁾")
_SCRIPT = re.compile(r"([_^])(?:\{([^{}]*)\}|(\S))")


def _plain_math(body: str) -> str:
    body = re.sub(r"\\mathregular\{(.*)\}", r"\1", body)
    body = _SCRIPT.sub(
        lambda m: (m.group(2) if m.group(2) is not None else m.group(3)).translate(
            _SUB if m.group(1) == "_" else _SUP
        ),
        body,
    )
    return body.replace("{", "").replace("}", "")


def plain(text: str) -> str:
    """``text`` with its mathtext written out in Unicode's sub- and superscripts."""
    return re.sub(r"\$([^$]*)\$", lambda m: _plain_math(m.group(1)), text or "")
