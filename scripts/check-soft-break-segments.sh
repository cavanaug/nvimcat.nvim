#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import sys
from pathlib import Path
import types

root = Path(sys.argv[1])
code = (root / "bin" / "nvimcat").read_text()
ns = types.ModuleType("nvimcat_bin")
ns.__file__ = str(root / "bin" / "nvimcat")
exec(compile(code, str(root / "bin" / "nvimcat"), "exec"), ns.__dict__)

seg = ns._soft_break_segments
is_sb = ns._is_soft_break_line

# blanks: pack to last soft break in pack_target window
lines = ["a", "b", "", "c"]
assert seg(lines, []) == [(1, 3), (4, 4)], seg(lines, [])

# comment leader with blank required
leaders = [("#", True)]
lines = ["code", "# note", "more"]
assert is_sb("# note", leaders)
assert not is_sb("#note", leaders)
assert not is_sb("code", leaders)
assert seg(lines, leaders) == [(1, 2), (3, 3)], seg(lines, leaders)

# leader without blank required
leaders = [("//", False)]
assert is_sb("//foo", leaders)
assert is_sb("//", leaders)

# hard cut: 5 lines, no soft breaks, ui_max=2
lines = ["a", "b", "c", "d", "e"]
assert seg(lines, [], ui_max=2) == [(1, 2), (3, 4), (5, 5)], seg(lines, [], ui_max=2)

# multiple blanks within pack_target: pack to last blank
lines = ["a", "", "b", ""]
assert seg(lines, [], pack_target=100) == [(1, 4)], seg(lines, [], pack_target=100)

# extra break (heading) without blank
lines = ["a", "## H", "b"]
assert seg(lines, [], extra_breaks={2}) == [(1, 2), (3, 3)], seg(lines, [], extra_breaks={2})

# fence: interior blank suppressed; trailing blank is cut
lines = ["```", "", "x", "```", ""]
assert seg(
    lines, [], extra_breaks={1}, suppress_blanks=[(2, 3)], pack_target=100
) == [(1, 5)], seg(lines, [], extra_breaks={1}, suppress_blanks=[(2, 3)], pack_target=100)

# blank outside suppress still preferred cut
lines = ["a", "", "b"]
assert seg(lines, [], suppress_blanks=[(10, 12)]) == [(1, 2), (3, 3)], seg(lines, [])

# comment still preferred cut even inside suppress range
leaders = [("#", True)]
lines = ["```", "# note", "```"]
assert seg(
    lines, leaders, extra_breaks={1}, suppress_blanks=[(2, 2)]
) == [(1, 2), (3, 3)], seg(lines, leaders, extra_breaks={1}, suppress_blanks=[(2, 2)])

# many headings: pack_target keeps page count sane (not one page per heading)
lines = []
extras = set()
for i in range(1, 51):
    lines.append(f"## H{i}")
    extras.add(len(lines))
    lines.append(f"body-{i}")
    lines.append("")
packed = seg(lines, [], ui_max=1000, pack_target=100, extra_breaks=extras)
assert 2 <= len(packed) <= 8, packed
for a, b in packed:
    assert b - a + 1 <= 1000

# no soft break in pack_target → hard-cut at pack_limit (not distant blank)
lines = ["x"] * 50 + [""] + ["y"] * 50 + [""]
packed = seg(lines, [], pack_target=40)
assert packed[0] == (1, 40), packed
assert packed[1][0] == 41

print("OK soft-break-segments")
PY
