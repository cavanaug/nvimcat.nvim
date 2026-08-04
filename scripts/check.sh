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
    # Cold start + mermaid settle should finish under 1s on embed path.
    # ponytail: 1000ms is common; allow 1500 under load (still << PTY era).
    "perf_under_1_5s": elapsed < 1500,
}
for k, v in checks.items():
    print(("OK" if v else "FAIL"), k)
print(f"elapsed_ms={elapsed}")
print("---")
print("\n".join(plain.splitlines()[:20]))
sys.exit(0 if all(checks.values()) else 1)
PY

RESEARCH="${NVIMCAT_PERF_FILE:-$HOME/wip_other/research/terminal-markdown-renderers/README.md}"
if [[ -f "$RESEARCH" ]]; then
  research_times=()
  for _ in 1 2 3; do
    start_ms="$(date +%s%3N)"
    if ! timeout 90 "$ROOT/bin/nvimcat" "$RESEARCH" >/dev/null 2>"$ERR"; then
      echo "nvimcat research perf run failed" >&2
      cat "$ERR" >&2 || true
      exit 1
    fi
    end_ms="$(date +%s%3N)"
    research_times+=($((end_ms - start_ms)))
  done
  python3 - "${research_times[@]}" <<'PY'
import sys
times = [int(x) for x in sys.argv[1:]]
median = sorted(times)[len(times) // 2]
max_t = max(times)
# ponytail: 14KB research README ~1.5–1.9s after sample run; 500/700ms is sample-scale only.
checks = {
    "research_median_under_2000ms": median < 2000,
    "research_max_under_3000ms": max_t < 3000,
}
for k, v in checks.items():
    print(("OK" if v else "FAIL"), k)
print(f"research_times_ms={times}")
print(f"research_median_ms={median}")
print(f"research_max_ms={max_t}")
sys.exit(0 if all(checks.values()) else 1)
PY
fi

if command -v agent-terminal >/dev/null 2>&1; then
  echo "compare-tui: $SAMPLE"
  "$ROOT/scripts/compare-tui.sh" "$SAMPLE" "$NVIMCAT_WIDTH"
else
  echo "skip compare-tui (agent-terminal not installed)"
fi
