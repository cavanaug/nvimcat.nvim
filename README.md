# nvim-ansi-pager

**CLI: `nvimcat`** · **Neovim: `:NvimCat`**

Dump a file to the terminal as ANSI, rendered by **your** Neovim config — LazyVim, colorscheme, `render-markdown.nvim`, mermaid plugins, the lot — then exit.

```bash
nvimcat README.md
```

Not glow. Not mdcat. Not a second markdown engine. Your nvim is the renderer.

## Install

### Lazy.nvim (plugin + optional CLI)

```lua
{
  "cavanaug/nvim-ansi-pager", -- or { dir = "~/path/to/nvim-ansi-pager" }
  cmd = "NvimCat",
  opts = {
    -- disable_plugins = { "copilot.lua", ... },
  },
}
```

Put `bin/nvimcat` on your PATH (symlink is fine):

```bash
ln -sf /path/to/nvim-ansi-pager/bin/nvimcat ~/.local/bin/nvimcat
```

The CLI also `rtp:prepend`s the repo, so it works even if Lazy hasn’t loaded the plugin yet.

### CLI-only

Same symlink; no Lazy entry required. The Lua package loads from the repo beside `bin/`.

## Usage

```bash
nvimcat notes.md
NVIMCAT_WIDTH=100 nvimcat docs/guide.md
NVIMCAT_VERBOSE=1 nvimcat notes.md   # stderr progress
```

Inside Neovim:

```vim
:NvimCat                 " dump current buffer → scratch
:NvimCat path/to/file.md
```

## How it works

1. `nvimcat` starts `nvim --headless` with your normal config (`g:nvim_ansi_pager = 1`).
2. Waits until Lazy is ready (`VeryLazy` / short poll — not a fixed multi-second sleep).
3. Disables side-effect plugins (Copilot, etc.), opens the file via env (not argv).
4. Sizes the window, waits for decorations (tables / mermaid virt_lines) to settle.
5. Captures the screen grid → ANSI on stdout, then quits.

## Config

```lua
require("nvim-ansi-pager").setup({
  width = 80,
  min_wait_ms = 80,
  settle_ms = 120,
  timeout_ms = 8000,
  disable_plugins = { "copilot.lua", "copilot-cmp", "blink-copilot" },
})
```

## Requirements

- Neovim 0.10+
- Your usual plugin setup for the filetypes you care about
- A terminal/font that matches what you use inside nvim (Nerd Font icons, etc.)

## Limitations

- Color fidelity from `screenattr` is approximate; layout match is the priority.
- Very large files hit a `max_lines` cap and fall back to scroll-stitching.
- Configs that assume a real TUI may need a `g:nvim_ansi_pager` guard.
- Dump disables render-markdown `anti_conceal` and forces `fillchars.eob=~` for a clean capture.

## License

MIT
