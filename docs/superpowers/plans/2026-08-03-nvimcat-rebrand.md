# Nvimcat Rebrand + Lazy CLI Install Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebrand to `nvimcat.nvim` / Nvimcat / `nvimcat` and install `~/.local/bin/nvimcat` on Lazy `build` + `setup()`.

**Architecture:** Mechanical rename of module/plugin paths and env/globals to the `nvimcat` identity. Add `M.install_cli()` that symlinks the repo `bin/nvimcat` into `~/.local/bin` without clobbering foreign files; call it from `setup()` (unless opted out) and from a repo-root `lazy.lua` `build` hook so LazyVim install creates the CLI even when the plugin is `cmd`-lazy-loaded.

**Tech Stack:** Neovim Lua, bash CLI wrapper, lazy.nvim package spec, existing `scripts/check.sh`.

## Global Constraints

- Repo name: `nvimcat.nvim`; product: Nvimcat; CLI: `nvimcat`; command: `:NvimCat` (unchanged spelling).
- Lua module: `require("nvimcat")` → `lua/nvimcat/init.lua`; plugin file: `plugin/nvimcat.lua`.
- Flags/env: `g:nvimcat`, `g:nvimcat_root`, `g:loaded_nvimcat`, `NVIMCAT`, `NVIMCAT_ROOT`; keep `NVIMCAT_WIDTH` / `NVIMCAT_FILES` / `NVIMCAT_VERBOSE`.
- No capture/settle behavior changes; no Mason; Unix symlink only for CLI install.
- Never overwrite an existing `~/.local/bin/nvimcat` that is not already our symlink.
- Opt-out: `opts.install_cli = false` skips symlink from `setup()`; users who also want no install-time link must omit/override Lazy `build`.
- Leave runnable checks: `scripts/check.sh` (dump) + `scripts/check-cli-install.sh` (symlink).
- Do not commit unless the user explicitly asks (plan commit steps are optional gates).

## File map

| File | Responsibility |
|---|---|
| `lua/nvimcat/init.lua` | Core dump + `setup` + `install_cli` + `cli` |
| `plugin/nvimcat.lua` | `:NvimCat` command registration |
| `bin/nvimcat` | Headless launcher (env + `require('nvimcat').cli()`) |
| `lazy.lua` | Lazy package defaults (`cmd`, `opts`, `build`) |
| `README.md` | Install/usage under new names |
| `scripts/check.sh` | Existing dump self-check (unchanged logic) |
| `scripts/check-cli-install.sh` | Symlink install self-check with temp `HOME` |

---

### Task 1: Rename module, plugin, env, and docs identity

**Files:**
- Move: `lua/nvim-ansi-pager/init.lua` → `lua/nvimcat/init.lua`
- Move: `plugin/nvim-ansi-pager.lua` → `plugin/nvimcat.lua`
- Modify: `bin/nvimcat`
- Modify: `lua/nvimcat/init.lua` (identity strings only)
- Modify: `plugin/nvimcat.lua`
- Modify: `README.md` (naming/paths; CLI install docs come in Task 3)
- Delete: old paths after move

**Interfaces:**
- Consumes: none
- Produces: `require("nvimcat")` with existing `M.setup`, `M.dump`, `M.dump_to_buffer`, `M.cli`; env `NVIMCAT` / `NVIMCAT_ROOT`; globals `g:nvimcat` / `g:nvimcat_root` / `g:loaded_nvimcat`

- [ ] **Step 1: Move files**

```bash
mkdir -p lua/nvimcat
git mv lua/nvim-ansi-pager/init.lua lua/nvimcat/init.lua 2>/dev/null || mv lua/nvim-ansi-pager/init.lua lua/nvimcat/init.lua
rmdir lua/nvim-ansi-pager 2>/dev/null || true
git mv plugin/nvim-ansi-pager.lua plugin/nvimcat.lua 2>/dev/null || mv plugin/nvim-ansi-pager.lua plugin/nvimcat.lua
```

- [ ] **Step 2: Update `bin/nvimcat` identity**

Replace the export/globals/`require` block so the file is:

```bash
#!/usr/bin/env bash
# nvimcat — dump a file as ANSI using your full Neovim config (plugins, themes, …).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export NVIMCAT=1
export NVIMCAT_ROOT="$ROOT"
export NVIMCAT_WIDTH="${NVIMCAT_WIDTH:-${COLUMNS:-80}}"

if ! command -v nvim >/dev/null 2>&1; then
  echo "nvimcat: nvim not found on PATH" >&2
  exit 127
fi

if [[ $# -lt 1 ]]; then
  echo "usage: nvimcat <file>..." >&2
  exit 2
fi

# Resolve paths now; do NOT pass files as nvim argv.
# Argv files are opened before -c runs, which fires BufReadPost and starts
# Copilot (and similar) auth before we can disable them.
files=()
for f in "$@"; do
  if [[ -e "$f" ]]; then
    files+=("$(cd "$(dirname "$f")" && pwd)/$(basename "$f")")
  else
    files+=("$f")
  fi
done
# RS-separated list (avoid NUL — bash warns in $(...)).
export NVIMCAT_FILES="$(printf '%s\x1e' "${files[@]}")"

# LazyVim rebuilds rtp during startup, so we prepend again in -c before require.
ROOT_VIM="${ROOT//\\/\\\\}"
ROOT_VIM="${ROOT_VIM//\'/\\\'}"

exec nvim --headless \
  --cmd "let g:nvimcat = 1" \
  --cmd "let g:nvimcat_root = '${ROOT_VIM}'" \
  --cmd "let g:copilot_enabled = v:false" \
  --cmd "set rtp^=${ROOT}" \
  -c "lua vim.opt.rtp:prepend(vim.env.NVIMCAT_ROOT or vim.g.nvimcat_root)" \
  -c "lua require('nvimcat').cli()"
```

- [ ] **Step 3: Update `plugin/nvimcat.lua`**

```lua
if vim.g.loaded_nvimcat then
  return
end
vim.g.loaded_nvimcat = true

--- :NvimCat [file...] — dump rendered view into a scratch buffer.
--- With no args, dumps the current buffer (must already be loaded).
vim.api.nvim_create_user_command("NvimCat", function(opts)
  local nvimcat = require("nvimcat")
  if opts.args ~= "" then
    for _, file in ipairs(opts.fargs) do
      nvimcat.dump_to_buffer({ file = file })
    end
    return
  end
  nvimcat.dump_to_buffer({})
end, {
  nargs = "*",
  complete = "file",
  desc = "Dump rendered buffer/file as plain text into a scratch buffer",
})
```

- [ ] **Step 4: Update identity strings inside `lua/nvimcat/init.lua`**

Apply these exact replacements (and no logic changes):

1. File header comment: `--- nvimcat: dump a buffer as ANSI using the user's full Neovim config.`
2. `@class nap.Opts` → `@class nvimcat.Opts` (all occurrences)
3. `@param opts? nap.Opts` → `@param opts? nvimcat.Opts` (all occurrences, including `nap.Opts|{file?: string}`)
4. `"nvim-ansi-pager"` in `render-markdown.core.ui`.update → `"nvimcat"`
5. In `M.cli()`:
   ```lua
   local root = vim.env.NVIMCAT_ROOT or vim.g.nvimcat_root
   ```
6. Grep for leftovers and fix any remaining `nvim-ansi-pager` / `nvim_ansi_pager` / `NVIM_ANSI_PAGER` / `nap.Opts` in this file.

- [ ] **Step 5: Update README identity (install CLI section deferred)**

Set title and core references:

```markdown
# nvimcat.nvim

**CLI: `nvimcat`** · **Neovim: `:NvimCat`**
```

Lazy snippet:

```lua
{
  "cavanaug/nvimcat.nvim", -- or { dir = "~/path/to/nvimcat.nvim" }
  cmd = "NvimCat",
  opts = {},
}
```

Symlink example path: `/path/to/nvimcat.nvim/bin/nvimcat`.  
Config: `require("nvimcat").setup({...})`.  
How-it-works / limitations: `g:nvimcat` (not `g:nvim_ansi_pager`).

- [ ] **Step 6: Verify dump still works under new names**

Run: `./scripts/check.sh`  
Expected: all checks `OK`, exit 0.

- [ ] **Step 7: Commit (only if user asked to commit)**

```bash
git add -A
git commit -m "$(cat <<'EOF'
refactor: rebrand to nvimcat.nvim / require("nvimcat")

Align repo, module, plugin guard, and env/globals with the nvimcat identity.
EOF
)"
```

---

### Task 2: `install_cli()` + setup hook + self-check

**Files:**
- Modify: `lua/nvimcat/init.lua` (`DEFAULTS`, `M.setup`, new `M.install_cli`, helper `plugin_root`)
- Create: `scripts/check-cli-install.sh`

**Interfaces:**
- Consumes: Task 1 module `require("nvimcat")`
- Produces:
  - `M.install_cli()` → `boolean` (`true` if symlink present/created as ours, `false` if skipped)
  - `opts.install_cli` default `true`; `setup()` calls `install_cli()` when enabled
  - `plugin_root()` resolution: `NVIMCAT_ROOT` / `g:nvimcat_root` / derive from `init.lua` path

- [ ] **Step 1: Write failing CLI-install check**

Create `scripts/check-cli-install.sh`:

```bash
#!/usr/bin/env bash
# Self-check: setup() symlinks ~/.local/bin/nvimcat (using temp HOME).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOME_TMP="$(mktemp -d)"
trap 'rm -rf "$HOME_TMP"' EXIT
export HOME="$HOME_TMP"

nvim --headless \
  --cmd "set rtp^=${ROOT}" \
  -c "lua require('nvimcat').setup({})" \
  -c "qa!"

link="$HOME_TMP/.local/bin/nvimcat"
target="$ROOT/bin/nvimcat"

if [[ ! -L "$link" ]]; then
  echo "FAIL: expected symlink at $link" >&2
  exit 1
fi
got="$(readlink "$link")"
if [[ "$got" != "$target" ]]; then
  echo "FAIL: symlink points to $got, want $target" >&2
  exit 1
fi

# Second setup is no-op / still correct.
nvim --headless \
  --cmd "set rtp^=${ROOT}" \
  -c "lua require('nvimcat').setup({})" \
  -c "qa!"
got2="$(readlink "$link")"
[[ "$got2" == "$target" ]] || { echo "FAIL: rerun changed link" >&2; exit 1; }

# Opt-out does not remove existing link; with empty bin and install_cli=false, no link created.
HOME_TMP2="$(mktemp -d)"
export HOME="$HOME_TMP2"
nvim --headless \
  --cmd "set rtp^=${ROOT}" \
  -c "lua require('nvimcat').setup({ install_cli = false })" \
  -c "qa!"
if [[ -e "$HOME_TMP2/.local/bin/nvimcat" ]]; then
  echo "FAIL: install_cli=false created a link" >&2
  exit 1
fi

echo "OK cli_install"
```

```bash
chmod +x scripts/check-cli-install.sh
```

- [ ] **Step 2: Run check to verify it fails**

Run: `./scripts/check-cli-install.sh`  
Expected: FAIL (no `install_cli` / no symlink yet), non-zero exit.

- [ ] **Step 3: Implement `plugin_root`, `install_cli`, and wire `setup`**

In `lua/nvimcat/init.lua`, extend defaults and add helpers near `M.setup`:

```lua
local DEFAULTS = {
  width = tonumber(vim.env.COLUMNS) or 80,
  min_wait_ms = 80,
  settle_ms = 120,
  timeout_ms = 8000,
  max_lines = 5000,
  install_cli = true,
  disable_plugins = {
    "copilot.lua",
    "copilot-cmp",
    "blink-copilot",
    "CopilotChat.nvim",
    "codecompanion.nvim",
    "avante.nvim",
    "supermaven-nvim",
    "tabnine-nvim",
  },
}
```

Add (above `M.setup`):

```lua
local function plugin_root()
  local root = vim.env.NVIMCAT_ROOT or vim.g.nvimcat_root
  if type(root) == "string" and root ~= "" then
    return root
  end
  local src = debug.getinfo(1, "S").source
  if src:sub(1, 1) == "@" then
    -- lua/nvimcat/init.lua → repo root
    return vim.fn.fnamemodify(src:sub(2), ":p:h:h:h")
  end
  return nil
end

--- Symlink bin/nvimcat into ~/.local/bin (no clobber).
---@return boolean ok
function M.install_cli()
  local root = plugin_root()
  if not root then
    vim.notify("nvimcat: cannot resolve plugin root for CLI install", vim.log.levels.WARN)
    return false
  end
  local src = root .. "/bin/nvimcat"
  if vim.fn.filereadable(src) ~= 1 then
    vim.notify("nvimcat: missing " .. src, vim.log.levels.WARN)
    return false
  end
  local bindir = vim.fn.expand("~/.local/bin")
  vim.fn.mkdir(bindir, "p")
  local dest = bindir .. "/nvimcat"
  local uv = vim.uv or vim.loop
  local stat = uv.fs_lstat(dest)
  if stat then
    if stat.type == "link" then
      local current = uv.fs_readlink(dest)
      if current == src then
        return true
      end
    end
    vim.notify("nvimcat: " .. dest .. " exists; not overwriting", vim.log.levels.WARN)
    return false
  end
  local ok, err = uv.fs_symlink(src, dest)
  if not ok then
    vim.notify("nvimcat: symlink failed: " .. tostring(err), vim.log.levels.WARN)
    return false
  end
  return true
end
```

Update `M.setup`:

```lua
function M.setup(opts)
  config = vim.tbl_deep_extend("force", DEFAULTS, opts or {})
  if config.install_cli then
    M.install_cli()
  end
end
```

Also add `install_cli?` to the `---@class nvimcat.Opts` annotations.

- [ ] **Step 4: Run CLI-install check to verify it passes**

Run: `./scripts/check-cli-install.sh`  
Expected: `OK cli_install`, exit 0.

- [ ] **Step 5: Re-run dump check (no regressions)**

Run: `./scripts/check.sh`  
Expected: all `OK`, exit 0.

- [ ] **Step 6: Commit (only if user asked to commit)**

```bash
git add lua/nvimcat/init.lua scripts/check-cli-install.sh
git commit -m "$(cat <<'EOF'
feat: symlink nvimcat into ~/.local/bin on setup

Install the CLI for Lazy/manual setup without clobbering an existing binary.
EOF
)"
```

---

### Task 3: Lazy package spec + README install docs

**Files:**
- Create: `lazy.lua`
- Modify: `README.md` (Install section)

**Interfaces:**
- Consumes: `M.install_cli()` from Task 2
- Produces: Lazy defaults with `cmd = "NvimCat"`, `opts = {}`, `build` calling `require("nvimcat").install_cli()`

- [ ] **Step 1: Add repo-root `lazy.lua`**

```lua
return {
  "cavanaug/nvimcat.nvim",
  cmd = "NvimCat",
  opts = {},
  build = function()
    require("nvimcat").install_cli()
  end,
}
```

- [ ] **Step 2: Update README Install section**

Replace the Install section with:

```markdown
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
```

Keep Usage / How it works / Config / Requirements / Limitations / License; ensure Config uses `require("nvimcat")` and Limitations mention `g:nvimcat`.

- [ ] **Step 3: Sanity-check Lazy build path headlessly**

Run:

```bash
ROOT="$(pwd)"
HOME_TMP="$(mktemp -d)"
export HOME="$HOME_TMP"
nvim --headless \
  --cmd "set rtp^=${ROOT}" \
  -c "lua assert(require('nvimcat').install_cli())" \
  -c "qa!"
test -L "$HOME_TMP/.local/bin/nvimcat"
readlink "$HOME_TMP/.local/bin/nvimcat" | grep -F "$ROOT/bin/nvimcat"
rm -rf "$HOME_TMP"
```

Expected: asserts pass; symlink points at repo `bin/nvimcat`.

- [ ] **Step 4: Run both checks**

Run: `./scripts/check-cli-install.sh && ./scripts/check.sh`  
Expected: both exit 0.

- [ ] **Step 5: Commit (only if user asked to commit)**

```bash
git add lazy.lua README.md
git commit -m "$(cat <<'EOF'
docs: LazyVim install ships nvimcat on PATH

Add lazy.lua build hook and document ~/.local/bin symlink behavior.
EOF
)"
```

---

## Plan self-review

1. **Spec coverage:** Naming table → Task 1; file moves → Task 1; `install_cli` + setup + no-clobber → Task 2; Lazy `build` + README PATH note → Task 3; verification scripts → Tasks 1–3. Non-goals (Mason, Windows, command rename) omitted.
2. **Placeholders:** None; concrete code and commands included.
3. **Type consistency:** `M.install_cli()` / `opts.install_cli` / `NVIMCAT_ROOT` / `g:nvimcat_root` / `require("nvimcat")` consistent across tasks.
