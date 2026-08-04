#!/usr/bin/env bash
# Self-check: nvimcat smoke + full TUI compare against agent-terminal.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SAMPLE="${1:-$ROOT/fixtures/sample.md}"

export NVIMCAT_WIDTH="${NVIMCAT_WIDTH:-80}"
OUT="$(mktemp)"
ERR="$(mktemp)"
trap 'rm -f "$OUT" "$ERR"' EXIT

start_ms="$(date +%s%3N)"
if ! timeout 90 "$ROOT/bin/nvimcat" "$SAMPLE" >"$OUT" 2>"$ERR"; then
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
checks = {
    "nonempty": bool(plain.strip()),
    "has_sgr": "\x1b[" in raw,
    "heading": "Heading" in plain or "Sample" in plain or "Terminal" in plain,
    # Cold start + mermaid settle should still finish well under 4s.
    "perf_under_4s": elapsed < 4000,
}
for k, v in checks.items():
    print(("OK" if v else "FAIL"), k)
print(f"elapsed_ms={elapsed}")
print("---")
print("\n".join(plain.splitlines()[:20]))
sys.exit(0 if all(checks.values()) else 1)
PY

if command -v agent-terminal >/dev/null 2>&1; then
  echo "compare-tui: $SAMPLE"
  "$ROOT/scripts/compare-tui.sh" "$SAMPLE" "$NVIMCAT_WIDTH"
else
  echo "skip compare-tui (agent-terminal not installed)"
fi
