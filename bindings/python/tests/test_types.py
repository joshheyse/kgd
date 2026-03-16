"""Tests for kgdclient types and serialization."""

from kgdclient import Anchor, Color


def test_anchor_absolute():
    a = Anchor(type="absolute", row=5, col=10)
    d = a.to_dict()
    assert d == {"type": "absolute", "row": 5, "col": 10}


def test_anchor_pane():
    a = Anchor(type="pane", pane_id="%0", row=2, col=3)
    d = a.to_dict()
    assert d == {"type": "pane", "pane_id": "%0", "row": 2, "col": 3}


def test_anchor_nvim_win():
    a = Anchor(type="nvim_win", win_id=1000, buf_line=5, col=0)
    d = a.to_dict()
    assert d == {"type": "nvim_win", "win_id": 1000, "buf_line": 5}


def test_anchor_omits_zero_fields():
    a = Anchor(type="absolute")
    d = a.to_dict()
    assert d == {"type": "absolute"}


def test_color_defaults():
    c = Color()
    assert c.r == 0 and c.g == 0 and c.b == 0


def test_color_values():
    c = Color(r=65535, g=32768, b=0)
    assert c.r == 65535
    assert c.g == 32768
    assert c.b == 0
