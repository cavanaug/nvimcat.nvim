#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp --suffix=.md)
trap 'rm -f "$TMP" "$TMP.out" "$TMP.err"' EXIT
NVIM_BIN="${NVIMCAT_NVIM_BIN:-nvim}"
if [[ -z "${VIMRUNTIME:-}" && "$NVIM_BIN" == */build/bin/nvim ]]; then
  VIMRUNTIME="$(cd "$(dirname "$NVIM_BIN")/../../runtime" && pwd)"
fi
if [[ -n "${VIMRUNTIME:-}" ]]; then
  export VIMRUNTIME
fi

{
  echo "# compose fixture"
  echo
  echo "compose with **bold** and *italic*."
  echo
  echo "| API Endpoint | Granular Scopes |"
  echo "|--------------|-----------------|"
  echo "| Get account  | account:read    |"
  for i in $(seq 1 300); do
    echo "compose-row-$i"
  done
} >"$TMP"

PATH="${NVIMCAT_NVIM_BIN:+$(dirname "$NVIMCAT_NVIM_BIN"):}$PATH" \
  NVIMCAT_NVIM_BIN="$NVIM_BIN" \
  NVIMCAT_COMPOSE=1 \
  NVIMCAT_VERBOSE=1 \
  "$ROOT/bin/nvimcat" "$TMP" >"$TMP.out" 2>"$TMP.err"

python3 - "$TMP.out" "$ROOT" <<'PY'
import re
import runpy
import sys
from pathlib import Path

raw = Path(sys.argv[1]).read_bytes()
plain = re.sub(rb"\x1b\[[0-9;]*m", b"", raw).decode("utf-8", "replace")
assert "compose fixture" in plain
assert "compose with bold and italic." in plain
assert "**bold**" not in plain
assert "│ API Endpoint" in plain
assert "| API Endpoint |" not in plain
assert "compose-row-300" in plain
ansi = runpy.run_path(str(Path(sys.argv[2]) / "bin" / "nvimcat"))["_compose_row_to_ansi"]
assert b"\x1b[1;38;2;255;0;0mA" in ansi({
    "cells": [{"text": "A", "highlight": {"bold": True, "foreground": 0xFF0000}}]
})
print("OK compose")
PY
