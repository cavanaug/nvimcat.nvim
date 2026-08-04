#!/usr/bin/env python3
import os
import sys

_BIN = os.path.join(os.path.dirname(__file__), "..", "bin")
sys.path.insert(0, os.path.abspath(_BIN))

from nvimcat_grid import Grid  # noqa: E402

g = Grid()
g.resize(1, 5)  # rows, cols
g.apply_hl_attr_define(1, {"foreground": 0xFF0000, "bold": True}, {}, {})
# grid_line data format per Neovim: list of [text, hl_id, repeat?]
g.apply_grid_line(1, 0, 0, [["Hi", 1], ["!", 1]], False)
out = g.to_ansi()
assert b"\x1b[" in out and (
    b"Hi!" in out.replace(b"\x1b[0m", b"").replace(b"\x1b[1m", b"")
    or b"Hi" in out
)
# Truecolor red somewhere:
assert b"255;0;0" in out or b"38;2;255;0;0" in out
print("OK grid_ansi")
