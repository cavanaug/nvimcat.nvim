# Soft-break Scroll-Stitch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cut tall-file scroll-stitch pages only on blank lines or Neovim-discovered line comments, grow paint height to fit each soft-break segment (≤1000), and remove markdown-specific page-advance heuristics so captures stop drifting / dropping lines.

**Architecture:** Lua derives `{leader, blank_required}` from `vim.bo.commentstring` + `vim.bo.comments` (no filetype→prefix table). Python splits buffer lines into soft-break segments (with 1000-line hard cuts), then the existing embed stitch loop paints one segment per page (resize → scroll → stable grid → overlap-trim safety net).

**Tech Stack:** Python 3 in `bin/nvimcat`, Lua in `lua/nvimcat/`, bash check scripts, Neovim `--embed` / `--headless`.

**Spec:** `docs/superpowers/specs/2026-08-06-soft-break-stitch-design.md`

## Global Constraints

- No hardcoded filetype→comment-prefix map in nvimcat.
- No markdown-specific stitch rules (`_content_block_end`, `_is_table_line`, table/fence grow) on the page-advance path.
- Paint height must not follow `NVIMCAT_PAGE_LINES`; `NVIMCAT_STITCH_HEIGHT` / default is paint **floor** only; grow with `page_h = min(1000, max(floor, segment_len + 16))`.
- Soft break = whitespace-only line OR whole-line comment per discovered leaders.
- Block comments (`/* */`, `<!-- -->`) are not soft breaks; blanks-only when no line leaders.
- Hard-cut only when a soft-break-free run exceeds `UI_MAX_LINES` (1000): emit `[start, start+999]`, continue at `start+1000`.
- Keep `_trim_page_overlap` as safety net only.
- Prefer smallest diff; leave settle/non-md timeout short-circuit as already shipped.

## File map

| File | Role |
|------|------|
| `lua/nvimcat/soft_break.lua` | Parse `commentstring`/`comments` → leaders; optional buf wrapper |
| `bin/nvimcat` | `_soft_break_segments`, fetch leaders via RPC, segment stitch loop; delete md block helpers |
| `scripts/check-soft-break-segments.sh` | Pure-Python segment unit check (no LazyVim) |
| `scripts/check-comment-leaders.sh` | Headless nvim leader-parse unit check |
| `scripts/check-no-md-stitch-rules.sh` | Grep gate: md table/fence helpers gone from stitch path |
| `scripts/check-page-invariant.sh` | Adapt comments; keep PAGE_LINES identity; add STITCH_HEIGHT pair when cheap |
| `scripts/check-deterministic-capture.sh` | Keep; add optional non-md fixture path or sibling |

---

### Task 1: Python soft-break segment splitter (TDD)

**Files:**
- Create: `scripts/check-soft-break-segments.sh`
- Modify: `bin/nvimcat` (add `_is_soft_break_line`, `_soft_break_segments` only — do not wire stitch yet)

**Interfaces:**
- Consumes: none
- Produces:
  - `_is_soft_break_line(line: str, leaders: list[tuple[str, bool]]) -> bool`
  - `_soft_break_segments(lines: list[str], leaders: list[tuple[str, bool]], ui_max: int = 1000) -> list[tuple[int, int]]`  
    Leaders are `(leader, blank_required)`. Ranges are **1-based inclusive** `(start, end)`. Soft-break line is included at segment end. Next segment starts at `end+1`. Oversized runs hard-cut at `ui_max`.

- [ ] **Step 1: Write failing check script**

Create `scripts/check-soft-break-segments.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import importlib.util
import sys
from pathlib import Path

root = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("nvimcat", root / "bin" / "nvimcat")
mod = importlib.util.module_from_spec(spec)
# bin/nvimcat is a script; load via runpy-safe path: exec only defs by importing as file
sys.path.insert(0, str(root / "bin"))
# Prefer loading functions by compiling the file and extracting — script has side effects on __main__.
# Instead: duplicate-import guard — call helpers after loading with a stub __name__.
import types
code = (root / "bin" / "nvimcat").read_text()
# Execute module body without running main: strip/avoid __main__ by setting __name__
ns = types.ModuleType("nvimcat_bin")
ns.__file__ = str(root / "bin" / "nvimcat")
exec(compile(code, str(root / "bin" / "nvimcat"), "exec"), ns.__dict__)

seg = ns._soft_break_segments
is_sb = ns._is_soft_break_line

# blanks only
lines = ["a", "b", "", "c"]
assert seg(lines, []) == [(1, 3), (4, 4)], seg(lines, [])

# comment leader with blank required
leaders = [("#", True)]
lines = ["code", "# note", "more"]
assert is_sb("# note", leaders)
assert not is_sb("#note", leaders)  # b-flag: need blank after leader
assert not is_sb("code", leaders)
assert seg(lines, leaders) == [(1, 2), (3, 3)], seg(lines, leaders)

# leader without blank required
leaders = [("//", False)]
assert is_sb("//foo", leaders)
assert is_sb("//", leaders)

# hard cut: 5 lines, no soft breaks, ui_max=2
lines = ["a", "b", "c", "d", "e"]
assert seg(lines, [], ui_max=2) == [(1, 2), (3, 4), (5, 5)], seg(lines, [], ui_max=2)

# soft break ends segment including the blank
lines = ["a", "", "b", ""]
assert seg(lines, []) == [(1, 2), (3, 4)], seg(lines, [])

print("OK soft-break-segments")
PY
```

Make executable: `chmod +x scripts/check-soft-break-segments.sh`

- [ ] **Step 2: Run check — expect fail**

Run: `bash scripts/check-soft-break-segments.sh`  
Expected: FAIL (`_soft_break_segments` missing / AttributeError)

- [ ] **Step 3: Implement helpers in `bin/nvimcat`**

Add near the current `_content_block_end` block (will replace those functions in Task 3):

```python
def _is_soft_break_line(line: str, leaders: list[tuple[str, bool]]) -> bool:
    if not line.strip():
        return True
    # strip indent only (keep internal spaces)
    i = 0
    while i < len(line) and line[i] in " \t":
        i += 1
    body = line[i:]
    for leader, blank_required in leaders:
        if not leader or not body.startswith(leader):
            continue
        rest = body[len(leader) :]
        if blank_required:
            if rest == "" or rest[0] in " \t":
                return True
        else:
            return True
    return False


def _soft_break_segments(
    lines: list[str],
    leaders: list[tuple[str, bool]],
    ui_max: int = 1000,
) -> list[tuple[int, int]]:
    """1-based inclusive segments ending on soft break or EOF; hard-cut at ui_max."""
    n = len(lines)
    if n == 0:
        return []
    out: list[tuple[int, int]] = []
    start = 1
    while start <= n:
        end = start
        while end <= n:
            if end - start + 1 >= ui_max:
                end = start + ui_max - 1
                break
            if _is_soft_break_line(lines[end - 1], leaders):
                break
            end += 1
        if end > n:
            end = n
        out.append((start, end))
        start = end + 1
    return out
```

- [ ] **Step 4: Run check — expect pass**

Run: `bash scripts/check-soft-break-segments.sh`  
Expected: `OK soft-break-segments`

- [ ] **Step 5: Commit**

```bash
git add bin/nvimcat scripts/check-soft-break-segments.sh
git commit -m "$(cat <<'EOF'
feat: add soft-break segment splitter

Page cuts will land on blanks/comments once stitch is wired.
EOF
)"
```

---

### Task 2: Lua comment-leader discovery (TDD)

**Files:**
- Create: `lua/nvimcat/soft_break.lua`
- Create: `scripts/check-comment-leaders.sh`
- Modify: `lua/nvimcat/init.lua` only if a thin re-export is needed (prefer requiring `nvimcat.soft_break` from RPC)

**Interfaces:**
- Consumes: none
- Produces:
  - `require("nvimcat.soft_break").parse_leaders(commentstring, comments) -> { { leader=string, blank_required=boolean }, ... }`
  - `require("nvimcat.soft_break").line_comment_leaders(buf?) ->` same shape from `vim.bo[buf]`

**Parse rules (exact):**
1. `commentstring`: if it matches `^(.-)%%s%s*$` (leader + `%s` + optional trailing space only) → one leader with `blank_required=true`. If there is non-space text after `%s` (block form), skip.
2. `comments`: split on commas; each part `flags:string`. **Skip** if flags contain `s`, `m`, `e`, or `f` (three-piece or first-line/list markers like `fb:-`). Remaining parts → `leader=string`, `blank_required = flags` contains `b`.
3. Deduplicate by leader string (keep `blank_required=true` if any duplicate requires blank).
4. Never consult filetype name strings.

- [ ] **Step 1: Write failing headless check**

**Locked parse extra:** skip `comments` parts whose flags contain **any of** `s`, `m`, `e`, `f`, or `n` (three-piece, first-line/list, nested quote). Keeps `://`, `b:#`, `:%`, `:XCOMM`; drops `fb:-` and `n:>`.

Create `scripts/check-comment-leaders.sh`:

```bash
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
```

Make executable: `chmod +x scripts/check-comment-leaders.sh`

- [ ] **Step 2: Run check — expect fail**

Run: `bash scripts/check-comment-leaders.sh`  
Expected: FAIL (module missing)

- [ ] **Step 3: Implement `lua/nvimcat/soft_break.lua`**

```lua
local M = {}

---@param commentstring string
---@param comments string
---@return { leader: string, blank_required: boolean }[]
function M.parse_leaders(commentstring, comments)
  local by_leader = {}

  local function add(leader, blank_required)
    if not leader or leader == "" then
      return
    end
    local prev = by_leader[leader]
    if prev == nil then
      by_leader[leader] = blank_required and true or false
    elseif blank_required then
      by_leader[leader] = true
    end
  end

  commentstring = commentstring or ""
  local pre, post = commentstring:match("^(.-)%%s(.*)$")
  if pre and (post or ""):match("^%s*$") then
    add(pre, true)
  end

  for part in ((comments or "") .. ","):gmatch("([^,]*),") do
    if part ~= "" then
      local flags, str = part:match("^([a-zA-Z0-9]*):(.*)$")
      if flags and str and str ~= "" then
        if not flags:find("[smefn]") then
          add(str, flags:find("b", 1, true) ~= nil)
        end
      end
    end
  end

  local out = {}
  for leader, blank_required in pairs(by_leader) do
    out[#out + 1] = { leader = leader, blank_required = blank_required }
  end
  table.sort(out, function(a, b)
    return a.leader < b.leader
  end)
  return out
end

---@param buf integer?
function M.line_comment_leaders(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  return M.parse_leaders(vim.bo[buf].commentstring, vim.bo[buf].comments)
end

return M
```

- [ ] **Step 4: Run check — expect pass**

Run: `bash scripts/check-comment-leaders.sh`  
Expected: `OK comment-leaders`

- [ ] **Step 5: Commit**

```bash
git add lua/nvimcat/soft_break.lua scripts/check-comment-leaders.sh
git commit -m "$(cat <<'EOF'
feat: discover line-comment leaders from Neovim options

Runtime commentstring/comments only — no filetype prefix table.
EOF
)"
```

---

### Task 3: Wire segment stitch; remove markdown page heuristics

**Files:**
- Modify: `bin/nvimcat` (stitch loop ~1371–1471; delete `_is_table_line` / `_content_block_end`)
- Create: `scripts/check-no-md-stitch-rules.sh`

**Interfaces:**
- Consumes: `_soft_break_segments`, `nvimcat.soft_break.line_comment_leaders`
- Produces: tall-file stitch advances by soft-break segments

- [ ] **Step 1: Write grep gate (fail while helpers remain)**

Create `scripts/check-no-md-stitch-rules.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if rg -n '_content_block_end|_is_table_line' "$ROOT/bin/nvimcat"; then
  echo "FAIL: markdown stitch helpers still present in bin/nvimcat" >&2
  exit 1
fi
echo "OK no-md-stitch-rules"
```

`chmod +x` it.

- [ ] **Step 2: Run gate — expect fail**

Run: `bash scripts/check-no-md-stitch-rules.sh`  
Expected: FAIL (symbols still present)

- [ ] **Step 3: Replace stitch loop**

Add leader fetch helper:

```python
def _fetch_comment_leaders(nv: "NvimEmbed", timeout: float) -> list[tuple[str, bool]]:
    raw = nv.request(
        "nvim_exec_lua",
        """
local ok, sb = pcall(require, "nvimcat.soft_break")
if not ok then return {} end
return sb.line_comment_leaders()
""",
        [],
        timeout=timeout,
    )
    out: list[tuple[str, bool]] = []
    if isinstance(raw, list):
        for item in raw:
            if isinstance(item, dict) and item.get("leader"):
                out.append((str(item["leader"]), bool(item.get("blank_required"))))
    return out
```

Replace the content-aware block that uses `_content_block_end` with:

```python
buf_text: list[str] = []
try:
    raw_lines = nv.request(
        "nvim_buf_get_lines", 0, 0, -1, True,
        timeout=max(1.0, deadline - time.time()),
    )
    if isinstance(raw_lines, list):
        buf_text = [str(x) for x in raw_lines]
except (TimeoutError, RuntimeError):
    buf_text = []

leaders = []
try:
    leaders = _fetch_comment_leaders(nv, max(1.0, deadline - time.time()))
except (TimeoutError, RuntimeError):
    leaders = []

stitch_h = _stitch_ui_height()
last_line = len(buf_text) if buf_text else int(buf_lines or 1)
segments = (
    _soft_break_segments(buf_text, leaders, ui_max=_UI_MAX_LINES)
    if buf_text
    else [(1, last_line)]
)

for seg_start, seg_end in segments:
    if time.time() >= deadline or pages_done >= 500:
        break
    block_len = max(1, seg_end - seg_start + 1)
    page_h = min(_UI_MAX_LINES, max(stitch_h, block_len + 16))

    if page_h != height:
        flush_ev.clear()
        try:
            nv.request("nvim_ui_try_resize", width, page_h,
                       timeout=max(0.0, deadline - time.time()))
            height = page_h
            nv.request("nvim_command", "redraw!",
                       timeout=max(0.0, deadline - time.time()))
            flush_ev.wait(timeout=min(1.0, max(0.0, deadline - time.time())))
        except (TimeoutError, RuntimeError) as exc:
            print(f"nvimcat: page resize failed: {exc}", file=sys.stderr)
        flush_ev.clear()

    flush_ev.clear()
    try:
        with grid_lock:
            before = grid.to_ansi()
        _scroll_page(nv, seg_start, max(0.0, deadline - time.time()))
        _wait_grid_change(
            nv, grid, grid_lock, flush_ev, before,
            deadline=deadline, max_wait=0.5,
        )
    except (TimeoutError, RuntimeError) as exc:
        print(f"nvimcat: scroll failed: {exc}", file=sys.stderr)
        break
    flush_ev.clear()

    with grid_lock:
        part = grid.to_ansi()
    if output_parts:
        part = _trim_page_overlap(output_parts[-1], part)
    if part:
        if output_parts and not output_parts[-1].endswith(b"\n"):
            output_parts.append(b"\n")
        output_parts.append(part)
    pages_done += 1
    awaiting_resize_flush = False

# Do not advance via bot+1; segments list is authoritative.
```

Delete `_is_table_line` and `_content_block_end` entirely.

Update the comment above the stitch block to describe soft-break segments (no markdown language).

- [ ] **Step 4: Run unit gates**

Run:

```bash
bash scripts/check-soft-break-segments.sh
bash scripts/check-comment-leaders.sh
bash scripts/check-no-md-stitch-rules.sh
```

Expected: all OK

- [ ] **Step 5: Commit**

```bash
git add bin/nvimcat scripts/check-no-md-stitch-rules.sh
git commit -m "$(cat <<'EOF'
feat: stitch tall files on soft-break segments

Grow paint per blank/comment segment; drop markdown page heuristics.
EOF
)"
```

---

### Task 4: Integration checks (determinism + page identity)

**Files:**
- Modify: `scripts/check-page-invariant.sh` (fix header comment; optionally compare `NVIMCAT_STITCH_HEIGHT=80` vs `120` on a fixture that fits via blanks)
- Create: `scripts/check-deterministic-non-md.sh` (tall Lua/Python-like fixture with `#`/`--` comments + blanks)

**Interfaces:**
- Consumes: wired stitch from Task 3
- Produces: regression scripts proving determinism for non-md and PAGE_LINES identity

- [ ] **Step 1: Add non-md determinism check**

Create `scripts/check-deterministic-non-md.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
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
  timeout 120 "$ROOT/bin/nvimcat" --width 100 "$FIXTURE" >"$out"
  lines=$(python3 -c 'import re,pathlib,sys; t=re.sub(rb"\x1b\[[0-9;]*m",b"",pathlib.Path(sys.argv[1]).read_bytes()).decode(); print(t.count(chr(10))+(0 if t.endswith("\n") else 1))' "$out")
  COUNTS+=("$lines")
  python3 - "$out" <<'PY'
import re, sys
from pathlib import Path
plain = re.sub(rb"\x1b\[[0-9;]*m", b"", Path(sys.argv[1]).read_bytes()).decode()
assert "tall non-md" in plain
assert "x250" in plain or "x240" in plain
PY
  echo "run=$i lines=$lines"
done
if [[ "${COUNTS[0]}" != "${COUNTS[1]}" || "${COUNTS[1]}" != "${COUNTS[2]}" ]]; then
  echo "FAIL non-deterministic: ${COUNTS[*]}" >&2
  exit 1
fi
# byte-identical across runs
cmp -s "$TMP/run-1.out" "$TMP/run-2.out"
cmp -s "$TMP/run-2.out" "$TMP/run-3.out"
echo "OK deterministic-non-md lines=${COUNTS[0]}"
```

`chmod +x` it.

- [ ] **Step 2: Run — expect pass (or fix stitch bugs until pass)**

Run: `bash scripts/check-deterministic-non-md.sh`  
Expected: `OK deterministic-non-md …`

If FAIL: fix root cause in segment advance / overlap / leader fetch (do not reintroduce markdown heuristics).

- [ ] **Step 3: Update `scripts/check-page-invariant.sh`**

- Change header comment from “pages follow markdown blocks” to “PAGE_LINES ignored; soft-break segments; STITCH_HEIGHT is paint floor”.
- Keep existing `NVIMCAT_PAGE_LINES=100` vs `250` identity assertions.
- After fixture PAGE_LINES check, add:

```bash
NVIMCAT_STITCH_HEIGHT=80 NVIMCAT_TIMEOUT=90 "$ROOT/bin/nvimcat" --width 100 "$TMP" >"$TMP.s80"
NVIMCAT_STITCH_HEIGHT=120 NVIMCAT_TIMEOUT=90 "$ROOT/bin/nvimcat" --width 100 "$TMP" >"$TMP.s120"
# same plain() compare as PAGE_LINES — must match when segments grow-to-fit
```

Update `trap` to clean the new temps.

Note: the 1200-row pipe table has few blanks — soft-break segments may be huge and hard-cut at 1000. Identity across STITCH_HEIGHT should still hold because floor only changes minimum paint, and grow-to-fit uses `max(floor, len+16)`.

- [ ] **Step 4: Run page-invariant + existing deterministic md check**

```bash
bash scripts/check-page-invariant.sh
bash scripts/check-deterministic-capture.sh
bash scripts/check-soft-break-segments.sh
bash scripts/check-comment-leaders.sh
bash scripts/check-no-md-stitch-rules.sh
```

Expected: all OK

- [ ] **Step 5: Commit**

```bash
git add scripts/check-deterministic-non-md.sh scripts/check-page-invariant.sh
git commit -m "$(cat <<'EOF'
test: soft-break stitch determinism and page identity

Cover non-md captures and STITCH_HEIGHT paint-floor invariance.
EOF
)"
```

---

### Task 5: Spec status + handoff note

**Files:**
- Modify: `docs/superpowers/specs/2026-08-06-soft-break-stitch-design.md` (Status → implemented)
- Modify: `docs/superpowers/specs/2026-08-04-compose-api-nvimcat-handoff.md` only if it still documents markdown block stitch / `PAGE_LINES` paint (one-line correction)

- [ ] **Step 1: Update design status line to `implemented`**
- [ ] **Step 2: Fix any stale handoff sentence about markdown block paging**
- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/specs/2026-08-06-soft-break-stitch-design.md docs/superpowers/specs/2026-08-04-compose-api-nvimcat-handoff.md
git commit -m "$(cat <<'EOF'
docs: mark soft-break stitch design implemented
EOF
)"
```

---

## Spec coverage (self-review)

| Spec requirement | Task |
|------------------|------|
| Soft break = blank or line comment | 1, 2 |
| Leaders from `commentstring`/`comments` only | 2 |
| No filetype prefix table | 2, 3 (grep) |
| Segments end on soft break; blank belongs to ending segment | 1 |
| Grow paint `min(1000, max(floor, len+16))` | 3 |
| Hard-cut at 1000 | 1, 3 |
| Remove `_content_block_end` / `_is_table_line` | 3 |
| Keep overlap-trim safety net | 3 |
| `NVIMCAT_PAGE_LINES` not paint height | 4 |
| Determinism md + non-md | 4 |
| Unit checks without full LazyVim where possible | 1, 2 |
| Block comments not soft breaks | 2 (`<!--%s-->` → empty) |

**Placeholder scan:** none intentional.  
**Type consistency:** leaders are `list[tuple[str,bool]]` in Python and `{leader, blank_required}` in Lua throughout.
