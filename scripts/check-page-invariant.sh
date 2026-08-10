#!/usr/bin/env bash
# PAGE_LINES / STITCH_HEIGHT must not change normalized capture identity.
# Default: synthetic fixture only (fast, fail-fast).
# Optional granular: NVIMCAT_CHECK_GRANULAR=1 (slow; still fail-fast on empty).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=check-lib.sh
source "$ROOT/scripts/check-lib.sh"

WALL="${NVIMCAT_CHECK_WALL:-120}"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FIX="$TMP/fixture.md"
{
  echo "# page-invariant fixture"
  echo
  echo "| A | B |"
  echo "|---|---|"
  for i in $(seq 1 1200); do
    echo "| row-$i | val-$i |"
  done
} >"$FIX"

plain_cmp() {
  python3 - "$1" "$2" "$3" "$4" <<'PY'
import re, sys
from pathlib import Path

def plain(path: str) -> str:
    raw = Path(path).read_bytes()
    if not raw:
        print(f"FAIL empty {path}", file=sys.stderr)
        raise SystemExit(1)
    text = re.sub(rb"\x1b\[[0-9;]*m", b"", raw).decode("utf-8", "replace")
    if not text.strip():
        print(f"FAIL whitespace-only {path}", file=sys.stderr)
        raise SystemExit(1)
    lines = [ln.rstrip() for ln in text.splitlines()]
    return "\n".join(lines) + ("\n" if text.endswith("\n") else "")

label, needle = sys.argv[3], sys.argv[4]
a, b = plain(sys.argv[1]), plain(sys.argv[2])
la, lb = a.count("\n"), b.count("\n")
print(f"{label}_lines={la} vs {lb}")
if needle not in a or needle not in b:
    print(f"FAIL incomplete capture missing {needle!r}", file=sys.stderr)
    raise SystemExit(1)
if "row-1100" not in a:
    print("FAIL missing late fixture row", file=sys.stderr)
    raise SystemExit(1)
if a != b:
    print(f"FAIL {label} changed output: lines {la} vs {lb}", file=sys.stderr)
    raise SystemExit(1)
print(f"OK {label}")
PY
}

echo "fixture PAGE_LINES …"
export NVIMCAT_PAGE_LINES=100
nvimcat_capture "$WALL" "$TMP/p100" -- --width 100 "$FIX"
export NVIMCAT_PAGE_LINES=250
nvimcat_capture "$WALL" "$TMP/p250" -- --width 100 "$FIX"
unset NVIMCAT_PAGE_LINES
plain_cmp "$TMP/p100" "$TMP/p250" "page-invariant" "page-invariant"

# STITCH_HEIGHT identity is a harder soft-break property; opt-in until stable.
if [[ "${NVIMCAT_CHECK_STITCH_HEIGHT:-}" == "1" ]]; then
  echo "fixture STITCH_HEIGHT …"
  export NVIMCAT_STITCH_HEIGHT=80
  nvimcat_capture "$WALL" "$TMP/s80" -- --width 100 "$FIX"
  export NVIMCAT_STITCH_HEIGHT=120
  nvimcat_capture "$WALL" "$TMP/s120" -- --width 100 "$FIX"
  unset NVIMCAT_STITCH_HEIGHT
  plain_cmp "$TMP/s80" "$TMP/s120" "stitch-height-invariant" "page-invariant"
fi

GFIX="${1:-$HOME/wip_other/src_cavanaug/zoom-cli/.opencode/skills/zoom-skills/oauth/references/granular-scopes.md}"
if [[ "${NVIMCAT_CHECK_GRANULAR:-}" == "1" && -f "$GFIX" ]]; then
  GWALL="${NVIMCAT_CHECK_GRANULAR_WALL:-180}"
  echo "granular PAGE_LINES (optional) wall=${GWALL}s …"
  export NVIMCAT_PAGE_LINES=100
  nvimcat_capture "$GWALL" "$TMP/g100" -- --width 120 "$GFIX"
  export NVIMCAT_PAGE_LINES=250
  nvimcat_capture "$GWALL" "$TMP/g250" -- --width 120 "$GFIX"
  unset NVIMCAT_PAGE_LINES
  plain_cmp "$TMP/g100" "$TMP/g250" "granular-page-invariant" "Granular"
fi

echo "OK page-invariant"
