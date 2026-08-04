# nvimcat embed — follow-up performance notes

Measured on `feat/nvimcat-embed-ui` (WSL2), 2026-08-04.

## Current numbers

| Path | Typical wall |
|------|----------------|
| `nvim --headless` research README + `qa!` | ~0.5s |
| `nvimcat-embed --smoke` (`--clean`) | ~0.12s |
| `nvimcat` sample (mermaid) | ~0.55–0.9s |
| `nvimcat` research README (249 lines) | ~1.5–1.8s |

## Where research time goes

Example: wall **1687ms**, dump_span (enter→after_settle) **658ms**, remainder **~1029ms**.

| Phase | Research | Notes |
|-------|----------|--------|
| Before `dump_enter` + after settle | ~1.0s | `when_ready` (VeryLazy / poll up to 600ms + 900ms hard cap + `defer_fn(20)`), UI attach, capture flush, `qa!` |
| Edit → before settle | ~0.2–0.3s | chrome + open |
| Settle (`is_ready`) | ~0.5–0.6s | force `render-markdown` until extmarks exist |

Isolate headless (edit + load RM + force + wait ready, no embed UI): research **~0.4–0.7s** total process — so **decoration wait is real work**, not a sleep pad. Open+quit never pays for a full buffer decorate pass.

## Why settle ≫ open+quit

Open+quit loads the buffer and exits; Lazy may not finish markdown decoration.  
`nvimcat` must wait until `render-markdown` (and mermaid when present) has written extmarks — that is synchronous/async plugin work proportional to buffer complexity (tables, headings, code fences).

## Highest-leverage next cuts (no artificial delays)

1. **Shrink `when_ready`** — start dump as soon as `lazy.core.loader.init_done` (or filetype plugins for this buffer) instead of waiting on `VeryLazy` / 600–900ms caps. Likely recovers hundreds of ms before `dump_enter`.
2. **Don’t re-force-render every poll tick** — call `try_force_render` once (or on FileType), then `vim.wait(timeout, is_ready)` only. Repeated `render-markdown.core.ui.update(..., true)` on a 249-line buffer is expensive.
3. **Eager-load only markdown stack** under `g:nvimcat` — skip unrelated VeryLazy plugins for CLI dumps.
4. **Warm daemon** (`nvim --listen`) — amortize config load across invocations (out of scope for embed v1; largest win for repeated calls).
5. **Partial/viewport decorate** — if RM supports limiting update range, decorate visible/estimated height only (needs plugin cooperation).

## Non-goals for this note

Reintroducing timed settle/hold sleeps. PTY screenshot path (already demoted).
