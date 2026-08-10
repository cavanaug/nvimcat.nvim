#!/usr/bin/env bash
# Determinism on a tall non-markdown fixture (comments + blanks).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=check-lib.sh
source "$ROOT/scripts/check-lib.sh"

WALL="${NVIMCAT_CHECK_WALL:-120}"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FIXTURE="$TMP/tall.lua"
{
  echo "-- tall non-md stitch fixture"
  for i in $(seq 1 250); do
    echo "local x$i = $i"
    if (( i % 40 == 0 )); then
      echo ""
      echo "-- section $i"
    fi
  done
} >"$FIXTURE"

declare -a COUNTS=()
for i in 1 2 3; do
  out="$TMP/run-$i.out"
  echo "run=$i wall=${WALL}s …"
  nvimcat_capture "$WALL" "$out" -- --width 100 "$FIXTURE"
  assert_capture "$out" 200 "tall non-md"
  # shellcheck disable=SC1090
  source "${out}.meta"
  COUNTS+=("$lines")
  echo "run=$i lines=$lines"
done
if [[ "${COUNTS[0]}" != "${COUNTS[1]}" || "${COUNTS[1]}" != "${COUNTS[2]}" ]]; then
  echo "FAIL non-deterministic: ${COUNTS[*]}" >&2
  exit 1
fi
cmp -s "$TMP/run-1.out" "$TMP/run-2.out"
cmp -s "$TMP/run-2.out" "$TMP/run-3.out"
echo "OK deterministic-non-md lines=${COUNTS[0]}"
