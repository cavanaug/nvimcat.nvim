#!/usr/bin/env bash
# Prove tall buffers scroll-stitch past Neovim's 1000-line UI clamp / page height.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp)
trap 'rm -f "$TMP" "$TMP.out"' EXIT

# ~400 pipe-table rows → forces page mode (_PAGE_LINES=250) without a 15s monster.
{
  echo "# scroll-stitch fixture"
  echo
  echo "| A | B |"
  echo "|---|---|"
  for i in $(seq 1 400); do
    echo "| row-$i | val-$i |"
  done
} >"$TMP"

start=$(date +%s%3N)
"$ROOT/bin/nvimcat" "$TMP" >"$TMP.out"
end=$(date +%s%3N)
elapsed=$((end - start))

python3 - "$TMP.out" "$elapsed" <<'PY'
import re, sys
from pathlib import Path
raw = Path(sys.argv[1]).read_bytes()
elapsed = int(sys.argv[2])
plain = re.sub(rb"\x1b\[[0-9;]*m", b"", raw).decode("utf-8", "replace")
lines = plain.count("\n") + (0 if plain.endswith("\n") else 1)
# Must include late rows (not just the first page).
ok_tail = "row-350" in plain and "row-400" in plain
ok_head = "scroll-stitch" in plain or "row-1" in plain
print(f"scroll_lines={lines} elapsed_ms={elapsed} head={ok_head} tail={ok_tail}")
if not (ok_head and ok_tail and lines >= 300):
    print("FAIL scroll-stitch incomplete", file=sys.stderr)
    sys.exit(1)
# Generous ceiling — catches pathological regressions, not a perf target.
if elapsed > 20000:
    print("FAIL scroll-stitch too slow", file=sys.stderr)
    sys.exit(1)
print("OK scroll-stitch")
PY
