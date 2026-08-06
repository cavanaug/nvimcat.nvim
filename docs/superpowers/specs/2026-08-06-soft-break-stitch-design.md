# Soft-break scroll-stitch — design

**Date:** 2026-08-06  
**Status:** approved (design sections LGTM; awaiting spec file review)  
**Goal:** Eliminate wrong/missing lines and run-to-run non-determinism in tall-file scroll-stitch by cutting pages only on blank lines or Neovim-discovered line comments — for **all** filetypes, with **no** markdown-specific structure rules.

## Problem

Tall buffers exceed Neovim’s UI height cap (~1000) and must be scroll-stitched. Advancing at painted `bot+1` (and earlier markdown table/fence heuristics) still cuts mid-content. Those cuts interact badly with stale-grid captures and overlap trimming, producing:

- wrong or duplicated file lines at page seams
- non-deterministic ANSI / line counts across identical runs

This has been persistent across markdown and non-markdown files. Soft aesthetic seams are not the primary concern — **content identity and determinism** are.

## Decision

**Approach A — Soft-break segments**

1. Discover **line-comment leaders** at runtime from the embed Neovim buffer options (`commentstring`, `comments`). No filetype→prefix table in nvimcat.
2. Split the buffer into **segments** that each end on a soft break (blank or line-comment) or EOF.
3. For each segment with length ≤ UI max, **grow paint height** so the whole segment fits in one capture, then advance to the next segment.
4. Retire markdown-specific stitch helpers (`_content_block_end`, `_is_table_line`, table/fence grow logic).

## Soft breaks

A buffer line is a **soft break** if either:

1. It is empty or whitespace-only, or
2. After optional indent, it is a **whole-line comment** according to leaders discovered for this buffer.

### Leader discovery (runtime only)

After filetype is applied on the captured buffer, query Neovim (RPC / Lua helper):

- `vim.bo[buf].commentstring` — if the format is a line comment (`<leader>%s` without block delimiters), extract `<leader>`
- `vim.bo[buf].comments` — parse Vim’s comma-separated `comments` option; collect **line** leaders only (e.g. parts like `://`, `b:#`, `:--`)

**Line-comment match:** after indent, the line starts with a discovered leader. If that leader came from a `comments` part with the `b` flag (blank required), the next character must be whitespace or end-of-line. Leaders derived only from `commentstring` use the same blank-or-EOL rule (the `%s` form implies a separated comment body).

**Out of scope for soft breaks:** block-only forms (`/* … */`, `<!-- … -->`). They are not reliable single-line page boundaries. If Neovim exposes only block forms (or nothing), soft breaks are **blanks only** — including typical markdown, without special-casing markdown in code.

**Explicit non-goal:** no hardcoded map such as “python → `#`”, “lua → `--`”. Whatever Neovim reports for that buffer wins.

## Segments

Scan buffer lines once (1-based inclusive ranges):

- A segment starts at the first uncovered line.
- It extends through content until (and including) the next soft-break line, or through EOF if none.
- The next segment starts at `end + 1`.

So the soft-break line belongs to the segment it terminates.

## Stitch loop

After settle, before paging:

1. `nvim_buf_get_lines` for full buffer text.
2. Fetch line-comment leaders for the current buffer from Neovim.
3. Build the soft-break segment list.

Per segment:

1. `page_h = min(UI_MAX_LINES, max(stitch_floor, segment_len + 16))`  
   - `+ 16` is fixed chrome / virt-line slack (not content-dependent fudge).  
   - `stitch_floor` = default stitch height / `NVIMCAT_STITCH_HEIGHT` (paint **minimum**, not identity knob).  
   - `NVIMCAT_PAGE_LINES` must **not** control paint height (unchanged policy).
2. `nvim_ui_try_resize` to `page_h` when needed → scroll so `topline = segment.start` → wait for stable grid → append ANSI.
3. Keep `_trim_page_overlap` as a **safety net**, not the primary correctness mechanism.
4. Advance to `segment.end + 1` (not raw `bot+1`).

### Hard ceiling

While building segments: if the distance from segment start to the next soft break (or EOF) exceeds `UI_MAX_LINES` (1000), emit a hard segment `[start, start+999]`, then continue from `start+1000`. That mid-content cut is the only exception (Neovim UI clamp).

## Removals

| Remove from stitch path | Replacement |
|-------------------------|-------------|
| `_content_block_end` | soft-break segments |
| `_is_table_line` | none (not used for paging) |
| Markdown table/fence viewport grow | grow-to-fit per soft-break segment |

Settle / non-markdown timeout short-circuit (skip render-markdown waits) stays as already landed; out of scope to redesign further here.

## Architecture sketch

```
bin/nvimcat (stitch)
  → get buffer lines
  → RPC: line_comment_leaders(buf)  # from commentstring + comments
  → segments = split_on_soft_breaks(lines, leaders)
  → for seg in segments:
        grow UI to fit seg (≤1000)
        scroll to seg.start
        capture + overlap-trim
        advance seg.end+1
```

**Leader parsing lives in Lua** (small helper returning `{ leader, blank_required }` rows from `commentstring` + `comments`). Python only splits lines using that list. Source of truth is Neovim’s buffer options, not a local filetype table.

## Testing

1. **Unit (no LazyVim boot):** soft-break split + leader parse from sample `commentstring` / `comments` strings; blank-only when leaders empty.
2. **Determinism:** same tall file × 3 → identical output (existing `check-deterministic-capture.sh`; extend or twin for a tall non-markdown fixture with comments).
3. **Page invariant:** paint floor changes (`NVIMCAT_STITCH_HEIGHT`) must not change normalized content when segments fit (retain/adapt `check-page-invariant.sh`).
4. **No markdown stitch rules:** grep/guard that table/fence helpers are gone from the advance path.

## Success criteria

1. Deterministic captures on tall markdown and tall non-markdown.
2. No markdown-specific rules in page advance.
3. Comment leaders come only from Neovim buffer options.
4. Segments ≤1000 paint in one page; advances land on soft-break boundaries (except the >1000 unbroken hard-cut case).
5. Checks above pass.

## Out of scope

- Further settle / timing work beyond what’s already shipped for non-markdown.
- Reintroducing `NVIMCAT_PAGE_LINES` as paint height.
- Using block comments or treesitter comment captures for page cuts (may revisit later if blanks-only proves insufficient for some filetypes).
- Changing overlap-trim algorithm beyond keeping it as a safety net.

## Risks

| Risk | Mitigation |
|------|------------|
| Filetypes with no line leaders and few blanks (dense tables) | Grow to fit until blank or 1000; hard-cut only past 1000 |
| Wrong parse of exotic `comments` values | Prefer well-defined line flags; unit-test common option strings; blanks still work |
| Resize churn / races while growing | One resize per segment; reuse existing stable-grid wait |
| Leader fetch before filetype | Query leaders only after edit + filetype settled (same point we already have buf lines) |
