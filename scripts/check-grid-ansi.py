#!/usr/bin/env python3
import os
import sys

_BIN = os.path.join(os.path.dirname(__file__), "..", "bin")
sys.path.insert(0, os.path.abspath(_BIN))

from nvimcat_grid import Grid  # noqa: E402

# Brief fixture: bold red truecolor "Hi!"
g = Grid()
g.resize(1, 5)
g.apply_hl_attr_define(1, {"foreground": 0xFF0000, "bold": True}, {}, {})
g.apply_grid_line(1, 0, 0, [["Hi", 1], ["!", 1]], False)
out = g.to_ansi()
assert out == b"\x1b[1;38;2;255;0;0mHi!\x1b[0m\n"

# Optional hl_id: reuse last in-event
g = Grid()
g.resize(1, 3)
g.apply_hl_attr_define(1, {"foreground": 0xFF0000}, {}, {})
g.apply_grid_line(1, 0, 0, [["X", 1], ["Y"]], False)
row = g._rows[1][0]
assert row[0] == ("X", 1) and row[1] == ("Y", 1)

# Empty-text double-width continuation advances column
g = Grid()
g.resize(1, 5)
g.apply_hl_attr_define(1, {"foreground": 0xFF0000}, {}, {})
g.apply_grid_line(1, 0, 0, [["中", 1], ["", 1], ["!", 1]], False)
row = g._rows[1][0]
assert row[0] == ("中", 1) and row[1] == ("", 1) and row[2] == ("!", 1)

# SGR reset on hl change: bold+red → blue-only must not stay bold
g = Grid()
g.resize(1, 2)
g.apply_hl_attr_define(1, {"foreground": 0xFF0000, "bold": True}, {}, {})
g.apply_hl_attr_define(2, {"foreground": 0x0000FF}, {}, {})
g.apply_grid_line(1, 0, 0, [["A", 1], ["B", 2]], False)
out = g.to_ansi()
assert out == b"\x1b[1;38;2;255;0;0mA\x1b[0;38;2;0;0;255mB\x1b[0m\n"

print("OK grid_ansi")
