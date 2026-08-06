#!/usr/bin/env bash
# Prove tall-buffer capture starts at topline=1 and is byte-identical across runs
# (guards LazyVim deferred last-loc racing dump's view reset).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE="${1:-$HOME/wip_other/src_cavanaug/zoom-cli/.opencode/skills/zoom-skills/oauth/references/granular-scopes.md}"
TMPDIR_RUN=$(mktemp -d)
trap 'rm -rf "$TMPDIR_RUN"' EXIT

HEAD_NEEDLE="Granular OAuth Scopes"
TAIL_NEEDLE="List schedules"
if [[ ! -f "$FIXTURE" ]]; then
  FIXTURE="$TMPDIR_RUN/fixture.md"
  {
    echo "# scroll-stitch fixture"
    echo
    echo "| A | B |"
    echo "|---|---|"
    for i in $(seq 1 400); do
      echo "| row-$i | val-$i |"
    done
  } >"$FIXTURE"
  HEAD_NEEDLE="scroll-stitch"
  TAIL_NEEDLE="row-350"
fi

declare -a LINE_COUNTS=()
for i in 1 2 3; do
  out="$TMPDIR_RUN/run-$i.out"
  meta="$TMPDIR_RUN/run-$i.meta"
  timeout 180 "$ROOT/bin/nvimcat" --width 120 "$FIXTURE" >"$out"
  python3 - "$out" "$HEAD_NEEDLE" "$TAIL_NEEDLE" "$meta" <<'PY'
import re, sys
from pathlib import Path
raw = Path(sys.argv[1]).read_bytes()
head_needle, tail_needle, meta_path = sys.argv[2], sys.argv[3], sys.argv[4]
plain = re.sub(rb"\x1b\[[0-9;]*m", b"", raw).decode("utf-8", "replace")
lines = plain.count("\n") + (0 if plain.endswith("\n") else 1)
head_ok = head_needle in plain
tail_ok = tail_needle in plain
Path(meta_path).write_text(
    f"lines={lines}\nhead_ok={int(head_ok)}\ntail_ok={int(tail_ok)}\n"
)
print(f"lines={lines} head_ok={head_ok} tail_ok={tail_ok}")
if not head_ok:
    print("FAIL missing document head (likely started at EOF)", file=sys.stderr)
    raise SystemExit(1)
if not tail_ok:
    print("FAIL missing late content (incomplete stitch)", file=sys.stderr)
    raise SystemExit(1)
if lines < 300:
    print(f"FAIL too short lines={lines}", file=sys.stderr)
    raise SystemExit(1)
PY
  # shellcheck disable=SC1090
  source "$meta"
  LINE_COUNTS+=("$lines")
  echo "run=$i lines=$lines"
done

if [[ "${LINE_COUNTS[0]}" != "${LINE_COUNTS[1]}" || "${LINE_COUNTS[1]}" != "${LINE_COUNTS[2]}" ]]; then
  echo "FAIL non-deterministic line counts: ${LINE_COUNTS[*]}" >&2
  exit 1
fi
echo "OK deterministic-capture lines=${LINE_COUNTS[0]}"
