#!/usr/bin/env bash
# Run a check/command with a hard wall-clock limit and process-group kill so
# orphan `nvim --embed` processes cannot survive agent interrupts / hangs.
#
# Usage: scripts/run-guarded.sh [WALL_SECONDS] -- command args...
#    or: scripts/run-guarded.sh command args...   # default 240s
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

WALL=240
if [[ "${1:-}" =~ ^[0-9]+$ ]]; then
  WALL="$1"
  shift
fi
if [[ "${1:-}" == "--" ]]; then
  shift
fi
if [[ $# -lt 1 ]]; then
  echo "usage: $0 [WALL_SECONDS] [--] command..." >&2
  exit 2
fi

export NVIMCAT_ROOT="${NVIMCAT_ROOT:-$ROOT}"
# Inner nvimcat deadline slightly under wall so it tries clean close first.
if [[ -z "${NVIMCAT_TIMEOUT:-}" ]]; then
  export NVIMCAT_TIMEOUT=$(( WALL > 30 ? WALL - 15 : WALL ))
fi

# GNU timeout: new process group; kill group on expiry; escalate to KILL.
set +e
timeout --kill-after=15 --foreground "${WALL}s" "$@"
rc=$?
set -e

# Reap any nvimcat embeds still holding this repo root (do NOT pkill -f —
# that can match and kill the reaper shell itself).
reap_embeds() {
  local sig="$1"
  local pid
  while read -r pid; do
    [[ -n "$pid" ]] || continue
    kill "-$sig" "$pid" 2>/dev/null || true
  done < <(ps -eo pid=,args= | awk -v root="$ROOT" '
    index($0, "nvim --embed") && index($0, root) { print $1 }
  ')
}
reap_embeds TERM
sleep 0.2
reap_embeds KILL

if [[ $rc -eq 124 ]]; then
  echo "run-guarded: WALL=${WALL}s exceeded; killed process group" >&2
fi
exit "$rc"
