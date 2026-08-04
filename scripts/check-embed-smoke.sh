#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export NVIMCAT_ROOT="$ROOT"
start="$(date +%s%3N)"
python3 "$ROOT/bin/nvimcat-embed" --smoke 80
end="$(date +%s%3N)"
elapsed=$((end - start))
echo "embed_smoke_ms=$elapsed"
# Floor check: must beat PTY (~1100ms). Target headless-class.
test "$elapsed" -lt 800
