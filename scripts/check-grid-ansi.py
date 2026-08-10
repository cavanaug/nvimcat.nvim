#!/usr/bin/env python3
import os
import runpy

_BIN = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "bin", "nvimcat"))
mod = runpy.run_path(_BIN)
Grid = mod["Grid"]

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

# Missing hl bg inherits Normal from default_colors_set; hl 0 paints Normal too
g = Grid()
g.resize(1, 4)
g.apply_default_colors_set(0xE2E2E3, 0x2C2E34)
g.apply_hl_attr_define(1, {"foreground": 0xFC5D7C, "bold": True}, {}, {})
g.apply_grid_line(1, 0, 0, [["│", 1], [" ", 0], ["T", 1]], False)
out = g.to_ansi()
assert b"48;2;44;46;52" in out  # Normal bg on bold border and default space
assert out.startswith(b"\x1b[1;38;2;252;93;124;48;2;44;46;52m")

# Trailing eob `~` rows are omitted
g = Grid()
g.resize(3, 3)
g.apply_hl_attr_define(1, {"foreground": 0xFFFFFF}, {}, {})
g.apply_hl_attr_define(2, {"foreground": 0x414550}, {}, {})
g.apply_grid_line(1, 0, 0, [["Hi", 1]], False)
g.apply_grid_line(1, 1, 0, [["~", 2]], False)
g.apply_grid_line(1, 2, 0, [["~", 2]], False)
out = g.to_ansi()
assert b"Hi" in out and b"~" not in out

# Mid-row rumdl/snacks "Indexing"/"Indexed" overlay is truncated (garbled form too).
g = Grid()
g.resize(1, 40)
g.apply_hl_attr_define(1, {"foreground": 0xFFFFFF}, {}, {})
g.apply_grid_line(
    1,
    0,
    0,
    [["│ conta✔tIndexingiworkspace───────", 1]],
    False,
)
out = g.to_ansi()
plain = out.decode("utf-8", "replace")
assert "Indexing" not in plain, plain
assert "conta" in plain, plain

g = Grid()
g.resize(1, 50)
g.apply_hl_attr_define(1, {"foreground": 0xFFFFFF}, {}, {})
g.apply_grid_line(
    1,
    0,
    0,
    [["│ scopes                       Indexed 71/630 files  (11%) ⠹──", 1]],
    False,
)
out = g.to_ansi()
plain = out.decode("utf-8", "replace")
assert "Indexed" not in plain, plain
assert "scopes" in plain, plain

# Whole-row Indexing toast is dropped.
g = Grid()
g.resize(2, 20)
g.apply_hl_attr_define(1, {"foreground": 0xFFFFFF}, {}, {})
g.apply_grid_line(1, 0, 0, [["real content", 1]], False)
g.apply_grid_line(1, 1, 0, [["✔ Indexing workspace", 1]], False)
out = g.to_ansi()
plain = out.decode("utf-8", "replace")
assert "Indexing" not in plain, plain
assert "real content" in plain, plain

print("OK grid_ansi")
