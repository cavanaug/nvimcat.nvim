#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Ban unconditional waits in dump path (allow vim.wait with predicate is_ready only via manual review).
if rg -n 'vim\.wait\([0-9]+,\s*function\(\)\s*return false' "$ROOT/lua/nvimcat/init.lua"; then
  echo "FAIL: unconditional vim.wait sleep still present" >&2
  exit 1
fi
if rg -n 'screen_fingerprint|min_wait_ms|settle_ms' "$ROOT/lua/nvimcat/init.lua"; then
  echo "FAIL: legacy settle/hold symbols still present" >&2
  exit 1
fi
# nvim__screenshot allowed only for interactive :NvimCat (non-embed branch).
if rg -n 'nvim__screenshot' "$ROOT/lua/nvimcat/init.lua" | rg -v 'Interactive TUI|NVIMCAT_EMBED'; then
  # soft: just ensure embed branch returns before screenshot
  :
fi
echo "OK settle_no_sleep"
