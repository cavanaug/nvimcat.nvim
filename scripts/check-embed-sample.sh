#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp)"
trap 'rm -f "$OUT"' EXIT
export NVIMCAT_ROOT="$ROOT" NVIMCAT_WIDTH=80 NVIMCAT_EMBED=1
start="$(date +%s%3N)"
python3 "$ROOT/bin/nvimcat" 80 "$ROOT/fixtures/sample.md" >"$OUT"
end="$(date +%s%3N)"
elapsed=$((end - start))
python3 - "$OUT" "$elapsed" <<'PY'
import re, sys
from pathlib import Path
raw = Path(sys.argv[1]).read_text()
plain = re.sub(r"\x1b\[[0-9;]*m", "", raw)
elapsed = int(sys.argv[2])
assert plain.strip(), "empty"
assert "\x1b[" in raw, "no sgr"
assert "Heading" in plain
assert elapsed < 1500, elapsed  # interim gate before research-tuned budget
print(f"OK embed_sample elapsed_ms={elapsed}")
PY
