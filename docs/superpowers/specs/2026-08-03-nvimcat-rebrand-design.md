# Nvimcat rebrand + Lazy CLI install

Date: 2026-08-03  
Status: approved (conversation)

## Goal

Rebrand the project to **nvimcat.nvim** / **Nvimcat** / **nvimcat**, and make Lazy/LazyVim install place the `nvimcat` CLI on a user PATH via `~/.local/bin`.

No capture/settle behavior changes.

## Naming

| Surface | Value |
|---|---|
| Repo | `nvimcat.nvim` |
| Product / plugin | Nvimcat |
| CLI | `nvimcat` |
| User command | `:NvimCat` (unchanged) |
| Lua module | `require("nvimcat")` |
| Plugin loader | `plugin/nvimcat.lua` |
| Package dir | `lua/nvimcat/init.lua` |
| Loaded guard | `g:loaded_nvimcat` |
| Headless flag | `g:nvimcat = 1` |
| Repo root | `g:nvimcat_root` / `NVIMCAT_ROOT` |
| Mode env | `NVIMCAT=1` |
| Other env | `NVIMCAT_WIDTH`, `NVIMCAT_FILES`, `NVIMCAT_VERBOSE` (keep) |

Internal annotations rename `nap.Opts` → `nvimcat.Opts`. Render-markdown caller id becomes `"nvimcat"`.

Out of scope: renaming the on-disk checkout directory / creating the GitHub remote (do when publishing).

## File moves

- `lua/nvim-ansi-pager/` → `lua/nvimcat/`
- `plugin/nvim-ansi-pager.lua` → `plugin/nvimcat.lua`
- `bin/nvimcat` stays; update env/globals/`require` strings inside
- `README.md` + comments/strings: full identity rewrite
- `scripts/check.sh`: unchanged unless it references old module names (it does not today)

## CLI install (Lazy / LazyVim)

Canonical pattern for a user-facing CLI from a Neovim plugin: symlink into `~/.local/bin` (XDG user bin). Not Mason — Mason only mutates Neovim’s process PATH.

Shared helper `M.install_cli()` (also called from `setup()` when `opts.install_cli ~= false`):

1. Resolve plugin root (rtp / `NVIMCAT_ROOT` / `g:nvimcat_root`).
2. Ensure `~/.local/bin` exists.
3. Symlink `~/.local/bin/nvimcat` → `<plugin>/bin/nvimcat`.
4. If target exists:
   - already the correct symlink → no-op
   - anything else → skip and `vim.notify` (never clobber)
5. Opt-out: `opts.install_cli = false` (skips the call from `setup()`; Lazy `build` still may run — see below).

**Why `build`:** With `cmd = "NvimCat"`, Lazy defers loading until the command runs, so `opts`/`setup()` alone would not create the symlink at install time. Install-time symlink uses Lazy `build`.

Ship repo-root `lazy.lua` package spec:

```lua
{
  "cavanaug/nvimcat.nvim",
  cmd = "NvimCat",
  opts = {},
  build = function()
    require("nvimcat").install_cli()
  end,
}
```

README documents the same for manual LazyVim plugin files, and notes that `~/.local/bin` must be on the shell PATH (common on modern Linux).

## Verification

- `./scripts/check.sh` still passes (behavior unchanged; names only).
- After `setup()` or Lazy `build`, `~/.local/bin/nvimcat` is a symlink to the plugin `bin/nvimcat` (or notify-skip if conflict).
- `install_cli = false` skips symlink from `setup()`; document that users who opt out should also omit/override `build` if they do not want install-time linking.

## Non-goals

- Mason registry packaging
- Windows-specific install (symlink/wrapper) beyond “don’t break Unix”; can follow later
- Changing `:NvimCat` command name or dump logic
