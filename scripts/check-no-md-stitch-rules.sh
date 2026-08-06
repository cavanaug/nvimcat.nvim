#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if rg -n '_content_block_end|_is_table_line' "$ROOT/bin/nvimcat"; then
  echo "FAIL: markdown stitch helpers still present in bin/nvimcat" >&2
  exit 1
fi
echo "OK no-md-stitch-rules"
