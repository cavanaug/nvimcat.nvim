# Format-handler boundary implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give ordinary files an exact, fast source-row capture path while keeping Markdown's table and Mermaid geometry behind one lazy format handler.

**Architecture:** Neovim selects an internal Lua format session once per buffer. A registry miss is the plain path: the Python capture engine crops each page to its known source-line span and concatenates pages without content filtering or overlap inference. A Markdown session supplies stateful break hints, renderer hooks, and stable source/generated-row projection keys; all rich output is buffered until projection validation succeeds.

**Tech Stack:** Python 3 standard library, Lua 5.1/LuaJIT through Neovim, Neovim embedded UI RPC, Bash integration checks.

## Global constraints

- Ordinary files produce exactly one output row per source buffer line, in source order.
- The plain path must never classify source content as UI chrome by text.
- Markdown parsers, renderer updates, Mermaid detection, and rich overlap logic must not run for plain files.
- Shared seam hints may use blank rows and Neovim-discovered single-line comment leaders, but may not change source rows.
- Stateful delimiters such as `/* ... */`, Markdown fences, and LaTeX environments are not parsed by the plain path.
- The only initial rich handler is the Markdown family: `markdown`, `markdown.mdx`, `mdx`, `quarto`, and `rmd`.
- Handler output is buffered and validated before stdout; handler failure retries once through forced plain capture.
- Public handler registration, LaTeX handling, and C-family handling are out of scope.
- Do not commit from the current dirty `master` branch. The commit steps below are only for execution in an isolated feature worktree or after the user chooses a branch strategy.

---

### Task 1: Executable plain-file identity contract

**Files:**
- Create: `scripts/check-plain-exact.sh`
- Modify: `scripts/check-comment-leaders.sh:1-34`
- Modify: `scripts/check.sh:1-79`

**Interfaces:**
- Consumes: `scripts/check-lib.sh::nvimcat_capture(WALL, OUTFILE, --, ARGS...)`.
- Produces: `scripts/check-plain-exact.sh`, a real embedded-Neovim regression check for Python, Bash, and C; no production API.

- [ ] **Step 1: Write the failing exact-capture integration test**

Create `scripts/check-plain-exact.sh`. Generate three files with more than 1,000 source lines so capture crosses Neovim's UI-height ceiling. Use only spaces, printable ASCII, and blank rows so expected display text is independent of tab expansion.

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=check-lib.sh
source "$ROOT/scripts/check-lib.sh"

WALL="${NVIMCAT_CHECK_WALL:-45}"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

make_fixture() {
  local kind="$1" path="$2"
  case "$kind" in
    python)
      {
        echo '# plain python'
        echo 'Indexing = "source text, not UI chrome"'
        echo 'Indexed = "must survive"'
        echo 'NORMAL = "must survive"'
        for i in $(seq 1 1220); do
          echo "value_$i = $i  # section $i"
          (( i % 41 == 0 )) && echo
        done
      } >"$path"
      ;;
    bash)
      {
        echo '#!/usr/bin/env bash'
        echo '# Indexing and Indexed are source comments'
        for i in $(seq 1 1220); do
          echo "value_$i=$i # section $i"
          (( i % 43 == 0 )) && echo
        done
      } >"$path"
      ;;
    c)
      {
        echo '/* plain C block comment begins'
        echo
        echo 'Indexing and Indexed are source text'
        echo '*/'
        echo '// stateless line-comment seam'
        for i in $(seq 1 1220); do
          echo "int value_$i = $i; /* inline block text */"
          if (( i % 47 == 0 )); then
            echo '/* multiline comment'
            echo
            echo 'continues across a blank line */'
          fi
        done
      } >"$path"
      ;;
  esac
}

compare_visible_rows() {
  python3 - "$1" "$2" "$3" <<'PY'
import re, sys
from pathlib import Path

source_path, output_path, label = map(Path, sys.argv[1:])
source = source_path.read_text().splitlines()
raw = output_path.read_bytes()
visible = re.sub(rb"\x1b\[[0-9;]*m", b"", raw).decode("utf-8", "replace")
actual = [line.rstrip() for line in visible.splitlines()]
if actual != source:
    limit = min(len(source), len(actual))
    first = next((i for i in range(limit) if source[i] != actual[i]), limit)
    print(
        f"FAIL {label}: source_rows={len(source)} output_rows={len(actual)} "
        f"first_mismatch={first + 1}",
        file=sys.stderr,
    )
    raise SystemExit(1)
print(f"OK {label} exact_rows={len(source)}")
PY
}

for kind in python bash c; do
  case "$kind" in python) ext=py;; bash) ext=sh;; c) ext=c;; esac
  fixture="$TMP/plain.$ext"
  output="$TMP/plain-$kind.out"
  make_fixture "$kind" "$fixture"
  nvimcat_capture "$WALL" "$output" -- --width 120 "$fixture"
  compare_visible_rows "$fixture" "$output" "$kind"
done
```

The production mutation this catches is restoring any content-based row deletion or using rich overlap trimming on a plain page.

- [ ] **Step 2: Extend real filetype comment discovery checks**

Append headless-buffer checks to `scripts/check-comment-leaders.sh` after the parser-only assertions:

```lua
local function leaders_for(name)
  vim.cmd("enew")
  vim.cmd("file " .. name)
  vim.cmd("filetype detect")
  return sb.line_comment_leaders(0)
end
assert(has(leaders_for("fixture.py"), "#", true))
assert(has(leaders_for("fixture.sh"), "#", true))
local c = leaders_for("fixture.c")
assert(has(c, "//", false))
for _, x in ipairs(c) do
  assert(x.leader ~= "/*" and x.leader ~= "*" and x.leader ~= "*/")
end
```

This fails if paired comment delimiters leak into the stateless common seam hints.

- [ ] **Step 3: Run the new tests and verify RED**

Run:

```bash
bash scripts/check-comment-leaders.sh
timeout 150 bash scripts/check-plain-exact.sh
```

Expected: comment discovery passes; exact capture fails on the Python fixture because `Grid._is_chrome_text()` / `_strip_statusline_leak()` removes literal `Indexing`, `Indexed`, or `NORMAL` rows.

- [ ] **Step 4: Wire the exact test into the suite only after it is green**

Add this command before the optional large Markdown fixture in `scripts/check.sh`:

```bash
bash "$ROOT/scripts/check-comment-leaders.sh"
bash "$ROOT/scripts/check-plain-exact.sh"
```

- [ ] **Step 5: Commit on a non-default feature branch only**

```bash
git add scripts/check-plain-exact.sh scripts/check-comment-leaders.sh scripts/check.sh
git commit -m "test: enforce exact plain-file capture"
```

---

### Task 2: Lazy internal format-handler registry

**Files:**
- Create: `lua/nvimcat/format_handlers/init.lua`
- Create: `lua/nvimcat/format_handlers/markdown.lua`
- Create: `scripts/check-format-handlers.sh`
- Modify: `lua/nvimcat/soft_break.lua:54-129`

**Interfaces:**
- Produces: `require("nvimcat.format_handlers").resolve(buf, opts) -> session|nil, diagnostic|nil`.
- Produces: Markdown session fields `id = "markdown"`, `rich = true`, and method `break_hints() -> {extra_breaks, suppress_blanks}`.
- Consumes later: `nvimcat.init.dump()` and Python `_fetch_capture_info()`.

- [ ] **Step 1: Write the failing registry behavior test**

Create `scripts/check-format-handlers.sh` as a headless Neovim test. Install a counting loader in `package.preload["nvimcat.format_handlers.markdown"]`, then assert:

```lua
local loads = 0
package.loaded["nvimcat.format_handlers"] = nil
package.loaded["nvimcat.format_handlers.markdown"] = nil
package.preload["nvimcat.format_handlers.markdown"] = function()
  loads = loads + 1
  return { open = function(buf) return { id = "markdown", rich = true, buf = buf } end }
end

local registry = require("nvimcat.format_handlers")
vim.cmd("enew | setfiletype python")
local plain = registry.resolve(0)
assert(plain == nil)
assert(loads == 0, "plain resolution loaded Markdown")

vim.cmd("enew | setfiletype markdown")
local rich = registry.resolve(0)
assert(rich and rich.id == "markdown" and rich.rich == true)
assert(loads == 1)
assert(registry.resolve(0) == rich, "session was not cached")
assert(loads == 1)
```

Add a second case whose Markdown loader raises `synthetic handler failure`; assert `resolve()` returns `nil` plus a diagnostic containing the handler id but not buffer content.

The production mutation this catches is using a default handler object or importing Markdown on a registry miss.

- [ ] **Step 2: Run the registry test and verify RED**

Run: `bash scripts/check-format-handlers.sh`

Expected: FAIL because `nvimcat.format_handlers` does not exist.

- [ ] **Step 3: Implement the registry**

In `lua/nvimcat/format_handlers/init.lua`, define declarative internal registrations, validate them into one normalized lookup table at module load, and keep a per-buffer cache:

```lua
local M = {}
local registrations = {
  {
    id = "markdown",
    module = "nvimcat.format_handlers.markdown",
    filetypes = { "markdown", "markdown.mdx", "mdx", "quarto", "rmd" },
  },
}
local by_filetype = {}
for _, spec in ipairs(registrations) do
  assert(spec.id ~= "" and spec.module ~= "", "invalid format-handler registration")
  for _, raw in ipairs(spec.filetypes) do
    local ft = raw:lower()
    assert(not by_filetype[ft], "duplicate format handler for " .. ft)
    by_filetype[ft] = spec
  end
end
local cache = {}

function M.resolve(buf, opts)
  buf = buf or vim.api.nvim_get_current_buf()
  if opts and opts.force_plain then return nil end
  local ft = (vim.bo[buf].filetype or ""):lower()
  local spec = by_filetype[ft]
  if not spec then return nil end
  local cached = cache[buf]
  if cached and cached.filetype == ft then return cached.session end
  local ok_mod, handler = pcall(require, spec.module)
  if not ok_mod then return nil, ("%s: load failed: %s"):format(spec.id, handler) end
  local ok_open, session = pcall(handler.open, buf)
  if not ok_open then return nil, ("%s: open failed: %s"):format(spec.id, session) end
  assert(session.id == spec.id, "handler id mismatch for " .. ft)
  cache[buf] = { filetype = ft, session = session }
  return session
end

return M
```

Keep the registration table internal. Registry misses return `nil`; do not add a plain handler object. Add a duplicate-filetype construction case to the registry test so a future conflicting internal registration fails deterministically at startup.

- [ ] **Step 4: Move Markdown break parsing into its handler**

Move the current Tree-sitter heading/fence traversal from `soft_break.treesitter_addon()` into `lua/nvimcat/format_handlers/markdown.lua` behind:

```lua
function M.open(buf)
  local session = { id = "markdown", rich = true, buf = buf }
  function session:break_hints()
    return markdown_break_hints(self.buf)
  end
  return session
end
```

Leave `soft_break.lua` responsible only for `parse_leaders()` and `line_comment_leaders()`. A failed or unavailable Markdown parser returns empty handler hints, not a common-path heuristic.

- [ ] **Step 5: Verify GREEN and focused compatibility**

Run:

```bash
bash scripts/check-format-handlers.sh
bash scripts/check-comment-leaders.sh
bash scripts/check-soft-break-addon.sh
bash scripts/check-soft-break-fence.sh
```

Expected: all pass; the add-on/fence scripts now obtain hints through the Markdown session.

- [ ] **Step 6: Commit on a non-default feature branch only**

```bash
git add lua/nvimcat/format_handlers lua/nvimcat/soft_break.lua scripts/check-format-handlers.sh scripts/check-soft-break-addon.sh scripts/check-soft-break-fence.sh
git commit -m "refactor: add lazy format handler registry"
```

---

### Task 3: Exact source-row projection for the plain capture path

**Files:**
- Modify: `bin/nvimcat:480-587,948-1000,1149-1184,1533-1810`
- Modify: `scripts/check-grid-ansi.py:1-105`
- Modify: `scripts/check-soft-break-segments.sh:1-116`

**Interfaces:**
- Produces: `Grid.to_ansi(grid=1, *, exact_rows=None, rich=True) -> bytes`.
- Produces: `_fetch_capture_info(nv, timeout) -> CaptureInfo`, where `CaptureInfo.handler_id` is `None` for plain files and `CaptureInfo.rich` is false.
- Consumes: Task 2 registry and Markdown session `break_hints()`.

- [ ] **Step 1: Add unit regressions for literal chrome text and exact cropping**

Extend `scripts/check-grid-ansi.py` with a grid containing five rows:

```python
rows = ["Indexing workspace", "Indexed files", "NORMAL source", "~", "tail"]
```

Assert `grid.to_ansi(exact_rows=5, rich=False)` returns all five normalized rows—including the literal `~`—while `grid.to_ansi(rich=True)` retains the existing rich-format cleanup behavior.

Extend `scripts/check-soft-break-segments.sh` with a plain-page concatenation assertion proving two adjacent source intervals are joined without calling `_trim_page_overlap()`.

The production mutation this catches is accidentally routing plain capture through text-based chrome cleanup or overlap inference.

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
python3 scripts/check-grid-ansi.py
bash scripts/check-soft-break-segments.sh
```

Expected: FAIL because `Grid.to_ansi()` has no exact-row policy and removes the literal chrome-like rows.

- [ ] **Step 3: Add explicit capture metadata**

Replace `_fetch_soft_break_info()` with a `CaptureInfo` named tuple or frozen dataclass:

```python
@dataclass(frozen=True)
class CaptureInfo:
    handler_id: str | None
    rich: bool
    leaders: tuple[tuple[str, bool], ...]
    extra_breaks: frozenset[int]
    suppress_blanks: tuple[tuple[int, int], ...]
    diagnostic: str | None = None
```

Its Lua RPC must call the Task 2 registry once, always collect common line-comment leaders, and call `session:break_hints()` only when a session exists. Respect `NVIMCAT_FORCE_PLAIN=1` by passing `{force_plain=true}`. Return `handler_id=nil`, `rich=false`, and empty handler hints on a registry error while preserving a sanitized diagnostic.

- [ ] **Step 4: Implement exact grid projection**

Change `Grid.to_ansi()` so the plain branch is first and does no content inspection:

```python
def to_ansi(self, grid: int = 1, *, exact_rows: int | None = None, rich: bool = True) -> bytes:
    rows = self._rows.get(grid, [])
    if not rich:
        count = max(0, min(len(rows), int(exact_rows or 0)))
        lines = [self._row_to_ansi(row) for row in rows[:count]]
        return b"\n".join(lines) + (b"\n" if lines else b"")
    # Existing EOB, statusline, overlay, and trailing-chrome cleanup follows.
```

An absent `exact_rows` in plain mode is a programming error; raise `ValueError` rather than guessing. Do not call `_is_eob_row()`, `_is_statusline_row()`, `_strip_statusline_leak()`, or `_is_chrome_text()` in this branch.

- [ ] **Step 5: Split plain and rich page assembly**

Fetch `CaptureInfo` before the first scroll or pre-stitch renderer update. For each segment, compute `block_len = seg_end - seg_start + 1` and assemble as follows:

```python
if capture_info.rich:
    part = grid.to_ansi(rich=True)
    if output_parts:
        output_parts[-1], part = _trim_page_overlap(...)
else:
    part = grid.to_ansi(exact_rows=block_len, rich=False)
```

For plain capture, append each exact segment directly. Never call `_trim_page_overlap()`. Validate after assembly that the ANSI payload has exactly `len(buf_text)` newline-terminated rows; a mismatch is a capture error and emits no partial stdout.

- [ ] **Step 6: Verify GREEN**

Run:

```bash
python3 scripts/check-grid-ansi.py
bash scripts/check-soft-break-segments.sh
timeout 150 bash scripts/check-plain-exact.sh
```

Expected: all pass; Python, Bash, and C each report an exact source/output row match.

- [ ] **Step 7: Commit on a non-default feature branch only**

```bash
git add bin/nvimcat scripts/check-grid-ansi.py scripts/check-soft-break-segments.sh scripts/check-plain-exact.sh
git commit -m "fix: preserve exact rows for plain files"
```

---

### Task 4: Route rendering and row provenance through the Markdown session

**Files:**
- Modify: `lua/nvimcat/format_handlers/markdown.lua`
- Modify: `lua/nvimcat/init.lua:114-324,555-675`
- Modify: `bin/nvimcat:1226-1379,1635-1672`
- Modify: `scripts/check-format-handlers.sh`
- Modify: `scripts/check-soft-break-segments.sh`

**Interfaces:**
- Extends Markdown session with `needs_mermaid()`, `prepare(win, opts)`, `ready()`, `settle(win, opts)`, `refresh(win, reason, timeout_ms)`, `extra_rows()`, and `project(win, first_line, last_line)`.
- Produces: Python `ProjectionRow(data: bytes, key: tuple[str, int, int])` and `_trim_projected_overlap(prev, next)`, whose comparisons use keys rather than rendered text.
- Produces: `vim.g.nvimcat_format_handler`, set to `"markdown"` or `"plain"` before capture.
- Consumes: Task 2 `registry.resolve()` and Task 3 `CaptureInfo.rich`.

- [ ] **Step 1: Add a failing no-Markdown-runtime test**

Extend `scripts/check-format-handlers.sh` with preloads for these modules that each raise if required:

```lua
for _, name in ipairs({
  "render-markdown",
  "render-markdown.state",
  "render-markdown.core.ui",
  "render-markdown-mermaid",
  "render-markdown-mermaid.display",
}) do
  package.preload[name] = function() error("plain path loaded " .. name) end
end
```

Open a Python buffer and execute the same handler lifecycle helper used by `nvimcat.init.dump()`. Assert it returns the plain mode without an error. Then open Markdown with a counting fake handler and assert exactly its methods are invoked.

The production mutation this catches is reintroducing an unconditional Markdown `require`, Mermaid scan, or renderer wait in common capture.

- [ ] **Step 2: Run the test and verify RED**

Run: `bash scripts/check-format-handlers.sh`

Expected: FAIL because `_SILENCE_CHROME_LUA`, `_PRE_STITCH_RENDER_LUA`, and current `init.lua` helpers still reference Markdown directly from common flow.

- [ ] **Step 3: Move Markdown lifecycle behavior into the session**

Move the current Markdown-only helpers from `lua/nvimcat/init.lua` into `format_handlers/markdown.lua`: Mermaid fence detection/setup, renderer plugin loading, anti-conceal configuration, table/Mermaid readiness, render generation, settle, refresh, and virtual-row estimation. Preserve their current wait bounds and stable-idle behavior.

`init.dump()` should resolve once and use nil-safe calls:

```lua
local session, handler_error = handlers.resolve(buf, {
  force_plain = vim.env.NVIMCAT_FORCE_PLAIN == "1",
})
vim.g.nvimcat_format_handler = session and session.id or "plain"
vim.g.nvimcat_format_error = handler_error or ""

if session then
  session:prepare(win, opts)
  session:settle(win, opts)
end
```

Height estimation adds `session:extra_rows()` only when a session exists. Plain height is based on source count plus fixed UI slack; it does not scan extmarks or file text for Mermaid fences.

- [ ] **Step 4: Add a failing provenance-overlap test**

In `scripts/check-soft-break-segments.sh`, construct two projected pages whose visible text is deliberately repeated but whose stable identities differ:

```python
row = ns.ProjectionRow
prev = [
    row(b"same", ("source", 10, 0)),
    row(b"same", ("source", 11, 0)),
    row(b"border", ("before", 12, 1)),
]
nxt = [
    row(b"border", ("before", 12, 1)),
    row(b"same", ("source", 12, 0)),
]
left, right = ns._trim_projected_overlap(prev, nxt)
assert [x.key for x in left] == [
    ("source", 10, 0), ("source", 11, 0), ("before", 12, 1)
]
assert [x.key for x in right] == [("source", 12, 0)]
```

Add a second case where identical bytes have different keys and assert neither row is deleted. The mutation this catches is falling back to rendered-text overlap for rich pages.

Run: `bash scripts/check-soft-break-segments.sh`

Expected: FAIL because `ProjectionRow` and `_trim_projected_overlap()` do not exist.

- [ ] **Step 5: Implement Markdown page provenance**

Implement `session:project(win, first_line, last_line)` with `vim.fn.screenpos()` for each source line in the requested interval. Return a key for every document grid row:

- a source row is `{ "source", lnum, 0 }`;
- rows between source anchors are keyed to the following source as `{ "before", following_lnum, ordinal_from_top }`;
- rows after the final source anchor are `{ "after", preceding_lnum, ordinal_from_top }`.

Reject duplicate keys, missing screen positions for every source line in the interval, and keys outside the requested source interval. A rejection sets the handler diagnostic and triggers Task 5's atomic plain fallback.

In Python, pair each ANSI grid row with the corresponding returned key:

```python
@dataclass(frozen=True)
class ProjectionRow:
    data: bytes
    key: tuple[str, int, int]

def _trim_projected_overlap(
    prev: list[ProjectionRow], nxt: list[ProjectionRow]
) -> tuple[list[ProjectionRow], list[ProjectionRow]]:
    limit = min(len(prev), len(nxt))
    for size in range(limit, 0, -1):
        if [row.key for row in prev[-size:]] == [row.key for row in nxt[:size]]:
            return prev, nxt[size:]
    return prev, nxt
```

Serialize only `ProjectionRow.data` after all rich pages pass validation. Keep `_trim_page_overlap()` only as a compatibility helper for screenshot/compose paths that have no document projection; embedded rich capture must use stable keys.

- [ ] **Step 6: Make Python scroll hooks handler-neutral**

Keep common scroll Lua limited to window positioning, chrome options, notification/floating-window cleanup, and `redraw!`. Delete direct Markdown imports from `_SILENCE_CHROME_LUA`.

Replace `_PRE_STITCH_RENDER_LUA` and the Markdown block in `_scroll_page()` with a registry-mediated call that runs only when `CaptureInfo.rich` is true:

```lua
local session = require("nvimcat.format_handlers").resolve(0)
if session then session:refresh(vim.api.nvim_get_current_win(), reason, timeout_ms) end
vim.cmd("redraw!")
```

Plain scroll never executes this RPC block.

- [ ] **Step 7: Verify handler isolation, provenance, and runtime**

Run:

```bash
bash scripts/check-format-handlers.sh
bash scripts/check-soft-break-segments.sh
timeout 150 bash scripts/check-plain-exact.sh
bash scripts/check-scroll-stitch.sh
```

Expected: all pass. Capture stderr under `NVIMCAT_VERBOSE=1` and confirm it reports `format_handler=plain` for Python/C and `format_handler=markdown` for Markdown.

- [ ] **Step 8: Commit on a non-default feature branch only**

```bash
git add lua/nvimcat/format_handlers/markdown.lua lua/nvimcat/init.lua bin/nvimcat scripts/check-format-handlers.sh scripts/check-soft-break-segments.sh
git commit -m "refactor: isolate markdown rendering lifecycle"
```

---

### Task 5: Atomic handler fallback and full regression gate

**Files:**
- Modify: `bin/nvimcat:1533-1830`
- Modify: `scripts/check-format-handlers.sh`
- Modify: `scripts/check-granular-scopes-tables.sh`
- Modify: `scripts/check.sh`
- Modify: `docs/superpowers/specs/2026-08-11-format-handler-boundary-design.md:1-4`

**Interfaces:**
- Produces: `_capture_once(width, files, *, force_plain=False) -> CaptureResult`.
- Produces: `CaptureResult(output: bytes, handler_id: str|None, handler_error: str|None, rc: int)`.
- `capture(width, files) -> int` remains the CLI boundary and is the only function that writes captured bytes to stdout.

- [ ] **Step 1: Add a failing atomic-fallback controller test**

Add a Python block to `scripts/check-format-handlers.sh` that imports the real controller and supplies a narrow fake for the slow Neovim subprocess boundary. The first attempt returns a failed Markdown `CaptureResult` containing partial bytes; the second forced-plain attempt returns a complete plain payload. Assert:

- the attempt arguments are `[False, True]` in that order;
- the returned status is zero;
- captured stderr contains a sanitized `markdown` fallback diagnostic;
- captured stdout contains only the second attempt's complete plain payload;
- the first attempt's partial rendered bytes are never emitted.

The fake replaces only process execution; fallback selection, buffering, diagnostics, and stdout emission remain real controller behavior.

The production mutation this catches is writing a partial rich projection before handler validation or failing without the specified plain retry.

- [ ] **Step 2: Run the fallback test and verify RED**

Run: `bash scripts/check-format-handlers.sh`

Expected: FAIL because `capture()` currently owns stdout and cannot retry atomically.

- [ ] **Step 3: Buffer one capture attempt**

Extract the current Neovim lifecycle into `_capture_once()`. It returns bytes and metadata; it never writes stdout. Preserve process cleanup in `finally` and convert incomplete stitching, line-count mismatch, registry diagnostics after rich startup, and renderer-hook exceptions into a nonzero `CaptureResult` with `handler_error`.

Implement the public boundary:

```python
def capture(width: int, files: list[str]) -> int:
    result = _capture_once(width, files, force_plain=False)
    if result.handler_error and result.handler_id:
        print(
            f"nvimcat: {result.handler_id} handler failed; retrying plain: "
            f"{result.handler_error}",
            file=sys.stderr,
        )
        result = _capture_once(width, files, force_plain=True)
    if result.rc != 0:
        return result.rc
    sys.stdout.buffer.write(result.output)
    sys.stdout.buffer.flush()
    return 0
```

Sanitize diagnostics to handler id plus exception text; never include a source line, full RPC payload, or buffer contents.

- [ ] **Step 4: Verify fallback GREEN**

Run: `bash scripts/check-format-handlers.sh`

Expected: the simulated handler failure emits only one complete plain capture and exits successfully.

- [ ] **Step 5: Run the focused regression matrix**

Run:

```bash
bash scripts/check-comment-leaders.sh
bash scripts/check-soft-break-addon.sh
bash scripts/check-soft-break-fence.sh
bash scripts/check-soft-break-segments.sh
python3 scripts/check-grid-ansi.py
bash scripts/check-no-md-stitch-rules.sh
bash scripts/check-page-invariant.sh
bash scripts/check-scroll-stitch.sh
timeout 150 bash scripts/check-plain-exact.sh
```

Expected: every command exits zero with no warnings or tracebacks.

- [ ] **Step 6: Run the large Markdown acid test three times**

Run:

```bash
for run in 1 2 3; do
  timeout 60 bash scripts/check-granular-scopes-tables.sh \
    "$HOME/wip_other/src_cavanaug/zoom-cli/.opencode/skills/zoom-skills/oauth/references/granular-scopes.md"
done
```

Expected on the current fixture: source count 3,457; bounded rendered count near the established 3,526 baseline; 221 ordered table frames; tail marker present; each run under the script's 45-second ceiling. Save three outputs during the script and compare their normalized byte streams so the repeated run proves determinism rather than only independent validity.

- [ ] **Step 7: Run the complete suite and static checks**

Run:

```bash
timeout 300 bash scripts/check.sh fixtures/sample.md
git diff --check
bash -n scripts/check-plain-exact.sh scripts/check-format-handlers.sh scripts/check.sh
python3 -m py_compile bin/nvimcat scripts/check-grid-ansi.py
```

Expected: all commands exit zero; sample performance remains below its existing ceiling; the optional real Markdown fixture passes when present.

- [ ] **Step 8: Update design status and commit on a non-default feature branch only**

Change the design status to `implemented and verified`, then:

```bash
git add bin/nvimcat lua/nvimcat scripts/check*.sh scripts/check-grid-ansi.py docs/superpowers/specs/2026-08-11-format-handler-boundary-design.md
git commit -m "fix: isolate rich format rendering"
```
