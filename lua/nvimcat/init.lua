--- nvimcat: dump a buffer as ANSI using the user's full Neovim config.
local M = {}

---@class nvimcat.Opts
---@field width? integer
---@field timeout_ms? integer
---@field max_lines? integer
---@field compose? boolean
---@field install_cli? boolean
---@field disable_plugins? string[]

-- Neovim clamps &lines / UI height at 1000; requesting more only burns CPU.
local UI_MAX_LINES = 1000

local DEFAULTS = {
  -- width: nil → NVIMCAT_WIDTH / COLUMNS / vim.o.columns (see prepare_chrome)
  timeout_ms = 8000,
  max_lines = 5000,
  compose = false,
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
    -- Lint/spell on large markdown (cspell via nvim-lint) dwarfs render time.
    "nvim-lint",
    "mason-nvim-lint",
  },
}

local config = vim.deepcopy(DEFAULTS)

local function _timing(msg)
  if vim.env.NVIMCAT_TIMING ~= "1" then
    return
  end
  local f = io.open("/tmp/nvimcat-timing.log", "a")
  if f then
    f:write(string.format("%d %s\n", vim.uv.now(), msg))
    f:close()
  end
end

local function merge(opts)
  return vim.tbl_deep_extend("force", config, opts or {})
end

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

--- Plugin setup (Lazy `opts` / `require(...).setup`).
---@param opts? nvimcat.Opts
function M.setup(opts)
  config = vim.tbl_deep_extend("force", DEFAULTS, opts or {})
  if config.install_cli then
    M.install_cli()
  end
end

local function buffer_needs_mermaid(buf)
  for _, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if l:match("^```%s*mermaid") then
      return true
    end
  end
  return false
end

local function ensure_lazy_markdown_plugins()
  pcall(function()
    require("lazy.core.loader").load({
      plugins = {
        "render-markdown.nvim",
        "render-markdown-mermaid.nvim",
      },
    }, { start = "nvimcat" })
  end)
  pcall(vim.cmd, "doautocmd FileType " .. (vim.bo.filetype ~= "" and vim.bo.filetype or "markdown"))
  return pcall(require, "render-markdown.core.ui")
end

local plugins_loaded = false

local function ensure_mermaid_setup()
  local mod = require("render-markdown-mermaid")
  if mod.config then
    return mod
  end
  local opts = { mode = "unicode", placement = "above", replace = true }
  pcall(function()
    local p = require("lazy.core.config").plugins["render-markdown-mermaid.nvim"]
    if p and p.opts then
      opts = vim.tbl_deep_extend("force", opts, type(p.opts) == "function" and p.opts() or p.opts)
    end
  end)
  mod.setup(opts)
  return mod
end

local ts_parsed = false

local function try_force_render(buf, win, need_mermaid)
  if not plugins_loaded then
    plugins_loaded = ensure_lazy_markdown_plugins()
  end
  pcall(function()
    vim.wo[win].conceallevel = 2
    vim.wo[win].concealcursor = ""
  end)
  -- Full-buffer parse once; repeating it every settle poll dominates large files.
  if not ts_parsed then
    pcall(function()
      vim.treesitter.get_parser(buf, "markdown"):parse(true)
    end)
    ts_parsed = true
  end
  pcall(function()
    require("render-markdown.core.ui").update(buf, win, "nvimcat", true)
  end)
  pcall(function()
    require("render-markdown").set(true)
  end)
  if need_mermaid then
    pcall(function()
      local mod = ensure_mermaid_setup()
      require("render-markdown-mermaid.display").render(buf, mod.config)
    end)
  end
  pcall(vim.api.nvim_exec_autocmds, "BufWinEnter", { buffer = buf })
end

local function has_table_decor(buf)
  for name, id in pairs(vim.api.nvim_get_namespaces()) do
    local from_rm = name:find("render%-markdown", 1, false) ~= nil
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, id, 0, -1, { details = true })) do
      local d = m[4] or {}
      if d.virt_text and from_rm then
        for _, chunk in ipairs(d.virt_text) do
          local t = chunk[1] or ""
          if t:find("┌") or t:find("│") or t:find("├") or t:find("╰") then
            return true
          end
        end
      end
      if d.virt_lines then
        for _, line in ipairs(d.virt_lines) do
          for _, chunk in ipairs(line) do
            local t = chunk[1] or ""
            if t:find("┌") or t:find("│") then
              return true
            end
          end
        end
      end
    end
  end
  return false
end

--- Mermaid overlays are multi-line virt_lines (bm/ascii), not the source fence.
local function has_mermaid_decor(buf)
  for name, id in pairs(vim.api.nvim_get_namespaces()) do
    local interesting = name:find("mermaid", 1, true) or name:find("render%-markdown", 1, false)
    if not interesting then
      goto continue
    end
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, id, 0, -1, { details = true })) do
      local d = m[4] or {}
      if d.virt_lines and #d.virt_lines >= 3 then
        local text = {}
        for _, line in ipairs(d.virt_lines) do
          for _, chunk in ipairs(line) do
            text[#text + 1] = chunk[1] or ""
          end
        end
        local joined = table.concat(text)
        -- Prefer diagram chrome; fall back to node labels from replaced source.
        if joined:find("┌") or joined:find("─") or joined:find("►") or joined:find("Start") then
          return true
        end
      end
    end
    ::continue::
  end
  return false
end

local function has_rm_marks(buf)
  for name, id in pairs(vim.api.nvim_get_namespaces()) do
    if name:find("render%-markdown", 1, false) then
      if #vim.api.nvim_buf_get_extmarks(buf, id, 0, -1, {}) > 0 then
        return true
      end
    end
  end
  return false
end

local function is_ready(buf, need_mermaid)
  -- Mermaid is async (bm); when the fence exists, wait for its virt_lines.
  if need_mermaid then
    return has_mermaid_decor(buf)
  end
  -- Prefer cheap mark presence; table box scan is O(all extmarks).
  return has_rm_marks(buf) or has_table_decor(buf)
end

local function render_generation(buf)
  local ok, decorator = pcall(function()
    return require("render-markdown.core.ui").get(buf)
  end)
  return ok and decorator and decorator.n or nil
end

local function settle(buf, win, opts, need_mermaid)
  -- Force once, then only poll. Re-forcing every tick (debounce=0) schedules
  -- unbounded ui.update callbacks and can prevent decorations from stabilizing.
  local before = render_generation(buf)
  if not is_ready(buf, need_mermaid) then
    try_force_render(buf, win, need_mermaid)
  end
  local ok = vim.wait(opts.timeout_ms, function()
    local generation = render_generation(buf)
    return is_ready(buf, need_mermaid)
      and (before == nil or (generation ~= nil and generation > before))
  end, 20)
  if not ok then
    -- One last nudge, then brief wait — still no per-tick thrash.
    before = render_generation(buf)
    try_force_render(buf, win, need_mermaid)
    vim.wait(math.min(500, opts.timeout_ms), function()
      local generation = render_generation(buf)
      return is_ready(buf, need_mermaid)
        and (before == nil or (generation ~= nil and generation > before))
    end, 20)
  end
  if not is_ready(buf, need_mermaid) then
    io.stderr:write(
      "nvimcat: settle timeout (ready="
        .. tostring(is_ready(buf, need_mermaid))
        .. " mermaid="
        .. tostring(need_mermaid)
        .. ")\n"
    )
  end
  return is_ready(buf, need_mermaid)
end

local function disable_anti_conceal()
  pcall(function()
    local state = require("render-markdown.state")
    ---@param cfg table?
    local function disable(cfg)
      if not cfg then
        return
      end
      if cfg.anti_conceal then
        -- Want non-cursor rendering: hide anti-conceal for the whole dump.
        cfg.anti_conceal.enabled = false
      end
      -- Force updates must not be dropped while decorator.running is true.
      cfg.debounce = 0
    end
    disable(state.config)
    for _, cfg in pairs(state.cache or {}) do
      disable(cfg)
    end
  end)
end

--- Silence LSP paint without quitting clients (quit → snacks warning float).
local function mute_lsp_paint(buf)
  for _, client in ipairs(vim.lsp.get_clients()) do
    pcall(function()
      client.server_capabilities.semanticTokensProvider = nil
    end)
    pcall(function()
      vim.lsp.semantic_tokens.stop(buf, client.id)
    end)
    pcall(vim.lsp.stop_client, client.id, false)
  end
  for name, id in pairs(vim.api.nvim_get_namespaces()) do
    if name:find("semantic_tokens", 1, true) then
      pcall(vim.api.nvim_buf_clear_namespace, buf, id, 0, -1)
    end
  end
end

local function close_floating_windows()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local ok, cfg = pcall(vim.api.nvim_win_get_config, win)
    if ok and cfg.relative ~= nil and cfg.relative ~= "" then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
end

local function disable_side_effect_plugins(opts)
  vim.g.copilot_enabled = false
  vim.notify = function() end

  local names = (opts and opts.disable_plugins) or config.disable_plugins
  pcall(function()
    local Config = require("lazy.core.config")
    local Loader = require("lazy.core.loader")
    local Handler = require("lazy.core.handler")
    for _, name in ipairs(names) do
      local plugin = Config.plugins[name]
      if plugin then
        plugin.enabled = false
        if plugin._ then
          plugin._.cond = false
        end
        pcall(Handler.disable, plugin)
        if plugin._ and plugin._.loaded then
          pcall(Loader.deactivate, plugin)
        end
      end
    end
  end)

  pcall(vim.cmd, "silent! Copilot disable")
  pcall(function()
    require("copilot.command").disable()
  end)
  -- nvim-lint (cspell) on a multi-thousand-line markdown file is catastrophic.
  pcall(function()
    require("lint").linters_by_ft = {}
  end)
  pcall(vim.diagnostic.enable, false)
end

local function silence_ui_noise()
  pcall(vim.diagnostic.enable, false)
  pcall(vim.diagnostic.hide)
  -- lualine refreshes and can restore laststatus between stitch pages.
  vim.o.laststatus = 0
  vim.o.showtabline = 0
  vim.o.cmdheight = 0
  pcall(function()
    require("lualine").hide({
      place = { "statusline", "tabline", "winbar" },
      unhide = false,
    })
  end)
  -- Indent guides / scope lines (│) and cursor-word glow are not part of
  -- the markdown render the user wants to dump.
  pcall(function()
    require("snacks").indent.disable()
  end)
  pcall(function()
    require("ibl").update({ enabled = false })
  end)
  pcall(function()
    vim.g.indent_blankline_enabled = false
  end)
  pcall(function()
    vim.b.miniindentscope_disable = true
  end)
  pcall(function()
    require("illuminate").pause()
  end)
  pcall(vim.cmd, "silent! IlluminatePauseBuf")
  pcall(vim.cmd, "NoMatchParen")
  pcall(vim.cmd, "silent! TSContextDisable")
  pcall(vim.cmd, "nohlsearch")
  vim.v.hlsearch = false
  pcall(vim.fn.clearmatches)
  pcall(function()
    vim.fn.setreg("/", "")
  end)
  -- Headless can still paint CurSearch/IncSearch onto spans; neutralize for dump.
  pcall(vim.api.nvim_set_hl, 0, "CurSearch", { link = "Normal" })
  pcall(vim.api.nvim_set_hl, 0, "IncSearch", { link = "Normal" })
  pcall(vim.api.nvim_set_hl, 0, "Search", { link = "Normal" })
  pcall(function()
    local state = require("render-markdown.state")
    if state.config and state.config.indent then
      state.config.indent.enabled = false
    end
    for _, cfg in pairs(state.cache or {}) do
      if cfg.indent then
        cfg.indent.enabled = false
      end
    end
  end)
  -- disable() alone can leave existing decoration marks; clear them.
  local buf = vim.api.nvim_get_current_buf()
  for name, id in pairs(vim.api.nvim_get_namespaces()) do
    local n = tostring(name):lower()
    if n:find("indent", 1, true) or n:find("illumin", 1, true) or n:find("cursorword", 1, true) then
      pcall(vim.api.nvim_buf_clear_namespace, buf, id, 0, -1)
    end
  end
end

local function prepare_chrome(opts)
  local width = opts.width
    or tonumber(vim.env.NVIMCAT_WIDTH)
    or tonumber(vim.env.COLUMNS)
    or vim.o.columns
  if not width or width < 1 then
    width = 80 -- last resort when no TTY / env
  end
  opts.width = width
  vim.o.termguicolors = true
  vim.o.cmdheight = 0
  vim.o.laststatus = 0
  vim.o.showtabline = 0
  vim.o.ruler = false
  vim.o.showcmd = false
  vim.o.showmode = false
  vim.o.number = false
  vim.o.relativenumber = false
  vim.o.signcolumn = "no"
  vim.o.foldcolumn = "0"
  vim.o.columns = width
  vim.opt.fillchars:append({ eob = "~" })
  disable_side_effect_plugins(opts)
  silence_ui_noise()
end

--- Dump current buffer (or open `file`) to ANSI string.
---@param opts? nvimcat.Opts|{file?: string}
---@return string
function M.dump(opts)
  _timing("dump_enter")
  opts = merge(opts)
  prepare_chrome(opts)
  disable_side_effect_plugins(opts)

  if opts.file and opts.file ~= "" then
    vim.cmd("edit " .. vim.fn.fnameescape(opts.file))
  end
  _timing("after_edit")

  local buf = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()
  -- LazyVim BufReadPost last_loc is deferred via lazy file events and can jump
  -- to the '"' mark after we reset topline=1 — that starts scroll-stitch at EOF.
  vim.b[buf].lazyvim_last_loc = true
  pcall(function()
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = "no"
    vim.wo[win].foldcolumn = "0"
    vim.wo[win].statuscolumn = ""
    vim.wo[win].list = false
    vim.wo[win].cursorline = false
    vim.wo[win].wrap = false
  end)
  vim.o.signcolumn = "no"
  vim.o.number = false
  pcall(vim.diagnostic.enable, false)

  local need_mermaid = buffer_needs_mermaid(buf)

  disable_anti_conceal()
  vim.cmd("normal! gg")
  try_force_render(buf, win, need_mermaid)
  _timing(
    "before_settle ready="
      .. tostring(is_ready(buf, need_mermaid))
      .. " mermaid="
      .. tostring(need_mermaid)
  )
  settle(buf, win, opts, need_mermaid)
  _timing("after_settle ready=" .. tostring(is_ready(buf, need_mermaid)))

  -- Keep topline=1. Parking on the last line would scroll the viewport
  -- when the buffer is taller than the window (README-sized docs).
  silence_ui_noise()
  disable_anti_conceal()
  mute_lsp_paint(buf)
  close_floating_windows()
  pcall(function()
    vim.fn.winrestview({ lnum = 1, col = 0, topline = 1, leftcol = 0 })
  end)
  -- winrestview changes the visible range after settle; refresh decorations
  -- for the restored first page before the capture client snapshots the grid.
  local before_view_render = render_generation(buf)
  try_force_render(buf, win, need_mermaid)
  vim.wait(math.min(500, opts.timeout_ms), function()
    local generation = render_generation(buf)
    return before_view_render == nil
      or (generation ~= nil and generation > before_view_render)
  end, 20)
  -- Re-assert chrome: LazyVim/lualine may flip laststatus back on.
  vim.o.laststatus = 0
  vim.o.showtabline = 0
  vim.o.cmdheight = 0
  pcall(function()
    vim.o.winbar = ""
    vim.wo[win].winbar = ""
  end)
  if vim.env.NVIMCAT_VERBOSE == "1" then
    io.stderr:write(
      string.format(
        "nvimcat: capturing lines=%d cols=%d ready=%s\n",
        vim.o.lines,
        vim.o.columns,
        tostring(is_ready(buf, need_mermaid))
      )
    )
  end

  local function estimate_height(b)
    local n = vim.api.nvim_buf_line_count(b)
    local extra = 0
    for _, id in pairs(vim.api.nvim_get_namespaces()) do
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(b, id, 0, -1, { details = true })) do
        local d = m[4] or {}
        if d.virt_lines then
          extra = extra + #d.virt_lines
        end
      end
    end
    if buffer_needs_mermaid(b) and extra < 8 then
      extra = extra + 12
    end
    local cap = opts.max_lines or 5000
    -- Neovim UI height hard-caps at 1000; higher nvimcat_rows only slows resize.
    return math.max(24, math.min(UI_MAX_LINES, math.min(cap, n + extra + math.floor(n * 0.15) + 8)))
  end
  vim.g.nvimcat_rows = estimate_height(buf)
  vim.g.nvimcat_buf_lines = vim.api.nvim_buf_line_count(buf)

  local function pin_capture_view()
    -- Re-pin immediately before capture: deferred last_loc / plugins may have
    -- moved the cursor after settle; Neovim scrolls to keep cursor visible.
    vim.b[buf].lazyvim_last_loc = true
    pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })
    pcall(function()
      vim.fn.winrestview({ lnum = 1, col = 0, topline = 1, leftcol = 0 })
    end)
    local before = render_generation(buf)
    try_force_render(buf, win, need_mermaid)
    vim.wait(math.min(500, opts.timeout_ms), function()
      local generation = render_generation(buf)
      return before == nil or (generation ~= nil and generation > before)
    end, 20)
  end

  if opts.compose or vim.env.NVIMCAT_COMPOSE == "1" then
    pin_capture_view()
    vim.g.nvimcat_compose = 1
    vim.g.nvimcat_capture = 1
    if vim.env.NVIMCAT_VERBOSE == "1" then
      io.stderr:write("nvimcat: compose=1\n")
    end
    return ""
  end

  if vim.env.NVIMCAT_EMBED == "1" then
    -- Embed client owns ANSI; next UI flush is the frame to emit.
    pin_capture_view()
    vim.g.nvimcat_capture = 1
    vim.cmd("redraw!")
    return ""
  end

  -- Interactive TUI (:NvimCat): capture composed grid via screenshot.
  vim.o.lines = math.min(opts.max_lines or 5000, math.max(vim.o.lines, vim.g.nvimcat_rows))
  pcall(vim.api.nvim_win_set_height, win, math.max(1, vim.o.lines - 2))
  vim.cmd("redraw!")
  local path = vim.fn.tempname() .. ".nvimcat.shot"
  vim.api.nvim__screenshot(path)
  local root = plugin_root() or "."
  local ansi = vim.fn.system({ "python3", root .. "/bin/nvimcat", "--shot2ansi", path })
  pcall(os.remove, path)
  if vim.v.shell_error ~= 0 then
    error("nvimcat: shot2ansi failed: " .. tostring(ansi))
  end
  return ansi
end

--- Dump into a new scratch buffer (interactive `:NvimCat`).
---@param opts? nvimcat.Opts|{file?: string}
function M.dump_to_buffer(opts)
  local ansi = M.dump(opts)
  local plain = ansi:gsub("\27%[[0-9;]*m", "")
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(plain, "\n", { plain = true }))
  vim.api.nvim_set_current_buf(buf)
  return buf
end

local function files_from_env_or_argv()
  local files = {}
  local env = vim.env.NVIMCAT_FILES
  if env and env ~= "" then
    for part in env:gmatch("([^\30]+)") do
      if part ~= "" then
        files[#files + 1] = part
      end
    end
  end
  if #files == 0 then
    for i = 0, vim.fn.argc() - 1 do
      files[#files + 1] = vim.fn.argv(i)
    end
  end
  return files
end

local function lazy_init_done()
  local ok, Loader = pcall(require, "lazy.core.loader")
  return ok and Loader.init_done == true
end

--- Run cb once Lazy/Vim is ready (no fixed 2s sleep).
local function when_ready(cb)
  local done = false
  local compose = vim.env.NVIMCAT_COMPOSE == "1"
  local function once()
    if done then
      return
    end
    done = true
    -- Dump as soon as Lazy init is done; no extra pad.
    vim.schedule(cb)
  end

  vim.api.nvim_create_autocmd("User", {
    pattern = { "VeryLazy", "LazyVimStarted" },
    once = true,
    callback = once,
  })

  local function poll_from_vimenter()
    local t0 = vim.uv.now()
    local function poll()
      if done then
        return
      end
      if lazy_init_done() or (vim.uv.now() - t0) >= 400 then
        once()
        return
      end
      vim.defer_fn(poll, 20)
    end
    poll()
    -- Hard cap so we never hang if Lazy signals never fire in headless.
    vim.defer_fn(once, 700)
  end

  if compose or vim.v.vim_did_enter == 1 then
    poll_from_vimenter()
  else
    vim.api.nvim_create_autocmd("VimEnter", {
      once = true,
      callback = poll_from_vimenter,
    })
  end
end

--- CLI entry: dump files to stdout and quit.
function M.cli()
  local root = vim.env.NVIMCAT_ROOT or vim.g.nvimcat_root
  if root and root ~= "" then
    vim.opt.rtp:prepend(root)
  end

  disable_side_effect_plugins(config)
  -- Mute LSP paint before it reaches the capture; stopping clients emits a
  -- quit warning that the embedded UI client would capture as document data.
  vim.api.nvim_create_autocmd("LspAttach", {
    group = vim.api.nvim_create_augroup("nvimcat_mute_lsp", { clear = true }),
    callback = function(args)
      local client = vim.lsp.get_client_by_id(args.data.client_id)
      if client then
        client.server_capabilities.semanticTokensProvider = nil
      end
      pcall(vim.lsp.semantic_tokens.stop, args.buf, args.data.client_id)
    end,
  })

  local opts = merge({})

  local files = files_from_env_or_argv()
  if #files == 0 then
    io.stderr:write("nvimcat: usage: nvimcat <file>...\n")
    vim.cmd("cquit 2")
    return
  end

  when_ready(function()
    disable_side_effect_plugins(opts)
    if vim.env.NVIMCAT_VERBOSE == "1" then
      io.stderr:write("nvimcat: dumping…\n")
    end
    local ok, err = pcall(function()
      if vim.env.NVIMCAT_SHOT and vim.env.NVIMCAT_SHOT ~= "" then
        error("nvimcat: NVIMCAT_SHOT/PTY path removed; use default embed CLI (bin/nvimcat)")
      end
      local embed = vim.env.NVIMCAT_EMBED == "1"
      for i, file in ipairs(files) do
        if not embed and i > 1 then
          io.stdout:write("\n")
        end
        local dumped = M.dump(vim.tbl_extend("force", opts, { file = file }))
        if embed then
          local cap_ms = math.floor((tonumber(vim.env.NVIMCAT_TIMEOUT) or 60) * 1000)
          local t0 = vim.uv.now()
          while vim.g.nvimcat_capture == 1 and (vim.uv.now() - t0) < cap_ms do
            vim.wait(20, function()
              return vim.g.nvimcat_capture ~= 1
            end, 50)
          end
        else
          io.stdout:write(dumped)
        end
      end
    end)
    if not ok then
      io.stderr:write("nvimcat: " .. tostring(err) .. "\n")
      vim.cmd("cquit 1")
      return
    end
    if vim.env.NVIMCAT_EMBED == "1" then
      vim.g.nvimcat_done = 1
      vim.cmd("redraw!")
    else
      vim.cmd("qa!")
    end
  end)
end

--- Shared prep for agent-terminal compare harness (same silence as dump).
function M.prep_compare()
  disable_side_effect_plugins(config)
  prepare_chrome(merge({}))
  local buf = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()
  pcall(function()
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = "no"
    vim.wo[win].foldcolumn = "0"
    vim.wo[win].statuscolumn = ""
    vim.wo[win].list = false
    vim.wo[win].cursorline = false
    vim.wo[win].wrap = false
  end)
  -- Stop LSP paint from overriding @markup.link on [S12]-style cites.
  mute_lsp_paint(buf)
  close_floating_windows()
  silence_ui_noise()
  disable_anti_conceal()
  pcall(function()
    vim.fn.winrestview({ lnum = 1, col = 0, topline = 1, leftcol = 0 })
  end)
  try_force_render(buf, win, buffer_needs_mermaid(buf))
  vim.cmd("redraw!")
  mute_lsp_paint(buf)
  close_floating_windows()
  vim.o.laststatus = 0
  vim.o.showtabline = 0
  vim.o.cmdheight = 0
  pcall(function()
    vim.o.winbar = ""
    vim.wo[win].winbar = ""
  end)
  vim.cmd("redraw!")
end

return M
