#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp --suffix=.md)"
trap 'rm -f "$TMP"' EXIT
cat >"$TMP" <<'MD'
# Title

```
code with

blank inside
```

## Next
MD

# ponytail: extend rtp with nvim-treesitter runtime so headless -u NONE gets markdown parser
TS_RUNTIME="${NVIM_TS_RUNTIME:-$HOME/.local/share/nvim/lazy/nvim-treesitter}"
NVIM_ARGS=(
  --headless -u NONE
  -c "set rtp^=$ROOT"
)
if [[ -d "$TS_RUNTIME" ]]; then
  NVIM_ARGS+=(-c "set rtp^=$TS_RUNTIME")
fi
NVIM_ARGS+=(
  -c "edit $TMP"
  -c "setfiletype markdown"
  -c "lua local sb=require('nvimcat.soft_break')
       local a=sb.treesitter_addon(0)
       local function fail(msg)
         error(msg .. ': ' .. vim.inspect(a))
       end
       local ok = false
       for _, l in ipairs(a.extra_breaks or {}) do
         if l == 1 then ok = true end
       end
       if not ok then fail('missing heading break') end
       if #(a.suppress_blanks or {}) < 1 then fail('missing suppress') end
       local blank_suppressed = false
       for _, r in ipairs(a.suppress_blanks) do
         local s, e = r[1] or r.start, r[2] or r['end']
         if s and e and s <= 6 and 6 <= e then blank_suppressed = true end
       end
       if not blank_suppressed then fail('blank inside fence not suppressed') end
       print('OK soft-break-addon')"
  -c "qa!"
)

nvim "${NVIM_ARGS[@]}"
