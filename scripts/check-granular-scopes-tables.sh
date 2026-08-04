#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE="${1:-$HOME/wip_other/src_cavanaug/zoom-cli/.opencode/skills/zoom-skills/oauth/references/granular-scopes.md}"
OUT="$(mktemp)"
trap 'rm -f "$OUT"' EXIT

if [[ ! -f "$FIXTURE" ]]; then
  echo "SKIP missing fixture: $FIXTURE"
  exit 0
fi

timeout 120 "$ROOT/bin/nvimcat" "$FIXTURE" >"$OUT"

python3 - "$OUT" <<'PY'
import re
import sys
from pathlib import Path

plain = re.sub(r"\x1b\[[0-9;]*m", "", Path(sys.argv[1]).read_text())
raw = [
    (line_no, line.strip())
    for line_no, line in enumerate(plain.splitlines(), 1)
    if line.lstrip().startswith("|") and line.count("|") >= 2
]
if raw:
    print(f"FAIL found {len(raw)} raw table lines", file=sys.stderr)
    for line_no, line in raw[:20]:
        print(f"{line_no}: {line}", file=sys.stderr)
    raise SystemExit(1)
print("OK all granular-scopes tables rendered")
PY
