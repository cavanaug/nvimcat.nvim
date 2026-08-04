#!/usr/bin/env bash
# Full-screen compare: agent-terminal nvim TUI vs nvimcat (same prep, same size).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FILE="${1:?usage: compare-tui.sh <file> [cols] [rows]}"
COLS="${2:-100}"
ROWS="${3:-}"
NAME="nvimcatcmp$$"
PREP="$ROOT/scripts/prep-compare.lua"

if [[ -z "$ROWS" ]]; then
  LINES=$(wc -l <"$FILE" | tr -d ' ')
  ROWS=$((LINES + LINES / 2 + 48))
  if ((ROWS < 40)); then ROWS=40; fi
  if ((ROWS > 200)); then ROWS=200; fi
fi

cleanup() {
  agent-terminal kill -s "$NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

agent-terminal kill -s "$NAME" >/dev/null 2>&1 || true
agent-terminal spawn --name "$NAME" --geometry "${COLS}x${ROWS}" --xterm direct \
  nvim -n \
  --cmd "let g:nvimcat = 1" \
  --cmd "let g:nvimcat_root = '$ROOT'" \
  --cmd "set rtp^=$ROOT" \
  -c "lua vim.opt.rtp:prepend('$ROOT')" \
  "$FILE" >/dev/null

# Wait for something from the file
HINT=$(grep -m1 -E '^#+ |^[A-Za-z]' "$FILE" | head -c 40 | tr -d '`#*' || true)
if [[ -n "$HINT" ]]; then
  agent-terminal wait-for -s "$NAME" "$HINT" --timeout 30000 >/dev/null || true
else
  sleep 2
fi
sleep 1.2

agent-terminal press -s "$NAME" Escape >/dev/null
agent-terminal type -s "$NAME" ":luafile $PREP" >/dev/null
agent-terminal press -s "$NAME" Enter >/dev/null
sleep 2.5
agent-terminal press -s "$NAME" Escape >/dev/null
# Stay at top: nvimcat dumps from topline 1 after prep_compare.
agent-terminal press -s "$NAME" g >/dev/null
agent-terminal press -s "$NAME" g >/dev/null
sleep 0.8

TUI=$(mktemp)
CAT=$(mktemp)
trap 'rm -f "$TUI" "$CAT"; cleanup' EXIT

agent-terminal snapshot -s "$NAME" --format json --render text,style,color --settle 800 >"$TUI"
NVIMCAT_WIDTH="$COLS" NVIMCAT_HEIGHT="$ROWS" "$ROOT/bin/nvimcat" "$FILE" >"$CAT" 2>/tmp/nvimcat-compare.err || {
  echo "nvimcat failed:" >&2
  cat /tmp/nvimcat-compare.err >&2
  exit 1
}

python3 - "$TUI" "$CAT" "$FILE" <<'PY'
import json, re, sys
from pathlib import Path

tui_path, cat_path, label = sys.argv[1], sys.argv[2], sys.argv[3]
ANSI_RE = re.compile(r"\x1b\[([0-9;]*)m")
OSC8_RE = re.compile(r"\x1b\]8;[^\x1b\\]*\x1b\\")


def parse_ansi(line: str):
    line = OSC8_RE.sub("", line)
    cells = []
    fg = bg = None
    bold = italic = False
    i = 0
    while i < len(line):
        m = ANSI_RE.match(line, i)
        if m:
            parts = [int(x) for x in m.group(1).split(";") if x != ""] if m.group(1) != "" else [0]
            j = 0
            while j < len(parts):
                p = parts[j]
                if p == 0:
                    fg = bg = None
                    bold = italic = False
                elif p == 1:
                    bold = True
                elif p == 3:
                    italic = True
                elif p == 22:
                    bold = False
                elif p == 23:
                    italic = False
                elif p == 38 and j + 4 < len(parts) and parts[j + 1] == 2:
                    fg = "#{:02x}{:02x}{:02x}".format(parts[j + 2], parts[j + 3], parts[j + 4])
                    j += 4
                elif p == 48 and j + 4 < len(parts) and parts[j + 1] == 2:
                    bg = "#{:02x}{:02x}{:02x}".format(parts[j + 2], parts[j + 3], parts[j + 4])
                    j += 4
                j += 1
            i = m.end()
            continue
        cells.append({"ch": line[i], "fg": fg, "bg": bg, "b": bold, "i": italic})
        i += 1
    while cells and cells[-1]["ch"] == " " and not cells[-1]["bg"] and not cells[-1]["b"]:
        cells.pop()
    return cells


def tui_row_cells(row):
    """Build cells from agent-terminal JSON row (text + spans).

    Span c/l are character indices into row text (not display columns).
    """
    text = OSC8_RE.sub("", row.get("t") or "")
    styles = {}
    max_end = len(text)
    for sp in row.get("spans") or []:
        s = sp.get("s") or {}
        start, length = sp["c"], sp["l"]
        max_end = max(max_end, start + length)
        for c in range(start, start + length):
            styles[c] = {
                "fg": s.get("fg"),
                "bg": s.get("bg"),
                "b": bool(s.get("b")),
                "i": bool(s.get("i")),
            }
    cells = []
    for idx, ch in enumerate(text.rstrip("\n")):
        st = styles.get(idx) or {}
        cells.append(
            {
                "ch": ch,
                "fg": st.get("fg"),
                "bg": st.get("bg"),
                "b": st.get("b", False),
                "i": st.get("i", False),
            }
        )
    # Trailing span coverage (full-width heading / code bars) as spaces.
    for idx in range(len(cells), max_end):
        st = styles.get(idx) or {}
        if not (st.get("bg") or st.get("b") or st.get("i") or st.get("fg")):
            continue
        cells.append(
            {
                "ch": " ",
                "fg": st.get("fg"),
                "bg": st.get("bg"),
                "b": st.get("b", False),
                "i": st.get("i", False),
            }
        )
    while cells and cells[-1]["ch"] in ("", " ") and not cells[-1]["bg"] and not cells[-1]["b"]:
        cells.pop()
    return cells


def plain(cells):
    return "".join(c["ch"] for c in cells if c["ch"]).rstrip()


tui = json.loads(Path(tui_path).read_text())
cat_lines = Path(cat_path).read_text(errors="replace").splitlines()


def tui_height(rows):
    h = 0
    for i, row in enumerate(rows):
        t = OSC8_RE.sub("", row.get("t") or "").rstrip()
        if t == "~" or t.startswith("~") or t.startswith("E1568"):
            break
        if "Indexing workspace" in t:
            break
        h = i + 1
    while h > 0 and not OSC8_RE.sub("", rows[h - 1].get("t") or "").strip():
        h -= 1
    return h


def cat_height(lines):
    h = 0
    for i, line in enumerate(lines):
        p = re.sub(r"\x1b\[[0-9;]*m", "", line).rstrip()
        if p == "~" or re.fullmatch(r"~+", p):
            break
        h = i + 1
    while h > 0 and not re.sub(r"\x1b\[[0-9;]*m", "", lines[h - 1]).strip():
        h -= 1
    return h


n = min(tui_height(tui["rows"]), cat_height(cat_lines))
mism = []
for i in range(n):
    tc = tui_row_cells(tui["rows"][i])
    cc = parse_ansi(cat_lines[i] if i < len(cat_lines) else "")
    tp, cp = plain(tc), plain(cc)
    if tp != cp:
        mism.append(f"L{i} TEXT\n  T={tp!r}\n  C={cp!r}")
        continue
    # Align by printable chars for style checks (skip wide pads)
    def content(cells):
        return [c for c in cells if c["ch"] != ""]

    tc2, cc2 = content(tc), content(cc)
    for j, (a, b) in enumerate(zip(tc2, cc2)):
        if a["ch"].isspace() and b["ch"].isspace():
            # Catch missing Normal bg on spaces (one side None, other set).
            ab, bb = (a.get("bg") or "").lower(), (b.get("bg") or "").lower()
            if ab != bb and (ab or bb):
                mism.append(f"L{i}c{j} space bg {a.get('bg')!r}!={b.get('bg')!r}")
            continue
        for key, name in (("fg", "fg"), ("bg", "bg"), ("b", "bold"), ("i", "italic")):
            av, bv = a.get(key), b.get(key)
            if key in ("fg", "bg"):
                al, bl = (str(av).lower() if av else ""), (str(bv).lower() if bv else "")
                if al != bl and (al or bl):
                    mism.append(f"L{i}c{j} {a['ch']!r} {name} {av!r}!={bv!r}")
            else:
                if bool(av) != bool(bv):
                    mism.append(f"L{i}c{j} {a['ch']!r} {name} {av}!={bv}")
        if len(mism) > 60:
            break
    if len(mism) > 60:
        break

print(f"file={label} rows_compared={n} mismatches={len(mism)}")
for m in mism[:40]:
    print(m)
if mism:
    sys.exit(1)
print("MATCH")
PY
