#!/usr/bin/env bash
# Shared fail-fast helpers for nvimcat check scripts.
# Caller must set ROOT to the repo/worktree root before using these.
# Source this; do not execute.

# Run nvimcat under a hard wall. Never swallow stderr into /dev/null.
# Usage: nvimcat_capture WALL OUTFILE -- nvimcat-args...
# Writes stderr to OUTFILE.err. Fails fast if empty/timeout.
nvimcat_capture() {
  local wall="$1" out="$2"
  shift 2
  if [[ "${1:-}" == "--" ]]; then shift; fi
  local err="${out}.err"
  local bin="${ROOT}/bin/nvimcat"
  local guard="${ROOT}/scripts/run-guarded.sh"
  local inner_timeout="${NVIMCAT_TIMEOUT:-}"
  if [[ -z "$inner_timeout" ]]; then
    inner_timeout=$((wall > 20 ? wall - 15 : wall))
  fi
  local rc=0

  if [[ -x "$guard" ]]; then
    set +e
    "$guard" "$wall" -- env NVIMCAT_TIMEOUT="$inner_timeout" \
      "$bin" "$@" >"$out" 2>"$err"
    rc=$?
    set -e
  else
    set +e
    timeout --kill-after=10 "${wall}s" \
      env NVIMCAT_TIMEOUT="$inner_timeout" \
      "$bin" "$@" >"$out" 2>"$err"
    rc=$?
    set -e
  fi

  if [[ $rc -eq 124 ]]; then
    echo "FAIL nvimcat wall=${wall}s exceeded" >&2
    [[ -s "$err" ]] && tail -n 20 "$err" >&2
    return 124
  fi
  if [[ $rc -ne 0 ]]; then
    echo "FAIL nvimcat exit=$rc" >&2
    [[ -s "$err" ]] && tail -n 20 "$err" >&2
    return "$rc"
  fi
  if [[ ! -s "$out" ]]; then
    echo "FAIL empty capture (0 bytes) — not a 1-line success" >&2
    [[ -s "$err" ]] && tail -n 20 "$err" >&2
    return 1
  fi
  return 0
}

# Validate ANSI capture: min lines + required needles. Empty → hard fail.
# Usage: assert_capture OUTFILE MIN_LINES NEEDLE [NEEDLE...]
assert_capture() {
  local out="$1" min_lines="$2"
  shift 2
  python3 - "$out" "$min_lines" "$@" <<'PY'
import re, sys
from pathlib import Path

path, min_lines = Path(sys.argv[1]), int(sys.argv[2])
needles = sys.argv[3:]
raw = path.read_bytes()
if not raw:
    print("FAIL empty capture bytes=0", file=sys.stderr)
    raise SystemExit(1)
plain = re.sub(rb"\x1b\[[0-9;]*m", b"", raw).decode("utf-8", "replace")
# True empty / whitespace-only is failure (empty stdin used to report as "1 line").
if not plain.strip():
    print("FAIL whitespace-only capture", file=sys.stderr)
    raise SystemExit(1)
lines = plain.count("\n") + (0 if plain.endswith("\n") else 1)
print(f"lines={lines} bytes={len(raw)}")
if lines < min_lines:
    print(f"FAIL too short lines={lines} min={min_lines}", file=sys.stderr)
    raise SystemExit(1)
for n in needles:
    if n not in plain:
        print(f"FAIL missing needle {n!r}", file=sys.stderr)
        raise SystemExit(1)
Path(str(path) + ".meta").write_text(f"lines={lines}\n")
PY
}
