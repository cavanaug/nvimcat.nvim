#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
start=$(date +%s%3N)
python3 "$ROOT/bin/nvimcat" --smoke 80
end=$(date +%s%3N)
echo "embed_smoke_ms=$((end - start))"
