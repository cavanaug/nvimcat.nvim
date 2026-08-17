# Format-handler boundary — design

**Date:** 2026-08-11
**Status:** approved
**Goal:** Preserve ordinary source files one buffer line at a time while isolating formats whose rendered display has different geometry.

## Reader and outcome

This document is for maintainers adding or changing capture behavior. After reading it, a maintainer should be able to add a specialized format without changing the ordinary-file path or weakening its line-identity guarantee.

## Decision

Use a fast default path plus optional, lazily selected format handlers.

The default path is not a generic handler instance. A registry lookup returns no handler for ordinary files, and capture proceeds directly with the plain-file contract. Python, Bash, Lua, C, C++, and other source formats use this path unless a future feature gives one of them genuinely different display geometry.

A handler is selected only for a format that needs stateful structure or adds rendered rows. The first handler is the Markdown family. Future candidates include LaTeX environments and, if needed, language-specific handling for stateful regions such as C-family block comments.

Registration remains internal initially. Public custom-handler registration is deferred until the contract has versioning, validation, diagnostics, and resource limits.

## Guarantees

### Plain-file contract

For an ordinary buffer:

- each source buffer line produces exactly one output row;
- source rows remain in source order, without insertion, deletion, or duplication;
- removing ANSI styling and terminal-cell padding yields Neovim's visible representation of the source row;
- content is never classified as UI chrome by matching its text;
- Markdown parsers, Mermaid detection, Markdown renderer updates, and decoration-aware overlap do not run;
- tall files may still be divided into capture pages, but page boundaries cannot change the line contract.

This contract protects literal code containing strings such as `Indexing`, `Indexed`, status labels, or box-drawing characters. UI noise must be prevented before capture or identified structurally; it must not be removed by scanning ordinary source text.

### Shared seam hints

Blank lines and stateless single-line comment leaders remain cheap, format-neutral hints for choosing page boundaries. Leaders come from Neovim's buffer options rather than a hard-coded language map. Python and Bash therefore discover `#` naturally.

C and C++ can similarly discover `//`. Their stateful `/* ... */` delimiter pair is deliberately excluded from the common path.

These hints affect only where capture pages end. They never add, delete, replace, or reinterpret a source row.

### Stateful constructs

Start/end constructs are not interpreted by the plain path. Examples include:

- C and C++ block comments delimited by `/*` and `*/`;
- Markdown fenced code blocks;
- Markdown tables and Mermaid blocks;
- LaTeX environments delimited by `\begin{...}` and `\end{...}`.

A file containing such constructs still receives exact plain capture by default. A specialized handler may use a parser to add preferred breaks, protect ranges from breaks, or project generated rows when the format's rendered geometry requires it. Delimiter-prefix heuristics do not belong in the shared path.

## Interface shape

The capture engine performs one metadata-only registry lookup per file:

```python
handler = registry.resolve(filetype=document.filetype, path=document.path)

if handler is None:
    return capture_plain_exact(document, common_seams)

session = handler.open(document, runtime)
return capture_projected(document, common_seams, session)
```

The internal interface is intentionally small:

```python
class FormatHandler(Protocol):
    def open(self, document: SourceDocument, runtime: FormatRuntime) -> FormatSession: ...

class FormatSession(Protocol):
    @property
    def break_hints(self) -> BreakHints: ...

    def project(self, page: CapturedPage) -> PageProjection: ...
```

`BreakHints` contains preferred break positions and protected source ranges. Shared blank and single-line-comment seams are always computed by the core, then merged with handler hints.

`PageProjection` labels each row with stable provenance: a source-line identity or a handler-owned generated-row identity. Rich-format stitching uses that provenance rather than repeated rendered text to resolve page overlap.

The registry stores lazy factories. Resolving an ordinary file does not import or initialize a specialized parser or renderer.

Each internal registration associates a unique handler id and a narrow set of normalized filetypes with one lazy factory. Conflicting filetype registrations are rejected at startup so selection remains deterministic. The initial registry contains only the Markdown family.

## Markdown handler

The Markdown-family handler owns all behavior that can change display geometry:

- Markdown-family filetype selection;
- heading and fence-aware break hints;
- protected fenced-code ranges;
- table rendering and virtual rows;
- Mermaid detection and generated rows;
- renderer settling;
- decoration-aware overlap;
- Markdown-specific output validation.

The handler may produce more output rows than source lines. Its conformance tests define allowed expansion and require complete, ordered source coverage.

No Markdown behavior is consulted for an ordinary file.

## Future handlers

A LaTeX handler can add protected environment ranges or projected display rows without changing plain capture. A C-family handler is optional rather than automatic: it is justified only if block-comment awareness improves page selection or a renderer changes display geometry. Until then, C and C++ remain exact plain files, and `/* ... */` is ordinary source content.

Internal handlers must declare their supported filetypes narrowly. Failure to load or validate a handler falls back atomically to exact plain capture with a diagnostic; partially projected output is never emitted.

## Testing

The implementation is accepted only with these tests:

1. Tall generated Python and Bash fixtures exceed the UI height limit, include blank lines and `#` comments, and produce exactly one output row per source line in source order.
2. Representative local Python and Bash files have exact line counts. Literal `Indexing` and `Indexed` strings remain present and unchanged.
3. Actual Python and Bash buffer options discover `#` as a single-line comment leader.
4. A tall C or C++ fixture contains multiline `/* ... */` comments, including internal blank lines, and still satisfies exact line identity without a handler.
5. Plain-file tests prove the Markdown handler factory, parser, renderer, and Mermaid detection are never loaded or called.
6. The large Markdown acid fixture permits bounded expansion, preserves head and tail markers, renders every source table as one ordered frame, remains deterministic, and meets its runtime ceiling.
7. An ambiguous repeated-row overlap fixture proves rich stitching never deletes legitimate repeated content.
8. Handler failure proves atomic fallback to the plain contract.

## Error handling

The plain path treats a line-count or source-order mismatch as a capture error rather than emitting corrupted output.

A rich handler validates its projection before emission. Invalid provenance, overlapping source ownership, missing source coverage, or handler exceptions discard the projection and restart through the plain path. Diagnostics identify the handler and reason without copying source content.

Rich output remains buffered until validation succeeds, making fallback atomic from the caller's perspective.

## Non-goals

- A public plugin API in this change.
- A LaTeX or C-family handler in this change.
- General parsing of paired delimiters in the plain path.
- Byte-for-byte preservation of terminal padding or ANSI sequences; the guarantee concerns source-row identity and visible source content.

## Alternatives rejected

### A handler for every file

A uniform `prepare`/`reconcile` handler keeps the engine symmetric, but ordinary files pay handler dispatch and are exposed to extension mistakes despite needing no special behavior.

### A composable capability pipeline

Independent break, projection, decoration, and overlap providers maximize flexibility. They also create a large ordering and conflict surface that is premature for one rich format.

### Global content filtering

Text-based cleanup appears simple but cannot distinguish UI messages from literal source code. It already removes valid Python rows containing progress-related strings and is incompatible with the plain-file contract.
