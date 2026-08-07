# Handoff — Neovim compose API + thin nvimcat

**Audience:** cold agent with no prior session memory  
**Date:** 2026-08-04  
**Goal:** Design/implement an upstream-style Neovim API that returns composed screen cells without a UI grid, then slim nvimcat to consume it (stream ANSI). Do **not** invent a standalone binary linked against private libnvim.

---

## Last action (this session)

Profiled nvimcat on a pathological markdown file (~3458 lines, ~2716 pipe-table rows). Root causes: settle thrash, Neovim `&lines` clamp at **1000**, futile giant UI resize, rumdl/LSP paint into the grid, and scroll-stitch paging in the Python embed client. Shipped **moderate fixes** in nvimcat (uncommitted on `master`) plus analysis that **compose-without-UI** needs a Neovim API; roadmap “externalized UI” does **not** replace that.

## Next action (for you)

1. Read this file + `docs/superpowers/specs/2026-08-04-nvimcat-embed-perf-followup.md`.
2. In the Neovim tree, confirm `win_line` → `linebuf_*` → `grid_line_flush` path and `check_screensize()` 1000 clamp (citations below).
3. Write a short design/PR sketch for **`nvim_win_get_screen_lines`** (name flexible) — API surface first, then a spike that draws one buffer range into a scratch/throttled grid and returns cells.
4. Only after the API spike works: plan nvimcat thin consumer (Lua loop + stream ANSI; drop embed scroll-stitch for dump path).

## Why this direction (locked decisions)

| Decision | Choice | Why |
|----------|--------|-----|
| Core primitive | **Compose API in stock Neovim** | Matches `nvim_eval_statusline` / `nvim_win_text_height`; reusable |
| Product CLI | **Thin nvimcat** loads user config | Fidelity = LazyVim + render-markdown, not a bare renderer |
| Not chosen | Builtin `nvim --print-screen` as *core* design | ANSI/chrome policy bikeshed; can be sugar later on top of API |
| Not chosen | Separate binary linking `libnvim.a` | No stable libnvim ABI; packaging/maintenance hell |
| Not chosen | Wait on roadmap “externalized UI” | That externalizes **chrome/layout**, not buffer cell composition |

---

## Problem statement

nvimcat’s value is: dump a buffer as ANSI using the user’s **real** Neovim config (theme, render-markdown, mermaid, etc.).

Today’s dump path:

```text
Python embed UI client
  → nvim --embed + ui_attach
  → Lua settle / force render-markdown
  → set nvimcat_capture; resize/scroll UI
  → client accumulates grid_line → ANSI
  → write stdout once (or scroll-stitch pages)
```

Pain on tall / table-heavy buffers:

1. **UI height clamp** — `Rows` max 1000 (`check_screensize` in Neovim).
2. **Compose only via UI** — cells only leave core as `grid_line` events; Lua cannot read the painted grid.
3. **Paging in Python** — scroll-stitch works but is slow and couples nvimcat to msgpack UI.
4. **render-markdown viewport marks** — RM decorates visible range; paging must re-`update` per page. A compose API does **not** remove this cost.

Baselines (WSL2, 2026-08-04, `granular-scopes.md`): mdcat ~24ms, glow ~180ms, nvimcat after fixes ~14–16s for full dump (complete, not truncated).

---

## Repos and paths

| Repo | Path |
|------|------|
| nvimcat | `/home/cavanaug/wip_other/src_cavanaug/nvimcat.nvim` |
| Neovim source | `/home/cavanaug/wip_other/src_general/neovim` |
| User nvimcat CLI | `~/.local/bin/nvimcat` → lazy install; sync from repo when testing |
| Pathological fixture | `~/wip_other/src_cavanaug/zoom-cli/.opencode/skills/zoom-skills/oauth/references/granular-scopes.md` |

**nvimcat git state (important):** `master` has **uncommitted** perf work:

- modified: `bin/nvimcat`, `lua/nvimcat/init.lua`
- untracked: `scripts/check-scroll-stitch.sh`

Do not discard without asking. Commit if the user wants that branch of work preserved before the API spike.

---

## Target architecture

```text
┌─────────────────────────────────────────────────────────┐
│  nvim process (user config loaded)                      │
│                                                         │
│  render-markdown / plugins → extmarks on ranges         │
│           ↓                                             │
│  nvim_win_get_screen_lines(win, opts)   ← NEW API       │
│           ↓                                             │
│  cells[] (schar + hl / RGB)                             │
└─────────────────────────────────────────────────────────┘
           ↓
┌─────────────────────────────────────────────────────────┐
│  thin nvimcat                                           │
│  - boot / settle / force RM for each range              │
│  - cells → ANSI                                         │
│  - stream pages to stdout (flush per chunk)             │
│  - no ui_attach / no scroll-stitch grid client          │
└─────────────────────────────────────────────────────────┘
```

Optional later sugar (not the design center): `nvim --print-screen file` as a 20-line wrapper over the same API.

---

## Neovim workstream (primary)

### API sketch (proposed)

```lua
-- Name flexible; spirit = offscreen window line composition
vim.api.nvim_win_get_screen_lines(win, {
  start_row = 0,       -- buffer row, 0-index
  end_row = -1,        -- exclusive / -1 = last
  width = 120,         -- or use window width
  max_rows = 500,      -- cap screen rows returned this call
  -- maybe: skip_statuscolumn, include_virt_lines (default true)
})
-- → array of screen rows:
-- { { text = "...", cells = { { text = "x", hl_id = N }, ... } }, ... }
```

**Precedent:** `nvim_eval_statusline` (compose without driving a remote UI), `nvim_win_text_height` (measure only).

### Implementation hints (from source read)

| Piece | Location | Notes |
|-------|----------|-------|
| Composition | `src/nvim/drawline.c` (`win_line`) | Buffer + syntax + extmarks + conceal + virt_text/lines + wrap |
| Line buffer | `linebuf_char` / `linebuf_attr` → `grid_line_flush` | `src/nvim/grid.c` |
| Viewport clip | `win_update` passes `wp->w_view_height` | Must not require full-buffer UI height |
| Scratch grid | `ScreenGrid.throttled` in `grid_defs.h` | “draw internally, don’t send to UI” |
| Height clamp | `check_screensize()` → `Rows = MIN(..., 1000)` | `drawscreen.c` ~419–424; also `'lines'` docs |
| Screenshot dead end | `nvim__screenshot` → TUI-only dump of **already painted** grid | Not an offscreen composer |

**Spike approach (recommended):** allocate a small scratch `ScreenGrid` / `GridView` (width × page_height), point a temporary view at it (or reuse window grid carefully), call `win_line` for a buffer range / topline window, copy `chars`+`attrs` out to API objects, resolve attrs to RGB via existing hl helpers. Chunked paging inside one API call or leave paging to the caller (`max_rows`).

### Acceptance for Neovim spike

- Headless/`--embed` **without** `nvim_ui_attach`: call API, get cells for a markdown buffer with virt_text/table decorations.
- Result matches (closely) what a UI grid would show for the same topline/width for that range.
- No dependency on `Rows >= buffer display height`.
- Tests in Neovim’s suite (Lua functional test).

### Upstream pitch (one sentence)

> Offscreen window line composition API, analogous to `nvim_eval_statusline`, reusing `win_line` into a throttled/scratch grid so tools can dump decorated buffers without a 1000-row UI or remote `grid_line` streaming.

---

## nvimcat workstream (after API exists)

### Keep

- Load full user config (`g:nvimcat`, disable copilot/lint/LSP side effects).
- Force/settle render-markdown (and mermaid when needed).
- ANSI encoding, eob `~` stripping, fidelity vs TUI (existing checks).

### Change

- Dump path: **no** `NVIMCAT_EMBED` UI attach / scroll-stitch for the happy path.
- For each range: ensure RM marks → `nvim_win_get_screen_lines` → ANSI → **stream flush**.
- Abort cleanly if stdout closes (pipe/`head`).

### RM viewport (still your problem)

Compose API returns whatever extmarks exist. For full-file dump:

```text
for each buffer window of N lines:
  force RM update for that viewport (scroll or synthetic)
  wait until marks ready (cheap is_ready)
  compose that range
  stream ANSI
```

Or: negotiate with render-markdown for a full-buffer / bulk decorate mode (plugin change; largest remaining CPU for table-heavy files).

### Existing nvimcat perf fixes (already in working tree)

Worth preserving / reviewing before rewriting dump path:

- Settle: force once, then poll (no per-tick `try_force_render` thrash).
- Treesitter parse once; mermaid only if needed.
- Disable `nvim-lint`; stop all LSP on attach (rumdl was leaking into grid).
- Cap UI rows at 1000; scroll-stitch at `_PAGE_LINES` default **100** in `bin/nvimcat` (empirical; override with `NVIMCAT_PAGE_LINES`).
- `scripts/check-scroll-stitch.sh` — tall buffer completeness check.
- Timing: `NVIMCAT_TIMING=1` → `/tmp/nvimcat-timing.log`.

Checks: `scripts/check.sh`, `check-embed-smoke.sh`, `check-scroll-stitch.sh`, `check-settle-no-sleep.sh`.

---

## What will / won’t get faster

| Change | Effect on `granular-scopes.md`-class files |
|--------|-----------------------------------------------|
| Compose API (no UI/msgpack grid) | Removes resize/scroll-stitch/UI overhead (seconds) |
| Stream pages | Better TTFB + early abort; little total-time win |
| Warm `nvim --listen` daemon | Amortizes config startup (separate win) |
| RM still viewport + 2700 tables | **Still dominates** until RM bulk-decorate or fewer pages |

Do not promise mdcat-like speed from the compose API alone.

---

## Open threads (noticed, not done)

- Stream flush in current Python client (easy UX win on stock nvim; optional before API).
- Research README median got slower under load in one bench (~2.5s); recheck after clean tree.
- `when_ready` tightened; validate no flake on slow Lazy starts.
- Builtin `--print-screen` sugar — only after API lands.
- render-markdown: ask upstream about range/full-buffer decorate for tooling.

## Do not

- Do **not** build a standalone binary linking private Neovim objects.
- Do **not** treat raising the 1000 `Rows` clamp as the solution (still huge grids + UI traffic; doesn’t fix RM).
- Do **not** expect roadmap `ext_windows` / externalized messages to provide buffer cell dumps.
- Do **not** put ANSI policy and eob/`~` chrome stripping into Neovim core if avoidable.
- Do **not** thrash `render-markdown.core.ui.update(..., true)` every poll tick (`debounce=0` schedules unbounded work).
- Do **not** assume `nvim_buf_get_extmarks` ≈ composed screen (misses conceal/wrap/folds/virt layout).

---

## Suggested milestone order

1. **Neovim spike** — API returns cells for one viewport-sized range, headless, tested.
2. **nvimcat prototype** — optional env e.g. `NVIMCAT_COMPOSE=1` using API when present; fallback to embed.
3. **Streaming + early abort** in nvimcat.
4. **Delete embed scroll-stitch** for dump once compose path is default.
5. **RM decorate strategy** pass (bulk or smarter range force) for table-heavy docs.
6. (Optional) Upstream PR for the API; (optional) `--print-screen` sugar.

## Cold-start commands

```bash
# nvimcat status
cd /home/cavanaug/wip_other/src_cavanaug/nvimcat.nvim
git status
NVIMCAT_TIMING=1 ./bin/nvimcat fixtures/sample.md >/dev/null
./scripts/check.sh fixtures/sample.md

# neovim landmarks
rg -n 'check_screensize|win_line\(|grid_line_flush|throttled' \
  /home/cavanaug/wip_other/src_general/neovim/src/nvim/{drawscreen,drawline,grid}.c \
  /home/cavanaug/wip_other/src_general/neovim/src/nvim/grid_defs.h
```

---

## Related docs in this repo

- `docs/superpowers/specs/2026-08-04-nvimcat-embed-perf-followup.md` — earlier timing budget
- `docs/superpowers/specs/2026-08-03-nvimcat-embed-ui-design.md` — why embed UI existed
- `docs/superpowers/plans/2026-08-03-nvimcat-embed-ui.md` — embed implementation plan

## External refs

- Roadmap: https://neovim.io/roadmap/ (“Externalized UI: window layout events, messages” ≠ compose API)
- Arch: Neovim `runtime/doc/dev_arch.txt` / https://neovim.io/doc/user/dev_arch/
