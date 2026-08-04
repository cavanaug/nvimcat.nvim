# nvimcat embed UI client — design

**Date:** 2026-08-03  
**Status:** approved (LGTM)  
**Goal:** `nvimcat` on research-sized markdown in ~0.5s wall, TUI-grid fidelity, no sleep-based settle/hold.

## Problem

Current `nvimcat` uses `forkpty` + `nvim__screenshot`. On this host a synthetic PTY alone costs ~1.1s even for `nvim --clean -c qa!`, while the same quit on a real TTY or `--headless` is ~0.3–0.5s. Artificial `min_wait_ms` / `settle_ms` / screen-hold sleeps add more latency and paper over races.

## Decision

Replace the PTY screenshot path with:

1. `nvim --embed` + msgpack-rpc `nvim_ui_attach` (composed grid, same class of fidelity as screenshot)
2. Condition-only settle (`vim.wait(timeout, is_ready)` — no post-ready sleeps)
3. Explicit ready → capture handshake (not “sleep then hope”)

## Architecture

```
bin/nvimcat
  → bin/nvimcat-embed (Python msgpack-rpc UI client)
       spawns: nvim --embed -n … + scripts/cli-entry.lua
       nvim_ui_attach(width, height, { rgb=true, ext_linegrid=true })
       Lua: open file → chrome/silence → force render → wait until ready → signal capture
       client: accumulate grid_line / hl_attr_define; on capture signal + flush → ANSI stdout
```

PTY + `nvim__screenshot` are removed from the default hot path (optional legacy/debug only if kept at all).

## Components

### `bin/nvimcat`

- Resolve symlink → plugin root (already fixed).
- Probe width (`NVIMCAT_WIDTH` / TTY / `COLUMNS` / 80).
- Exec `nvimcat-embed` with width + files (no PTY, no shot temp file).

### `bin/nvimcat-embed`

- Spawn `nvim --embed` with existing `--cmd` / `cli-entry.lua` bootstrap (load worktree module, bypass Lazy hijack).
- `nvim_ui_attach(width, height, {rgb=true, ext_linegrid=true})`.
- Maintain grid cell buffer + highlight attr table from UI events.
- Height: start from a conservative estimate; after Lua reports content height (or after ready), `nvim_ui_try_resize` once if needed, then capture.
- On capture signal, wait for the next `flush`, render ANSI to stdout, then `qa!`.
- Prefer a **minimal vendored msgpack-rpc** (or stdlib-only if practical) so `nvimcat` stays dependency-light; pynvim only if vendoring is clearly worse.

### Lua `dump` / `cli`

Keep: chrome prep, side-effect plugin disable, anti-conceal off, force render (render-markdown / mermaid), `is_ready` predicates.

Change:

| Remove | Replace with |
|--------|----------------|
| `min_wait_ms` / `settle_ms` padding after ready | return as soon as `is_ready` |
| screen-fingerprint hold loop | UI `flush` after ready signal |
| `vim.wait(ms, function() return false end)` “just in case” | none in dump hot path |
| `nvim__screenshot` + `shot2ansi` on hot path | embed client ANSI |

Settle loop shape:

```lua
try_force_render(...)
vim.wait(opts.timeout_ms, function()
  return is_ready(buf, need_mermaid)
end, 10)
-- if not ready: stderr warning, still capture best-effort
signal_capture()  -- RPC notify or chan_send / marker the client understands
```

Ready signal options (pick one in implementation; prefer RPC notify):

1. `vim.rpcnotify(0, "nvimcat_capture", {})` if channel 0 is the embed UI (verify), or
2. Dedicated notification on the UI channel the client owns, or
3. `nvim_set_var` / shared once-flag the client polls via RPC **without sleep** (request in event loop).

Mermaid: still condition on `has_mermaid_decor` (async bm). No timed settle window after it appears.

### ANSI emission

Map `hl_attr_define` → SGR (truecolor when present). Emit one line per grid row; strip chrome rows if still present after Lua chrome kill. Reuse lessons from `nvimcat-shot2ansi` (SGR carry across rows) where applicable; implementation may live in the embed client rather than shelling to shot2ansi.

## Non-goals

- Warm daemon / long-lived `nvim --listen` (can be a later optimization).
- Hand-rolled extmark→ANSI reconstruct as the primary path (option B; rejected).
- Guaranteeing sub-0.5s on pathological configs that load multi-second plugins before `VeryLazy`.

## Success criteria

- Sample fixture: **≤ ~1s** wall; compare-tui **MATCH**.
- Research README (`terminal-markdown-renderers/README.md`): **median ≤ ~2s** / max **≤ ~3s** after embed migration (measured ~1.5–2s; PTY floor removed). Stretch target remains ~0.5s — limited by render-markdown settle on large buffers, not PTY (see follow-up perf notes).
- `scripts/check.sh` gates match the budgets above.
- Dump path contains **no** unconditional timed sleeps for race avoidance.

## Risks / mitigations

| Risk | Mitigation |
|------|------------|
| Embed UI attach still slow | Measure early; if >0.5s floor, profile attach vs Lazy — may need earlier `cli` before VeryLazy for markdown-only |
| Ready fires before final mermaid virt_lines | `is_ready` already requires mermaid decor when fences exist; force-render + pump until true |
| Resize after ready flickers grid | Single `nvim_ui_try_resize` then one forced redraw + flush before capture |
| Msgpack dependency weight | Vendor minimal client; no pip install required for users |

## Migration

1. Implement embed client + Lua handshake behind default CLI.
2. Retire PTY from `bin/nvimcat` default.
3. Keep `nvimcat-shot2ansi` until compare harness is green; delete or demote after.
4. Update README “How it works” to describe embed UI, not PTY screenshot.
