#!/usr/bin/env bash
# Mid-table pack seams reflow column widths; keep_together must keep one width.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp --suffix=.md)"
OUT="$(mktemp)"
trap 'rm -f "$TMP" "$OUT"' EXIT

{
  # No blank soft-breaks: force hard-cut mid-table under pack_target≈100.
  for i in $(seq 1 80); do
    printf 'filler-%02d\n' "$i"
  done
  echo '| API Endpoint                                                                                 | Granular Scopes                              |'
  echo '|----------------------------------------------------------------------------------------------|----------------------------------------------|'
  # Long early rows inflate column width; short late rows would shrink on a seam page.
  for i in $(seq 1 25); do
    printf '| %-92s | %-44s |\n' \
      "Delete Virtual Background files with a deliberately long endpoint title $i" \
      "group:delete:virtual_background_files:admin"
  done
  for i in $(seq 26 50); do
    printf '| %-20s | %-10s |\n' "short $i" "x:y:z"
  done
} >"$TMP"

export NVIMCAT_STITCH_HEIGHT=100
"$ROOT/bin/nvimcat" --width 160 "$TMP" >"$OUT"

python3 - "$OUT" <<'PY'
import re, sys
text = open(sys.argv[1], "rb").read().decode("utf-8", "replace")
plain = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", text)
plain = re.sub(r"\x1b\][^\x07]*\x07", "", plain)
# Border/data rows use box-drawing after render.markdown.
border_widths = []
for line in plain.splitlines():
    s = line.rstrip()
    if not s:
        continue
    if any(ch in s for ch in ("\u2500", "\u2502", "\u250c", "\u2514", "\u251c", "\u252c")):
        if "filler-" in s:
            continue
        border_widths.append(len(s))
if len(border_widths) < 20:
    raise SystemExit(f"too few table rows captured: {len(border_widths)}")
widths = sorted(set(border_widths))
if len(widths) != 1:
    raise SystemExit(f"table column reflow seam: widths={widths} counts={ {w: border_widths.count(w) for w in widths} }")
# Long early content must still be present (not crushed onto a short-row page).
if "deliberately long endpoint" not in plain:
    raise SystemExit("missing long endpoint text")
if "short 50" not in plain:
    raise SystemExit("missing short late row")
print(f"OK table-keep-together width={widths[0]} rows={len(border_widths)}")
PY
