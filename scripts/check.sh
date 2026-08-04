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
checks = {
    "table_corner": "┌" in plain,
    "table_vline": "│" in plain,
    "heading": "Heading One" in plain,
    "heading_icon": ("Heading One" in first and not first.lstrip().startswith("#")),
    # non-cursor heading look: RenderMarkdownH1Bg must survive capture
    "heading_bg": "48;2;" in first_ansi,
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
