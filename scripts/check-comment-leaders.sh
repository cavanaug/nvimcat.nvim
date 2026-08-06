#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
chmod +x "$ROOT/scripts/check-comment-leaders.sh" 2>/dev/null || true
nvim --clean -n --headless \
  --cmd "set rtp^=${ROOT}" \
  -c 'lua local sb=require("nvimcat.soft_break")
local function has(t, leader, blank)
  for _, x in ipairs(t) do
    if x.leader == leader then
      assert(x.blank_required == blank, leader)
      return true
    end
  end
  return false
end
local t = sb.parse_leaders("# %s", "")
assert(has(t, "#", true))
local t2 = sb.parse_leaders("/*%s*/", "s1:/*,mb:*,ex:*/,://,b:#,:%,:XCOMM,n:>,fb:-")
assert(has(t2, "//", false))
assert(has(t2, "#", true))
assert(has(t2, "%", false))
assert(has(t2, "XCOMM", false))
for _, x in ipairs(t2) do
  assert(x.leader ~= "-" and x.leader ~= ">")
end
local t3 = sb.parse_leaders("<!--%s-->", "")
assert(#t3 == 0)
print("OK comment-leaders")
' \
  -c "qa!"
