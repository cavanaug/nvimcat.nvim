#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp --suffix=.md)"
OUT="$(mktemp)"
trap 'rm -f "$TMP" "$OUT"' EXIT

{
  echo "# warning regression"
  echo
  echo "| API Endpoint | Granular Scopes |"
  echo "|---|---|"
  for i in $(seq 1 1500); do
    echo "| upload-$i | video_mgmt:write:file-$i |"
  done
} >"$TMP"

for _ in 1 2 3; do
  timeout 90 "$ROOT/bin/nvimcat" "$TMP" >"$OUT"
  python3 - "$OUT" <<'PY'
import re
import sys
from pathlib import Path

plain = re.sub(r"\x1b\[[0-9;]*m", "", Path(sys.argv[1]).read_text())
for needle in ("Client marksman quit", "Warning", "Indexing", "Indexed"):
    if needle in plain:
        raise SystemExit(f"FAIL captured UI noise: {needle}")
PY
done
echo "OK no captured UI noise"
