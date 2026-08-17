#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE="${1:-$HOME/wip_other/src_cavanaug/zoom-cli/.opencode/skills/zoom-skills/oauth/references/granular-scopes.md}"
WALL="${NVIMCAT_CHECK_GRANULAR_WALL:-120}"
MAX_SECONDS="${NVIMCAT_CHECK_GRANULAR_MAX_SECONDS:-45}"
OUT="$(mktemp)"
trap 'rm -f "$OUT"' EXIT

if [[ ! -f "$FIXTURE" ]]; then
  echo "SKIP missing fixture: $FIXTURE"
  exit 0
fi

START_MS="$(date +%s%3N)"
timeout "$WALL" "$ROOT/bin/nvimcat" --width 120 "$FIXTURE" >"$OUT"
END_MS="$(date +%s%3N)"
ELAPSED_MS=$((END_MS - START_MS))

python3 - "$OUT" "$FIXTURE" "$ELAPSED_MS" "$MAX_SECONDS" <<'PY'
import re
import sys
from pathlib import Path

output = Path(sys.argv[1])
fixture = Path(sys.argv[2])
elapsed_ms = int(sys.argv[3])
max_ms = int(float(sys.argv[4]) * 1000)
plain = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", output.read_text())
lines = plain.splitlines()
source = fixture.read_text()
source_lines = source.count("\n")
source_tables = sum(
    bool(re.match(r"^\s*\|\s*:?-{3}", line)) for line in source.splitlines()
)
output_lines = len(lines)

# Catch both truncation and stitch overlap amplification. Rendering may add
# borders and wrapping, but it must stay close to the source document size.
min_output_lines = source_lines * 9 // 10
max_output_lines = source_lines + max(250, source_lines // 4)
if not min_output_lines <= output_lines <= max_output_lines:
    print(
        f"FAIL output line count source={source_lines} "
        f"output={output_lines} range={min_output_lines}..{max_output_lines}",
        file=sys.stderr,
    )
    raise SystemExit(1)

for marker in ("Granular OAuth Scopes", "Get ZVA transcripts"):
    if marker not in plain:
        print(f"FAIL missing completeness marker {marker!r}", file=sys.stderr)
        raise SystemExit(1)

raw = [
    (line_no, line.strip())
    for line_no, line in enumerate(lines, 1)
    if line.lstrip().startswith("|") and line.count("|") >= 2
]
if raw:
    print(f"FAIL found {len(raw)} raw table lines", file=sys.stderr)
    for line_no, line in raw[:20]:
        print(f"{line_no}: {line}", file=sys.stderr)
    raise SystemExit(1)

tops = sum(line.lstrip().startswith("┌") for line in lines)
bottoms = sum(line.lstrip().startswith("└") for line in lines)
if tops != source_tables or bottoms != source_tables:
    print(
        f"FAIL table count source={source_tables} top={tops} bottom={bottoms}",
        file=sys.stderr,
    )
    raise SystemExit(1)

inside_table = False
for index, line in enumerate(lines, 1):
    stripped = line.lstrip()
    if stripped.startswith("┌"):
        if inside_table:
            print(f"FAIL nested table start at output line {index}", file=sys.stderr)
            raise SystemExit(1)
        inside_table = True
    elif stripped.startswith("└"):
        if not inside_table:
            print(f"FAIL unmatched table end at output line {index}", file=sys.stderr)
            raise SystemExit(1)
        inside_table = False
    elif stripped.startswith(("│", "├")) and not inside_table:
        print(f"FAIL table body outside frame at output line {index}", file=sys.stderr)
        raise SystemExit(1)
    elif inside_table and not stripped:
        print(f"FAIL blank stitch seam inside table at output line {index}", file=sys.stderr)
        raise SystemExit(1)
if inside_table:
    print("FAIL unterminated table at end of output", file=sys.stderr)
    raise SystemExit(1)

if elapsed_ms > max_ms:
    print(
        f"FAIL granular-scopes render took {elapsed_ms}ms max={max_ms}ms",
        file=sys.stderr,
    )
    raise SystemExit(1)

print(
    f"OK granular-scopes source_lines={source_lines} output_lines={output_lines} "
    f"tables={tops} elapsed_ms={elapsed_ms}"
)
PY
