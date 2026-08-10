#!/usr/bin/env bash
# Prove tall-buffer capture starts at topline=1 and is byte-identical across runs.
# Fail-fast: empty captures and walls abort immediately (no silent "1 line").
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=check-lib.sh
source "$ROOT/scripts/check-lib.sh"

FIXTURE="${1:-$HOME/wip_other/src_cavanaug/zoom-cli/.opencode/skills/zoom-skills/oauth/references/granular-scopes.md}"
# Per-run wall (outer). Inner NVIMCAT_TIMEOUT is derived by nvimcat_capture.
WALL="${NVIMCAT_CHECK_WALL:-150}"
TMPDIR_RUN=$(mktemp -d)
trap 'rm -rf "$TMPDIR_RUN"' EXIT

HEAD_NEEDLE="Granular OAuth Scopes"
TAIL_NEEDLE="List schedules"
MIN_LINES=300
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
  echo "run=$i wall=${WALL}s …"
  nvimcat_capture "$WALL" "$out" -- --width 120 "$FIXTURE"
  assert_capture "$out" "$MIN_LINES" "$HEAD_NEEDLE" "$TAIL_NEEDLE"
  # shellcheck disable=SC1090
  source "${out}.meta"
  LINE_COUNTS+=("$lines")
  echo "run=$i lines=$lines"
done

if [[ "${LINE_COUNTS[0]}" != "${LINE_COUNTS[1]}" || "${LINE_COUNTS[1]}" != "${LINE_COUNTS[2]}" ]]; then
  echo "FAIL non-deterministic line counts: ${LINE_COUNTS[*]}" >&2
  exit 1
fi
cmp -s "$TMPDIR_RUN/run-1.out" "$TMPDIR_RUN/run-2.out"
cmp -s "$TMPDIR_RUN/run-2.out" "$TMPDIR_RUN/run-3.out"
echo "OK deterministic-capture lines=${LINE_COUNTS[0]}"
