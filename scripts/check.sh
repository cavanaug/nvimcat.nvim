#!/usr/bin/env bash
# Self-check: correctness + rough performance budget.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SAMPLE="${1:-$ROOT/fixtures/sample.md}"
OUT="$(mktemp)"
ERR="$(mktemp)"
trap 'rm -f "$OUT" "$ERR"' EXIT

export NVIMCAT_WIDTH=80
export NVIMCAT_VERBOSE=1

start_ms="$(date +%s%3N)"
if ! timeout 60 "$ROOT/bin/nvimcat" "$SAMPLE" >"$OUT" 2>"$ERR"; then
  echo "nvimcat failed or timed out" >&2
  cat "$ERR" >&2 || true
  exit 1
fi
end_ms="$(date +%s%3N)"
elapsed=$((end_ms - start_ms))

python3 - "$OUT" "$elapsed" <<'PY'
import re, sys
from pathlib import Path
raw = Path(sys.argv[1]).read_text()
plain = re.sub(r"\x1b\[[0-9;]*m", "", raw)
elapsed = int(sys.argv[2])
first = next((l for l in plain.splitlines() if l.strip()), "")
first_ansi = next((l for l in raw.splitlines() if "Heading One" in re.sub(r"\x1b\[[0-9;]*m", "", l)), "")
para = next((l for l in raw.splitlines() if "bold" in re.sub(r"\x1b\[[0-9;]*m", "", l)), "")
table = next((l for l in raw.splitlines() if "Tool" in re.sub(r"\x1b\[[0-9;]*m", "", l)), "")
quote = next((l for l in raw.splitlines() if "quote" in re.sub(r"\x1b\[[0-9;]*m", "", l)), "")

def styles_for(line):
    fg = bg = None
    bold = italic = False
    out = []
    i = 0
    while i < len(line):
        m = re.match(r"\x1b\[([0-9;]*)m", line[i:])
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
                elif p == 38 and j + 4 < len(parts) and parts[j + 1] == 2:
                    fg = "#{:02x}{:02x}{:02x}".format(parts[j + 2], parts[j + 3], parts[j + 4])
                    j += 4
                elif p == 48 and j + 4 < len(parts) and parts[j + 1] == 2:
                    bg = "#{:02x}{:02x}{:02x}".format(parts[j + 2], parts[j + 3], parts[j + 4])
                    j += 4
                j += 1
            i += len(m.group(0))
            continue
        out.append((line[i], fg, bg, bold, italic))
        i += 1
    return out

def word_ok(line, word, want_b=None, want_i=None, want_fg=None):
    cells = styles_for(line)
    s = "".join(c[0] for c in cells)
    idx = s.find(word)
    if idx < 0:
        return False
    chunk = cells[idx : idx + len(word)]
    for ch, fg, _bg, bold, italic in chunk:
        if want_b is not None and bold != want_b:
            return False
        if want_i is not None and italic != want_i:
            return False
        if want_fg and (fg or "").lower() != want_fg.lower():
            return False
    return True

# non-cursor heading look: RenderMarkdownH1Bg must survive capture full-width
heading_cells = styles_for(first_ansi)
checks = {
    "table_corner": "┌" in plain,
    "table_vline": "│" in plain,
    "heading": "Heading One" in plain,
    "heading_icon": ("Heading One" in first and not first.lstrip().startswith("#")),
    "heading_bg": "48;2;" in first_ansi,
    "heading_bg_fullwidth": sum(1 for _c, _f, bg, _b, _i in heading_cells if bg) >= 80,
    "heading_bold": word_ok(first_ansi, "Heading", want_b=True),
    "para_bold": word_ok(para, "bold", want_b=True, want_fg="#e2e2e3"),
    "para_italic": word_ok(para, "italic", want_i=True, want_fg="#e2e2e3"),
    "para_code": word_ok(para, "code", want_b=False, want_fg="#e7c664"),
    "table_head_fg": word_ok(table, "Tool", want_b=True, want_fg="#fc5d7c"),
    "quote_fg": word_ok(quote, "quote", want_fg="#7f8490"),
    "mermaid_diagram": ("Start" in plain and "Done" in plain and "┌" in plain),
    "no_eob_pad": "quote" in (plain.splitlines()[-1] if plain.splitlines() else ""),
    # cold LazyVim dump target from design (~2s); allow slack on busy hosts
    "perf_under_3s": elapsed < 3000,
}
for k, v in checks.items():
    print(("OK" if v else "FAIL"), k)
print(f"elapsed_ms={elapsed}")
print("---")
print("\n".join(plain.splitlines()[:30]))
sys.exit(0 if all(checks.values()) else 1)
PY
