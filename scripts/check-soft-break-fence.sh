#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=check-lib.sh
source "$ROOT/scripts/check-lib.sh"
TMP="$(mktemp --suffix=.md)"
OUT="$(mktemp)"
trap 'rm -f "$TMP" "$OUT" "$OUT.err"' EXIT
# Enough content that stitch runs; fence with internal blank must stay intact in ANSI
{
  echo "# fence soft-break"
  echo
  for i in $(seq 1 50); do echo "para-$i"; echo; done
  echo '```'
  echo 'line-a'
  echo
  echo 'line-b'
  echo '```'
  echo
  echo "## after"
  echo
  echo "done"
} >"$TMP"
nvimcat_capture 90 "$OUT" -- --width 100 "$TMP"
assert_capture "$OUT" 20 "line-a" "line-b" "after"
python3 - "$OUT" <<'PY'
import re, sys
from pathlib import Path
plain = re.sub(r"\x1b\[[0-9;]*m", "", Path(sys.argv[1]).read_text())
# Both fence body lines must appear; blank between them must not drop line-b
ia, ib = plain.find("line-a"), plain.find("line-b")
assert ia != -1 and ib != -1 and ia < ib, (ia, ib)
print("OK soft-break-fence")
PY
