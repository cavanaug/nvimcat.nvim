# nvimcat.nvim

**CLI: `nvimcat`** · **Neovim: `:NvimCat`**

Dump a file to the terminal as ANSI, rendered by **your** Neovim config — LazyVim, colorscheme, `render-markdown.nvim`, mermaid plugins, the lot — then exit.

```bash
nvimcat README.md
```

Not glow. Not mdcat. Not a second markdown engine. Your nvim is the renderer.

## Install

### Lazy.nvim / LazyVim

```lua
{
  "cavanaug/nvimcat.nvim", -- or { dir = "~/path/to/nvimcat.nvim" }
  cmd = "NvimCat",
  opts = {},
  build = function()
    require("nvimcat").install_cli()
  end,
}
```

On install/update (`build`) and whenever `setup()` runs, Nvimcat symlinks
`~/.local/bin/nvimcat` → the plugin’s `bin/nvimcat` (skips if something else
already occupies that path). Ensure `~/.local/bin` is on your shell `PATH`.

Opt out of the setup-time link:

```lua
opts = { install_cli = false }
```

(Also remove/override `build` if you do not want install-time linking.)

The CLI also `rtp:prepend`s the repo, so it works even if Lazy hasn’t loaded the plugin yet.

### CLI-only

```bash
ln -sf /path/to/nvimcat.nvim/bin/nvimcat ~/.local/bin/nvimcat
```

No Lazy entry required. The Lua package loads from the repo beside `bin/`.

## Usage

```bash
nvimcat notes.md
# uses current terminal width (override if needed):
NVIMCAT_WIDTH=100 nvimcat docs/guide.md
NVIMCAT_VERBOSE=1 nvimcat notes.md   # stderr progress
```

Inside Neovim:

```vim
:NvimCat                 " dump current buffer → scratch
:NvimCat path/to/file.md
```

## How it works

1. `nvimcat` starts `nvim --embed` with your normal config (`g:nvimcat = 1`) and attaches a UI client.
2. Waits until Lazy is ready (`VeryLazy` / short poll — not a fixed multi-second sleep).
3. Disables side-effect plugins (Copilot, etc.), opens the file via env (not argv).
4. Sizes the window, waits until decorations are ready (tables / mermaid virt_lines).
5. Emits the composed screen grid as ANSI on stdout, then quits.

## Config

```lua
require("nvimcat").setup({
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
- Configs that assume a real TUI may need a `g:nvimcat` guard.
- Dump disables render-markdown `anti_conceal` and forces `fillchars.eob=~` for a clean capture.

## License

MIT
