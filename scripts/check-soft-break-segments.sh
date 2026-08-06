#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import importlib.util
import sys
from pathlib import Path

root = Path(sys.argv[1])
# bin/nvimcat is a script; load via runpy-safe path: exec only defs by importing as file
sys.path.insert(0, str(root / "bin"))
# Prefer loading functions by compiling the file and extracting — script has side effects on __main__.
# Instead: duplicate-import guard — call helpers after loading with a stub __name__.
import types
code = (root / "bin" / "nvimcat").read_text()
# Execute module body without running main: strip/avoid __main__ by setting __name__
ns = types.ModuleType("nvimcat_bin")
ns.__file__ = str(root / "bin" / "nvimcat")
exec(compile(code, str(root / "bin" / "nvimcat"), "exec"), ns.__dict__)

seg = ns._soft_break_segments
is_sb = ns._is_soft_break_line

# blanks only
lines = ["a", "b", "", "c"]
assert seg(lines, []) == [(1, 3), (4, 4)], seg(lines, [])

# comment leader with blank required
leaders = [("#", True)]
lines = ["code", "# note", "more"]
assert is_sb("# note", leaders)
assert not is_sb("#note", leaders)  # b-flag: need blank after leader
assert not is_sb("code", leaders)
assert seg(lines, leaders) == [(1, 2), (3, 3)], seg(lines, leaders)

# leader without blank required
leaders = [("//", False)]
assert is_sb("//foo", leaders)
assert is_sb("//", leaders)

# hard cut: 5 lines, no soft breaks, ui_max=2
lines = ["a", "b", "c", "d", "e"]
assert seg(lines, [], ui_max=2) == [(1, 2), (3, 4), (5, 5)], seg(lines, [], ui_max=2)

# soft break ends segment including the blank
lines = ["a", "", "b", ""]
assert seg(lines, []) == [(1, 2), (3, 4)], seg(lines, [])

print("OK soft-break-segments")
PY
