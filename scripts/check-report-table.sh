#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp --suffix=.md)"
OUT="$(mktemp)"
trap 'rm -f "$TMP" "$OUT"' EXIT

{
  echo "# late table regression"
  echo
  echo "| API Endpoint | Granular Scopes |"
  echo "|---|---|"
  for i in $(seq 1 1500); do
    echo "| upload-$i | video_mgmt:write:file-$i |"
  done
  echo
  echo "### Report"
  echo
  echo "| API Endpoint | Granular Scopes |"
  echo "|---|---|"
  echo "| Get ZVA engagements | \`zva:read:list_engagements:admin\` |"
  echo "| Get ZVA query details | \`zva:read:list_queries:admin\` |"
  echo "| Get ZVA Surveys | \`zva:read:list_surveys:admin\` |"
} >"$TMP"

timeout 90 "$ROOT/bin/nvimcat" "$TMP" >"$OUT"

python3 - "$OUT" <<'PY'
import re
import sys
from pathlib import Path

plain = re.sub(r"\x1b\[[0-9;]*m", "", Path(sys.argv[1]).read_text())
first_table = plain.split("### Report", 1)[0]
report = plain.rsplit("### Report", 1)[-1]
raw_first = [
    line for line in first_table.splitlines()
    if line.lstrip().startswith("|") and line.count("|") >= 2
]
if raw_first:
    raise SystemExit("FAIL initial table was not rendered")
if "┌" not in report or "Get ZVA engagements" not in report:
    raise SystemExit("FAIL late Report table was not rendered")
print("OK initial and late tables rendered")
PY
