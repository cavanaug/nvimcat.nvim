# nvimcat Embed UI Client Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace PTY + `nvim__screenshot` with `nvim --embed` + `nvim_ui_attach` so research-sized `nvimcat` lands near ~0.5s wall with composed-grid fidelity and no sleep-based settle/hold.

**Architecture:** `bin/nvimcat` execs `bin/nvimcat-embed`, which spawns `nvim --embed`, attaches a line-grid UI over msgpack-rpc, runs Lua dump after attach, waits until `is_ready` (condition only), sets a capture flag, redraws; on the next UI `flush` the client emits ANSI and quits.

**Tech Stack:** Bash launcher, Python 3 (stdlib + tiny vendored msgpack-rpc), Neovim 0.10+ `--embed` UI protocol, existing Lua `nvimcat` module.

**Spec:** `docs/superpowers/specs/2026-08-03-nvimcat-embed-ui-design.md`

## Global Constraints

- No pip/pynvim dependency for users — vendor minimal msgpack-rpc in-repo.
- No unconditional timed sleeps in dump hot path (`vim.wait(ms, function() return false end)` banned; `vim.wait(timeout, is_ready)` OK).
- Delete `min_wait_ms` / `settle_ms` / screen-hold from dump path.
- Success: research README median ≤ ~0.5s (worst ≤ ~0.7s); sample compare-tui MATCH; `check.sh` gate matches new budget.
- Keep Lazy-bypass bootstrap (`loadfile` from `NVIMCAT_ROOT`).
- Symlink-safe `ROOT` resolution in `bin/nvimcat` must remain.

## File map

| File | Role |
|------|------|
| `bin/nvimcat_msgpack.py` | Minimal msgpack encode/decode for Neovim RPC types we need |
| `bin/nvimcat-embed` | Embed UI client: spawn, attach, grid, ANSI, capture handshake |
| `bin/nvimcat` | Width probe + exec embed (drop PTY/shot) |
| `scripts/cli-entry.lua` | Load module only (client invokes `cli()` after UI attach) |
| `lua/nvimcat/init.lua` | Condition-only settle; capture flag; no screenshot/hold |
| `scripts/check.sh` | Perf gate ~700ms (or 1000ms if flaky); keep compare |
| `README.md` | How it works → embed UI |
| `bin/nvimcat-pty`, `bin/nvimcat-shot2ansi` | Leave in tree demoted; not on default path |

---

### Task 1: Vendored msgpack-rpc + embed attach smoke

**Files:**
- Create: `bin/nvimcat_msgpack.py`
- Create: `scripts/check-embed-smoke.sh`
- Create: `bin/nvimcat-embed` (smoke skeleton only — attach + `qa!`)

**Interfaces:**
- Produces: `nvimcat_msgpack.pack(obj) -> bytes`, `nvimcat_msgpack.Unpacker` feeding bytes → Python objects; `NvimEmbed` class with `request(method, *args)`, `notify` handling, `ui_attach(w,h)`, `close()`
- Consumes: none

- [ ] **Step 1: Write failing smoke script**

Create `scripts/check-embed-smoke.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export NVIMCAT_ROOT="$ROOT"
start="$(date +%s%3N)"
python3 "$ROOT/bin/nvimcat-embed" --smoke 80
end="$(date +%s%3N)"
elapsed=$((end - start))
echo "embed_smoke_ms=$elapsed"
# Floor check: must beat PTY (~1100ms). Target headless-class.
test "$elapsed" -lt 800
```

- [ ] **Step 2: Run smoke — expect fail (embed missing)**

Run: `bash scripts/check-embed-smoke.sh`  
Expected: FAIL (`No such file` or import error)

- [ ] **Step 3: Implement minimal msgpack + embed smoke**

`bin/nvimcat_msgpack.py` — support nil/bool/int/float/str/bin/array/map sufficient for Neovim RPC + UI events (no full msgpack ext beyond what Neovim sends for UI; use raw Ext as opaque if needed).

`bin/nvimcat-embed` smoke mode:

```python
# --smoke WIDTH: spawn nvim --embed --clean -n, ui_attach(WIDTH, 24), request qa!
# Print nothing on stdout; exit 0
```

Spawn argv:

```python
["nvim", "--embed", "--clean", "-n", "--headless"]
# Note: --embed already implies RPC on stdio; do not also forkpty.
# ui_attach then nvim_command("qa!")
```

Measure: smoke must complete **&lt; 800ms** (proves we left the PTY floor).

- [ ] **Step 4: Re-run smoke — expect pass**

Run: `bash scripts/check-embed-smoke.sh`  
Expected: `embed_smoke_ms=<800` and exit 0

- [ ] **Step 5: Commit**

```bash
git add bin/nvimcat_msgpack.py bin/nvimcat-embed scripts/check-embed-smoke.sh
git commit -m "$(cat <<'EOF'
feat: add embed UI smoke client with vendored msgpack-rpc

Prove nvim --embed + ui_attach avoids the ~1.1s PTY startup floor.
EOF
)"
```

---

### Task 2: Grid buffer + ANSI renderer (unit-tested, no nvim)

**Files:**
- Create: `bin/nvimcat_grid.py`
- Create: `scripts/check-grid-ansi.py`
- Modify: `bin/nvimcat-embed` (import grid helpers; still smoke-capable)

**Interfaces:**
- Consumes: msgpack structures shaped like UI `hl_attr_define` / `grid_line` / `grid_resize` / `flush` args
- Produces:
  - `class Grid: resize(w,h); apply_hl_attr_define(id, rgb_attrs, ...); apply_grid_line(grid, row, col_start, cells, wrap); to_ansi() -> bytes`
  - Cell = `(text: str, hl_id: int)`; hl map id → `{fg, bg, bold, italic, underline, reverse}`

- [ ] **Step 1: Write failing ANSI unit check**

`scripts/check-grid-ansi.py`:

```python
#!/usr/bin/env python3
from nvimcat_grid import Grid  # loaded via sys.path insert to bin/

g = Grid()
g.resize(1, 5)  # rows, cols — match whatever API you define; document in module
g.apply_hl_attr_define(1, {"foreground": 0xFF0000, "bold": True}, {}, {})
# grid_line data format per Neovim: list of [text, hl_id, repeat?] 
g.apply_grid_line(1, 0, 0, [["Hi", 1], ["!", 1]], False)
out = g.to_ansi()
assert b"\x1b[" in out and b"Hi!" in out.replace(b"\x1b[0m", b"").replace(b"\x1b[1m", b"") or b"Hi" in out
# Truecolor red somewhere:
assert b"255;0;0" in out or b"38;2;255;0;0" in out
print("OK grid_ansi")
```

(Adjust asserts to exact SGR grammar you emit — keep them strict.)

- [ ] **Step 2: Run unit check — expect fail**

Run: `cd bin && python3 ../scripts/check-grid-ansi.py`  
Expected: FAIL import / missing symbol

- [ ] **Step 3: Implement `nvimcat_grid.py`**

- Handle `grid_resize`, `hl_attr_define` (rgb keys), `grid_line` (cell triples with optional repeat), `grid_clear` / `grid_destroy` if seen.
- `to_ansi()`: for each row, emit SGR only when attrs change; end with reset; newline-separated rows; rstrip trailing spaces optional but match current shot2ansi behavior where possible (prefer visible content fidelity over blank padding).

- [ ] **Step 4: Run unit check — expect pass**

Run: `PYTHONPATH=bin python3 scripts/check-grid-ansi.py`  
Expected: `OK grid_ansi`

- [ ] **Step 5: Commit**

```bash
git add bin/nvimcat_grid.py scripts/check-grid-ansi.py bin/nvimcat-embed
git commit -m "$(cat <<'EOF'
feat: add line-grid to ANSI renderer for embed UI

Convert hl_attr_define/grid_line state into truecolor SGR text.
EOF
)"
```

---

### Task 3: Lua condition-only settle + capture flag

**Files:**
- Modify: `lua/nvimcat/init.lua`
- Create: `scripts/check-settle-no-sleep.sh` (static grep gate)

**Interfaces:**
- Consumes: existing `is_ready`, `try_force_render`, `prepare_chrome`, …
- Produces:
  - `settle(buf, win, opts, need_mermaid)` → waits only on `is_ready`, no post-ready padding
  - After ready (or timeout): `vim.g.nvimcat_capture = 1` then `vim.cmd("redraw!")`  
  - `M.dump` no longer calls `nvim__screenshot` / screen-hold / fixed false waits when `vim.env.NVIMCAT_EMBED == "1"` (or always once CLI is embed-only — prefer **always** remove hold/screenshot from dump; embed client owns capture)
  - Remove opts `min_wait_ms` / `settle_ms` from `DEFAULTS` (or ignore them)

- [ ] **Step 1: Write failing grep gate**

`scripts/check-settle-no-sleep.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Ban unconditional waits in dump path (allow vim.wait with predicate is_ready only via manual review).
if rg -n 'vim\.wait\([0-9]+,\s*function\(\)\s*return false' "$ROOT/lua/nvimcat/init.lua"; then
  echo "FAIL: unconditional vim.wait sleep still present" >&2
  exit 1
fi
if rg -n 'screen_fingerprint|nvim__screenshot|min_wait_ms|settle_ms' "$ROOT/lua/nvimcat/init.lua"; then
  echo "FAIL: legacy settle/hold/screenshot symbols still present" >&2
  exit 1
fi
echo "OK settle_no_sleep"
```

- [ ] **Step 2: Run gate — expect fail**

Run: `bash scripts/check-settle-no-sleep.sh`  
Expected: FAIL on existing sleeps / symbols

- [ ] **Step 3: Rewrite settle + dump capture end**

Replace `settle` with:

```lua
local function settle(buf, win, opts, need_mermaid)
  if not is_ready(buf, need_mermaid) then
    try_force_render(buf, win)
  end
  local ok = vim.wait(opts.timeout_ms, function()
    if is_ready(buf, need_mermaid) then
      return true
    end
    try_force_render(buf, win)
    return false
  end, 10)
  if not ok then
    io.stderr:write(
      "nvimcat: settle timeout (ready="
        .. tostring(is_ready(buf, need_mermaid))
        .. " mermaid="
        .. tostring(need_mermaid)
        .. ")\n"
    )
  end
  return is_ready(buf, need_mermaid)
end
```

End of `M.dump` after settle + chrome re-assert:

```lua
  mute_lsp_paint(buf)
  close_floating_windows()
  pcall(function()
    vim.fn.winrestview({ lnum = 1, col = 0, topline = 1, leftcol = 0 })
  end)
  vim.o.laststatus = 0
  vim.o.showtabline = 0
  vim.o.cmdheight = 0
  -- Signal embed client: next UI flush is the frame to emit.
  vim.g.nvimcat_capture = 1
  vim.cmd("redraw!")
  return "" -- embed client owns ANSI; dump returns empty in CLI embed mode
```

Remove: `screen_fingerprint`, hold loop, `capture_screenshot` from dump hot path, `min_wait_ms`/`settle_ms` defaults, second settle for height (height handled by client resize — see Task 4).

Keep `prep_compare` usable for agent-terminal harness (may still use short condition waits; do not reintroduce fingerprint hold — use redraw only).

- [ ] **Step 4: Run gate — expect pass**

Run: `bash scripts/check-settle-no-sleep.sh`  
Expected: `OK settle_no_sleep`

- [ ] **Step 5: Commit**

```bash
git add lua/nvimcat/init.lua scripts/check-settle-no-sleep.sh
git commit -m "$(cat <<'EOF'
fix: settle on decoration readiness only, signal embed capture

Drop sleep/hold/screenshot from dump; set g:nvimcat_capture for the UI client.
EOF
)"
```

---

### Task 4: Full embed client — attach, run cli, capture on flush

**Files:**
- Modify: `bin/nvimcat-embed`
- Modify: `scripts/cli-entry.lua`
- Modify: `lua/nvimcat/init.lua` (`M.cli` / `when_ready` unchanged in spirit; ensure works when invoked via RPC after attach)

**Interfaces:**
- Consumes: `nvimcat_msgpack`, `nvimcat_grid.Grid`, Lua `cli()` / `g:nvimcat_capture`
- Produces: ANSI on stdout; exit code 0/1

- [ ] **Step 1: Write failing integration check**

Extend or add `scripts/check-embed-sample.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp)"
export NVIMCAT_ROOT="$ROOT" NVIMCAT_WIDTH=80 NVIMCAT_EMBED=1
start="$(date +%s%3N)"
python3 "$ROOT/bin/nvimcat-embed" 80 "$ROOT/fixtures/sample.md" >"$OUT"
end="$(date +%s%3N)"
elapsed=$((end - start))
python3 - "$OUT" "$elapsed" <<'PY'
import re, sys
from pathlib import Path
raw = Path(sys.argv[1]).read_text()
plain = re.sub(r"\x1b\[[0-9;]*m", "", raw)
elapsed = int(sys.argv[2])
assert plain.strip(), "empty"
assert "\x1b[" in raw, "no sgr"
assert "Heading" in plain
assert elapsed < 1500, elapsed  # interim gate before research-tuned budget
print(f"OK embed_sample elapsed_ms={elapsed}")
PY
```

- [ ] **Step 2: Run — expect fail / incomplete client**

Run: `bash scripts/check-embed-sample.sh`  
Expected: FAIL (smoke-only embed cannot dump sample yet)

- [ ] **Step 3: Implement full `nvimcat-embed`**

Behavior:

1. Env: `NVIMCAT=1`, `NVIMCAT_ROOT`, `NVIMCAT_WIDTH`, `NVIMCAT_FILES` (path + `\x1e`), `NVIMCAT_EMBED=1`.
2. Estimate initial height: `max(24, min(200, line_count + 32))` (smaller than old PTY estimate; resize later if needed).
3. Spawn:

```python
["nvim", "--embed", "-n",
 "--cmd", "let g:nvimcat = 1",
 "--cmd", f"let g:nvimcat_root = '{root_esc}'",
 "--cmd", "let g:copilot_enabled = v:false",
 "--cmd", f"set rtp^={root}"]
```

4. Immediately `nvim_ui_attach(width, height, {"rgb": True, "ext_linegrid": True, "ext_newgrid": True})`.
5. `nvim_exec_lua` / `nvim_command` to `luafile scripts/cli-entry.lua` **after** attach (change cli-entry to only load + `require(...).cli()` as today, but must not race before UI exists — attach first).
6. Event loop: on `redraw` batches, apply grid events; on `flush`, if `nvim_get_var("nvimcat_capture") == 1` (request once per flush max), then:
   - Optionally `nvim_ui_try_resize` if Lua exposes `vim.g.nvimcat_rows` after settle (set in dump from `estimate_height`); redraw; wait one more flush.
   - `sys.stdout.buffer.write(grid.to_ansi())`
   - `nvim_command("qa!")`
7. Timeout via `NVIMCAT_TIMEOUT` (default 30s) without sleep-polling: select on child stdout with short intervals only for I/O (I/O wait ≠ settle sleep).

Update `cli-entry.lua` if needed so embed parent controls when `cli()` starts (already via luafile timing).

In `M.dump`, set `vim.g.nvimcat_rows = estimate_height(buf)` before capture flag so client can resize once.

- [ ] **Step 4: Run sample embed check — expect pass**

Run: `bash scripts/check-embed-sample.sh`  
Expected: `OK embed_sample elapsed_ms=...` under 1500

- [ ] **Step 5: Commit**

```bash
git add bin/nvimcat-embed scripts/cli-entry.lua lua/nvimcat/init.lua scripts/check-embed-sample.sh
git commit -m "$(cat <<'EOF'
feat: capture ANSI from embed UI grid after ready flag

Wire ui_attach, condition settle, and flush-triggered ANSI emit.
EOF
)"
```

---

### Task 5: Switch default CLI to embed + perf gates

**Files:**
- Modify: `bin/nvimcat`
- Modify: `scripts/check.sh`
- Modify: `README.md`
- Optional: leave `bin/nvimcat-pty` unused

**Interfaces:**
- Consumes: `nvimcat-embed`
- Produces: default user-facing CLI behavior

- [ ] **Step 1: Write failing research perf assertion**

Add to `scripts/check.sh` (or sibling `scripts/check-perf-research.sh` invoked when path exists):

```bash
RESEARCH="${NVIMCAT_PERF_FILE:-$HOME/wip_other/research/terminal-markdown-renderers/README.md}"
if [[ -f "$RESEARCH" ]]; then
  # run three times, median < 500ms, max < 700ms
fi
```

And change sample gate from `perf_under_4s` / 4000 to **`perf_under_1s` / 1000** (sample with mermaid should still fit).

- [ ] **Step 2: Run check — expect fail on current PTY default**

Run: `NVIMCAT_WIDTH=80 bash scripts/check.sh fixtures/sample.md`  
Expected: FAIL perf (still ~2s+) until launcher switched

- [ ] **Step 3: Point `bin/nvimcat` at embed**

Replace shot/PTY exec with:

```bash
exec python3 "$ROOT/bin/nvimcat-embed" "$NVIMCAT_WIDTH" "${files[@]}"
```

Update header comment. Remove `SHOT` temp file.

README “How it works”:

1. `nvim --embed` + UI attach (your config)  
2. Wait until decorations ready (condition)  
3. Emit composed grid as ANSI  

- [ ] **Step 4: Verify sample + research**

Run:

```bash
bash scripts/check.sh fixtures/sample.md
# expect OK perf + MATCH if agent-terminal present

# research (adjust path if needed):
TIMEFORMAT='REAL %R'
for i in 1 2 3; do time nvimcat "$HOME/wip_other/research/terminal-markdown-renderers/README.md" >/dev/null; done
```

Expected: sample check green; research times median ≤ 0.5s (document if host variance forces 0.7s gate — update check threshold only with evidence).

- [ ] **Step 5: Commit**

```bash
git add bin/nvimcat scripts/check.sh README.md
git commit -m "$(cat <<'EOF'
feat: make embed UI the default nvimcat path

Drop PTY screenshot from the launcher; tighten perf gates toward ~0.5s.
EOF
)"
```

---

### Task 6: Compare-tui fidelity + cleanup notes

**Files:**
- Modify: `scripts/compare-tui.sh` / `scripts/prep-compare.lua` only if MATCH fails due to embed vs PTY chrome
- Modify: `lua/nvimcat/init.lua` `prep_compare` if needed (no hold sleeps)
- Docs: short note in README Limitations if any intentional delta remains

- [ ] **Step 1: Run compare on sample**

Run: `bash scripts/check.sh fixtures/sample.md`  
Expected: `MATCH` or list mismatches

- [ ] **Step 2: If mismatches, fix root cause (not sleeps)**

Likely causes: height/resize, statusline chrome, topline, hl mapping. Fix Lua chrome or ANSI mapping; re-run until MATCH.

- [ ] **Step 3: Demote legacy binaries in README**

Note `nvimcat-pty` / `nvimcat-shot2ansi` are legacy; default is embed. Do not delete in this task unless unused and compare green (deletion optional follow-up).

- [ ] **Step 4: Final perf evidence**

Capture three research timings into the commit message body or a one-line comment in check script output.

- [ ] **Step 5: Commit**

```bash
git add -u
git commit -m "$(cat <<'EOF'
fix: align embed capture with TUI compare and document legacy PTY

EOF
)"
```

---

## Spec coverage (self-review)

| Spec requirement | Task |
|------------------|------|
| Drop forkpty default | 5 |
| `--embed` + `nvim_ui_attach` | 1, 4 |
| Vendored msgpack (no pip) | 1 |
| Condition-only settle | 3 |
| Capture handshake (flag + flush) | 3, 4 |
| ANSI from grid / hl attrs | 2, 4 |
| Height resize after ready | 4 (`nvimcat_rows`) |
| Research ≤ ~0.5s / ≤ ~0.7s worst | 5 |
| Sample MATCH | 6 |
| check.sh gate | 5 |
| README how-it-works | 5 |
| No sleep-based races | 3 + grep gate |

## Placeholder scan

None intentional. Ready-signal locked as **`vim.g.nvimcat_capture` checked on UI `flush`** (spec option 3, event-driven).
