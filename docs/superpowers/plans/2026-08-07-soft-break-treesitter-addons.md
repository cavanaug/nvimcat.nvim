# Soft-break Treesitter Addons Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Discover markdown soft-break seams (headings, fence **open**) and blank-suppression ranges (inside fences) via treesitter, while keeping universal defaults (blank + comment leaders).

**Architecture:** Lua `nvimcat.soft_break` gains an addon RPC returning `{ extra_breaks, suppress_blanks }` from the buffer markdown parser. Python `_is_soft_break_line` / `_soft_break_segments` take that addon; stitch fetches it once with comment leaders. No TS → empty addon (parent behavior).

**Tech Stack:** Python 3 (`bin/nvimcat`), Lua (`lua/nvimcat/soft_break.lua`), bash checks, Neovim treesitter markdown grammar.

**Spec:** `docs/superpowers/specs/2026-08-07-soft-break-treesitter-addons-design.md`  
**Parent:** `docs/superpowers/specs/2026-08-06-soft-break-stitch-design.md`

## Global Constraints

- Defaults unchanged: blank **or** whole-line comment leaders from `commentstring` / `comments`.
- No hardcoded filetype→prefix content matchers (no `line.startswith("```")` tables for discovery).
- No resurrection of `_content_block_end` / `_is_table_line` / fence viewport-grow on the stitch advance path (`scripts/check-no-md-stitch-rules.sh` must still pass).
- Treesitter discovery in Lua is allowed; query/walk failure → empty addon.
- Markdown addon v1: ATX/setext heading **start** lines + fence **open** delimiter line → `extra_breaks`; fenced_code_block interior → `suppress_blanks`.
- Hard-cut at `UI_MAX_LINES` (1000) unchanged.
- Prefer smallest diff; do not expand to thematic breaks / HTML / other filetypes in this plan.
- Worktree: `.worktrees/soft-break-stitch` (branch `soft-break-stitch`). Use `./scripts/run-guarded.sh` for any nvimcat capture; never unbounded granular loops in subagents.

## File map

| File | Role |
|------|------|
| `lua/nvimcat/soft_break.lua` | Comment leaders (existing) + `treesitter_addon(buf)` → `{extra_breaks, suppress_blanks}` |
| `bin/nvimcat` | Extend soft-break helpers + fetch addon RPC; wire stitch |
| `scripts/check-soft-break-segments.sh` | Pure-Python unit: extras + suppress |
| `scripts/check-soft-break-addon.sh` | Headless nvim: markdown TS addon on a tiny fixture |
| `scripts/check-soft-break-fence.sh` | Guarded nvimcat: fence with internal blank must not leak mid-fence seam / raw split symptoms |
| `scripts/check-no-md-stitch-rules.sh` | Unchanged gate |

---

### Task 1: Python soft-break predicate + segments accept addon (TDD)

**Files:**
- Modify: `scripts/check-soft-break-segments.sh`
- Modify: `bin/nvimcat` (`_is_soft_break_line`, `_soft_break_segments` only — wire fetch in Task 3)

**Interfaces:**
- Consumes: existing leaders API
- Produces:
  - `_line_in_ranges(line_1based: int, ranges: list[tuple[int, int]]) -> bool`
  - `_is_soft_break_line(line: str, leaders: list[tuple[str, bool]], *, line_no: int = 1, extra_breaks: set[int] | None = None, suppress_blanks: list[tuple[int, int]] | None = None) -> bool`
  - `_soft_break_segments(lines, leaders, ui_max=1000, extra_breaks=None, suppress_blanks=None) -> list[tuple[int, int]]`
  - Predicate: `line_no in extra_breaks` OR `(blank and not in suppress)` OR comment-leader match

- [ ] **Step 1: Extend failing assertions in `scripts/check-soft-break-segments.sh`**

Append before `print("OK soft-break-segments")`:

```python
# extra break (heading) without blank
lines = ["a", "## H", "b"]
assert ns._soft_break_segments(lines, [], extra_breaks={2}) == [(1, 2), (3, 3)]

# blank suppressed inside fence range
lines = ["```", "", "x", "```", ""]
# suppress interior blanks: lines 2..3 (after open, before close) — blank at 2 ignored
assert ns._soft_break_segments(
    lines, [], extra_breaks={1}, suppress_blanks=[(2, 3)]
) == [(1, 1), (2, 5)]
# explanation: seg1 ends at fence open (1); seg2 runs 2..5 including trailing blank soft break at 5

# blank outside suppress still breaks
lines = ["a", "", "b"]
assert ns._soft_break_segments(lines, [], suppress_blanks=[(10, 12)]) == [(1, 2), (3, 3)]

# comment still breaks even inside suppress
leaders = [("#", True)]
lines = ["```", "# note", "```"]
assert ns._soft_break_segments(
    lines, leaders, extra_breaks={1}, suppress_blanks=[(2, 2)]
) == [(1, 1), (2, 2), (3, 3)]
```

Adjust expected tuples if the chosen inclusivity for suppress vs fence-open differs — **implement so these expectations hold** (fence open is extra break; interior blank suppressed; trailing blank after close still breaks).

- [ ] **Step 2: Run check — expect FAIL**

```bash
/bin/bash --noprofile --norc scripts/check-soft-break-segments.sh
```

Expected: FAIL (TypeError / unexpected kwargs / wrong segments)

- [ ] **Step 3: Implement minimal Python changes in `bin/nvimcat`**

Update signatures and logic:

```python
def _line_in_ranges(line_1based: int, ranges: list[tuple[int, int]] | None) -> bool:
    if not ranges:
        return False
    for a, b in ranges:
        if a <= line_1based <= b:
            return True
    return False


def _is_soft_break_line(
    line: str,
    leaders: list[tuple[str, bool]],
    *,
    line_no: int = 1,
    extra_breaks: set[int] | frozenset[int] | None = None,
    suppress_blanks: list[tuple[int, int]] | None = None,
) -> bool:
    if extra_breaks and line_no in extra_breaks:
        return True
    if not line.strip():
        return not _line_in_ranges(line_no, suppress_blanks)
    # existing leader match unchanged...
```

In `_soft_break_segments`, pass `line_no=end` into `_is_soft_break_line` with the new kwargs. Normalize `extra_breaks` to a set.

Keep backward compatible: omitting addon kwargs = old behavior (existing asserts must still pass).

- [ ] **Step 4: Re-run check — expect PASS**

```bash
/bin/bash --noprofile --norc scripts/check-soft-break-segments.sh
```

Expected: `OK soft-break-segments`

- [ ] **Step 5: Commit**

```bash
git add bin/nvimcat scripts/check-soft-break-segments.sh
git commit -m "$(cat <<'EOF'
feat: soft-break segments honor TS addon extras/suppress

EOF
)"
```

---

### Task 2: Lua treesitter markdown addon

**Files:**
- Modify: `lua/nvimcat/soft_break.lua`
- Create: `scripts/check-soft-break-addon.sh`

**Interfaces:**
- Consumes: buffer with markdown filetype + treesitter markdown parser
- Produces:
  - `M.treesitter_addon(buf?) -> { extra_breaks: integer[], suppress_blanks: { {start, end} | integer[] } }`
  - On failure: `{ extra_breaks = {}, suppress_blanks = {} }`
  - Markdown only when `vim.bo[buf].filetype` is `markdown` or starts with `markdown` (e.g. `markdown.mdx`); else empty
  - Heading: start line of `atx_heading` / `setext_heading` (1-based)
  - Fence open: start line of first `fenced_code_block_delimiter` child of each `fenced_code_block`
  - Suppress: lines strictly after open delimiter line through line before close delimiter (or through block end−1 if no close); empty interior → no range

- [ ] **Step 1: Write failing headless check**

Create `scripts/check-soft-break-addon.sh`:

```bash
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
# Headless: load soft_break only (rtp), edit file, call addon
nvim --headless -u NONE \
  -c "set rtp^=$ROOT" \
  -c "edit $TMP" \
  -c "setfiletype markdown" \
  -c "lua local a=require('nvimcat.soft_break').treesitter_addon(0)
       local ok = false
       for _, l in ipairs(a.extra_breaks or {}) do if l == 1 then ok = true end end
       assert(ok, 'missing heading break')
       assert(#(a.suppress_blanks or {}) >= 1, 'missing suppress')
       print('OK soft-break-addon')" \
  -c "qa!"
```

(Fixture line numbers: adjust asserts to match real file after write — `# Title` is line 1; fence open is the `` ``` `` line; blank inside fence must fall in a suppress range.)

Prefer a Lua one-liner that prints `vim.inspect(addon)` on failure for easier debug.

- [ ] **Step 2: Run check — expect FAIL**

```bash
chmod +x scripts/check-soft-break-addon.sh
/bin/bash --noprofile --norc scripts/check-soft-break-addon.sh
```

Expected: FAIL (`treesitter_addon` nil / assert)

- [ ] **Step 3: Implement `treesitter_addon` in `lua/nvimcat/soft_break.lua`**

Sketch (implement fully; handle pcall):

```lua
function M.treesitter_addon(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local ft = vim.bo[buf].filetype or ""
  if ft ~= "markdown" and not ft:match("^markdown") then
    return { extra_breaks = {}, suppress_blanks = {} }
  end
  local ok, parser = pcall(vim.treesitter.get_parser, buf, "markdown")
  if not ok or not parser then
    return { extra_breaks = {}, suppress_blanks = {} }
  end
  local trees = parser:parse()
  local root = trees and trees[1] and trees[1]:root()
  if not root then
    return { extra_breaks = {}, suppress_blanks = {} }
  end
  local extra, suppress, seen = {}, {}, {}
  local function add_break(row0)
    local l = row0 + 1
    if not seen[l] then
      seen[l] = true
      extra[#extra + 1] = l
    end
  end
  local function walk(node)
    local typ = node:type()
    if typ == "atx_heading" or typ == "setext_heading" then
      add_break(node:range()) -- start row
    elseif typ == "fenced_code_block" then
      local open_row, close_row
      for child in node:iter_children() do
        if child:type() == "fenced_code_block_delimiter" then
          local r = child:range()
          if not open_row then
            open_row = r
            add_break(r)
          else
            close_row = r
          end
        end
      end
      if open_row then
        local s = open_row + 2 -- 1-based line after open
        local e
        if close_row then
          e = close_row -- 1-based: last interior is close_row (0-based) → close_row
          -- interior 1-based: (open_row+1)+1 .. close_row (0-based end exclusive careful)
        end
        -- Compute inclusive 1-based [open_line+1, close_line-1]; skip if empty
      end
    end
    for child in node:iter_children() do
      walk(child)
    end
  end
  walk(root)
  table.sort(extra)
  return { extra_breaks = extra, suppress_blanks = suppress }
end
```

**Correctness note for implementer:** `node:range()` returns 0-based `start_row, start_col, end_row, end_col`. Convert carefully. Unit-test via the headless script until fixture matches.

Also export a combined helper if useful:

```lua
function M.soft_break_info(buf)
  return {
    leaders = M.line_comment_leaders(buf),
    addon = M.treesitter_addon(buf),
  }
end
```

- [ ] **Step 4: Re-run check — expect PASS**

```bash
/bin/bash --noprofile --norc scripts/check-soft-break-addon.sh
```

Expected: `OK soft-break-addon`

- [ ] **Step 5: Commit**

```bash
git add lua/nvimcat/soft_break.lua scripts/check-soft-break-addon.sh
git commit -m "$(cat <<'EOF'
feat: treesitter soft-break addon for markdown headings/fences

EOF
)"
```

---

### Task 3: Wire addon into embed stitch fetch

**Files:**
- Modify: `bin/nvimcat` (`_fetch_comment_leaders` → fetch leaders+addon, or add `_fetch_soft_break_info`; stitch call site)

**Interfaces:**
- Consumes: Task 1 segment API + Task 2 `soft_break_info` / `treesitter_addon`
- Produces: stitch loop passes `extra_breaks` / `suppress_blanks` into `_soft_break_segments`

- [ ] **Step 1: Replace/extend fetch helper**

```python
def _fetch_soft_break_info(nv: "NvimEmbed", timeout: float) -> tuple[
    list[tuple[str, bool]], set[int], list[tuple[int, int]]
]:
    raw = nv.request(
        "nvim_exec_lua",
        """
local ok, sb = pcall(require, "nvimcat.soft_break")
if not ok then return { leaders = {}, addon = { extra_breaks = {}, suppress_blanks = {} } } end
local leaders = sb.line_comment_leaders()
local addon = sb.treesitter_addon()
return { leaders = leaders, addon = addon }
""",
        [],
        timeout=timeout,
    )
    leaders: list[tuple[str, bool]] = []
    extra: set[int] = set()
    suppress: list[tuple[int, int]] = []
    if isinstance(raw, dict):
        # parse leaders list of dicts (existing shape)
        # parse addon.extra_breaks list of ints
        # parse addon.suppress_blanks list of {start,end} or [start,end]
        ...
    return leaders, extra, suppress
```

Keep `_fetch_comment_leaders` as a thin wrapper **or** delete and update the single call site — prefer one fetch.

- [ ] **Step 2: Update stitch call site**

Where segments are built (~`capture()` soft-break loop):

```python
leaders, extra_breaks, suppress_blanks = _fetch_soft_break_info(nv, _page_rpc_timeout(deadline))
segments = (
    _soft_break_segments(
        buf_text,
        leaders,
        ui_max=_UI_MAX_LINES,
        extra_breaks=extra_breaks,
        suppress_blanks=suppress_blanks,
    )
    if buf_text
    else [(1, last_line)]
)
```

- [ ] **Step 3: Sanity — segment unit check still passes**

```bash
/bin/bash --noprofile --norc scripts/check-soft-break-segments.sh
/bin/bash --noprofile --norc scripts/check-soft-break-addon.sh
/bin/bash --noprofile --norc scripts/check-no-md-stitch-rules.sh
```

Expected: all OK

- [ ] **Step 4: Commit**

```bash
git add bin/nvimcat
git commit -m "$(cat <<'EOF'
feat: stitch uses treesitter soft-break addon

EOF
)"
```

---

### Task 4: Guarded integration — fence internal blank

**Files:**
- Create: `scripts/check-soft-break-fence.sh`

**Interfaces:**
- Consumes: wired `bin/nvimcat`
- Produces: fail if capture shows a page seam that splits the fence (heuristic: both fence markers present; no orphan half; and/or segment unit already covers logic — this check ensures RPC+TS path works under embed)

- [ ] **Step 1: Write check**

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/check-lib.sh"
TMP="$(mktemp --suffix=.md)"
OUT="$(mktemp)"
trap 'rm -f "$TMP" "$OUT" "$OUT.err"' EXIT
# Enough content that stitch runs; fence with internal blank must stay intact in ANSI
{
  echo "# fence soft-break"
  echo
  for i in $(seq 1 50); do echo "para-$i"; echo; done
  echo '```'
  echo 'line-a'
  echo
  echo 'line-b'
  echo '```'
  echo
  echo "## after"
  echo
  echo "done"
} >"$TMP"
nvimcat_capture 90 "$OUT" -- --width 100 "$TMP"
assert_capture "$OUT" 20 "line-a" "line-b" "after"
python3 - "$OUT" <<'PY'
import re, sys
from pathlib import Path
plain = re.sub(r"\x1b\[[0-9;]*m", "", Path(sys.argv[1]).read_text())
# Both fence body lines must appear; blank between them must not drop line-b
ia, ib = plain.find("line-a"), plain.find("line-b")
assert ia != -1 and ib != -1 and ia < ib, (ia, ib)
print("OK soft-break-fence")
PY
```

- [ ] **Step 2: Run once under clean bash**

```bash
chmod +x scripts/check-soft-break-fence.sh
/bin/bash --noprofile --norc scripts/check-soft-break-fence.sh
```

Expected: `OK soft-break-fence` (wall &lt; 90s). Do **not** run granular-scopes here.

- [ ] **Step 3: Commit**

```bash
git add scripts/check-soft-break-fence.sh
git commit -m "$(cat <<'EOF'
test: guard soft-break fence blank suppression via embed

EOF
)"
```

---

### Task 5: Spec status + plan ledger

**Files:**
- Modify: `docs/superpowers/specs/2026-08-07-soft-break-treesitter-addons-design.md` (status → implemented when done)
- Modify: `.superpowers/sdd/progress.md` if present

- [ ] **Step 1: Mark addendum status implemented; note commits**
- [ ] **Step 2: Commit docs**

```bash
git add docs/superpowers/specs/2026-08-07-soft-break-treesitter-addons-design.md .superpowers/sdd/progress.md
git commit -m "$(cat <<'EOF'
docs: mark treesitter soft-break addons implemented

EOF
)"
```

---

## Spec coverage (self-review)

| Spec requirement | Task |
|------------------|------|
| Defaults blank + comments unchanged | 1 (compat asserts), 3 |
| `extra_breaks` / `suppress_blanks` API | 1–2 |
| Markdown headings + fence open | 2 |
| Suppress blanks inside fences | 1–2, 4 |
| No parser → empty addon | 2 |
| Hard-cut unchanged | 1 (existing hard-cut asserts) |
| No table/fence stitch helpers | 3 (`check-no-md-stitch-rules`) |
| Unit + markdown fixture checks | 1, 2, 4 |

**Placeholder scan:** none intentional. Fence suppress range math left precise in Task 2 with “verify via headless fixture” — implementer must lock 1-based inclusive bounds against `check-soft-break-addon.sh`.

**Type consistency:** `extra_breaks` as `set[int]` in Python; Lua array of ints; `suppress_blanks` as list of inclusive `(start, end)` tuples.
