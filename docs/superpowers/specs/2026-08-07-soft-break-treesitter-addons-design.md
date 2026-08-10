# Soft-break treesitter addons — design addendum

**Date:** 2026-08-07  
**Status:** implemented (commits 03dc4d1..afbe1ab)  
**Parent:** [2026-08-06-soft-break-stitch-design.md](./2026-08-06-soft-break-stitch-design.md)  
**Goal:** Keep universal soft breaks (blank + Neovim line-comment leaders), and add **treesitter-discovered** extra seams + blank suppression so markdown (and later filetypes) cut on headings / fence opens without hardcoding prefix tables or resurrecting table/fence stitch heuristics.

## Problem

Parent soft-break stitch cuts only on blanks and line comments. Tall markdown often has:

- long pipe tables with **no** blanks for 1000+ lines → hard-cut mid-table (cursor/topline mid-row)
- blanks **inside** fenced code blocks → page split mid-fence, broken render

We want more seams (headers, fence open) and safer blanks, without returning to markdown-specific *advance/grow* logic.

## Decision

**Approach: treesitter discovery addons (chosen)**

1. Defaults unchanged: blank **or** whole-line comment leaders from `commentstring` / `comments`.
2. After edit + filetype settle, Lua queries the buffer treesitter parser (when available) for an **addon**:
   - `extra_breaks`: 1-based line numbers that are also soft breaks
   - `suppress_blanks`: inclusive 1-based line ranges where blanks are **not** soft breaks
3. Python segment split uses the combined predicate (below).
4. No parser / query failure → blanks + comments only (parent behavior).
5. Hard-cut at `UI_MAX_LINES` (1000) unchanged.

**Rejected for this addendum:** line-heuristic filetype prefix maps; large “every block type” seam sets (YAGNI).

## Soft-break predicate (amended)

A line `L` is a soft break iff:

1. `L` is in `extra_breaks`, **or**
2. `L` is blank/whitespace-only **and** `L` is **not** inside any `suppress_blanks` range, **or**
3. `L` is a whole-line comment per parent leader rules.

Comment / blank discovery stays as in the parent spec. Addons never remove comment soft breaks.

## Addon API (Lua → Python)

Single RPC helper (name illustrative), after filetype is applied:

```lua
-- returns:
-- {
--   extra_breaks = { integer... },      -- sorted unique 1-based lines
--   suppress_blanks = { {start, end}... } -- inclusive 1-based ranges
-- }
```

Python fetches this alongside comment leaders (or one combined soft-break payload). Empty tables on failure.

## Markdown addon (first filetype)

When `filetype` is markdown-like (`markdown`, `markdown.mdx`, or equivalent already used by nvimcat for render-markdown):

| Source (treesitter) | Effect |
|---------------------|--------|
| ATX / setext headings | line(s) → `extra_breaks` |
| `fenced_code_block` **opening fence** only | open fence line → `extra_breaks` |
| Interior of `fenced_code_block` (after open, before close) | → `suppress_blanks` |

**Not in v1:** fence close as a break; thematic breaks; HTML blocks; pipe-table row boundaries.

## Discovery principles

- Same spirit as comment leaders: **ask the live buffer**, don’t ship `ft → { "#", "```" }` tables for matching content.
- Treesitter node types / queries live in Lua next to `nvimcat.soft_break` (small markdown query module is fine). That is structure discovery, not scroll-stitch grow heuristics.
- Parent **non-goal** remains: no `_content_block_end` / `_is_table_line` / fence *viewport grow* on the advance path. Grep/guard for those stays.

## Segment / paint behavior

Unchanged from parent once the soft-break set is computed:

- Segments end on soft break (inclusive) or EOF; grow paint to fit ≤1000; hard-cut only when unbroken span >1000.
- Scroll still parks `lnum = topline`; concealcursor `nvic` (separate fix) keeps cursor-line links concealed.

## Testing

1. **Unit (no full LazyVim):** given fake `extra_breaks` / `suppress_blanks`, Python split respects extras and ignores blanks inside suppress ranges; comment/blank defaults still work with empty addon.
2. **Markdown fixture:** heading between dense pads; fenced block containing an internal blank — capture must not split inside the fence; segment may start on heading / fence open.
3. **Fallback:** buffer with no TS markdown parser → identical to pre-addon soft-break behavior on the same fixture.
4. Keep parent guards: no table/fence stitch helpers on advance; determinism checks still apply.

## Success criteria

1. Markdown headings and fence **opens** become soft breaks when treesitter is available.
2. Blanks inside fenced code do not create soft breaks.
3. Non-markdown / no-parser paths unchanged from parent.
4. No resurrection of markdown table/fence *stitch* heuristics.

## Out of scope

- Other filetype addons (add later with the same API).
- Using block comments or TS *comment* captures as soft breaks (parent may revisit separately).
- Changing hard-cut limit or grow-to-fit policy.
- Fixing malformed fixture URLs or rumdl/noice (handled elsewhere).

## Risks

| Risk | Mitigation |
|------|------------|
| TS query drift across parser versions | Prefer stable node names; empty addon on query error |
| Setext headings span two lines | Include both lines in `extra_breaks` or the heading start line only — pick start line in impl, unit-test |
| Large files: full-buffer TS walk cost | One walk per capture (with leaders); acceptable vs stitch cost |
| Extra breaks denser → more pages | Expected; still ≤1000 paint per segment |

## Relationship to parent spec

This **amends** the parent’s “markdown = blanks only” and “out of scope: treesitter” notes for soft breaks. Parent Approach A, leader parse, segment inclusivity, grow-to-fit, and hard-cut remain authoritative except where this addendum replaces the soft-break predicate and adds the addon RPC.
