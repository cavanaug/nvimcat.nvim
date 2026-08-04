--- nvim-ansi-pager: dump a buffer as ANSI using the user's full Neovim config.
local M = {}

---@class nap.Opts
---@field width? integer
---@field min_wait_ms? integer
---@field settle_ms? integer
---@field timeout_ms? integer
---@field max_lines? integer
---@field disable_plugins? string[]

local DEFAULTS = {
  width = tonumber(vim.env.COLUMNS) or 80,
  min_wait_ms = 80,
  settle_ms = 120,
  timeout_ms = 8000,
  max_lines = 5000,
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

local config = vim.deepcopy(DEFAULTS)

local function merge(opts)
  return vim.tbl_deep_extend("force", config, opts or {})
end

--- Plugin setup (Lazy `opts` / `require(...).setup`).
---@param opts? nap.Opts
function M.setup(opts)
  config = vim.tbl_deep_extend("force", DEFAULTS, opts or {})
end

local function decor_fingerprint(buf)
  local parts = {}
  for name, id in pairs(vim.api.nvim_get_namespaces()) do
    local marks = vim.api.nvim_buf_get_extmarks(buf, id, 0, -1, { details = true })
    parts[#parts + 1] = name .. "=" .. #marks
    for _, m in ipairs(marks) do
      local d = m[4] or {}
      if d.virt_lines then
        for _, line in ipairs(d.virt_lines) do
          for _, chunk in ipairs(line) do
            parts[#parts + 1] = chunk[1] or ""
          end
        end
      end
      if d.virt_text then
        for _, chunk in ipairs(d.virt_text) do
          parts[#parts + 1] = chunk[1] or ""
        end
      end
    end
  end
  return table.concat(parts, "\0")
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
    require("lazy").load({
      plugins = {
        "render-markdown.nvim",
        "render-markdown-mermaid.nvim",
      },
    })
  end)
  pcall(vim.cmd, "doautocmd FileType " .. (vim.bo.filetype ~= "" and vim.bo.filetype or "markdown"))
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

local function try_force_render(buf, win)
  if not plugins_loaded then
    ensure_lazy_markdown_plugins()
    plugins_loaded = true
  end
  pcall(function()
    require("render-markdown.core.ui").update(buf, win, "nvim-ansi-pager", true)
  end)
  pcall(function()
    require("render-markdown").set(true)
  end)
  -- Treesitter + direct mermaid render (bypass debounce timer).
  pcall(function()
    vim.treesitter.get_parser(buf, "markdown"):parse()
  end)
  pcall(function()
    local mod = ensure_mermaid_setup()
    require("render-markdown-mermaid.display").render(buf, mod.config)
  end)
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
  return has_table_decor(buf) or has_rm_marks(buf)
end

local function settle(buf, win, opts, need_mermaid)
  local t0 = vim.uv.now()
  local last = nil
  local stable_since = nil

  while vim.uv.now() - t0 < opts.timeout_ms do
    try_force_render(buf, win)
    -- Must pump luv/vim.system callbacks (bare vim.wait(ms) is not enough).
    vim.wait(50, function()
      return is_ready(buf, need_mermaid)
    end, 20)
    local fp = decor_fingerprint(buf)
    local now = vim.uv.now()
    if is_ready(buf, need_mermaid) then
      if fp == last then
        stable_since = stable_since or now
        if now - t0 >= opts.min_wait_ms and now - stable_since >= opts.settle_ms then
          return true
        end
      else
        last = fp
        stable_since = nil
      end
    else
      last = fp
      stable_since = nil
    end
  end
  io.stderr:write(
    "nvimcat: settle timeout (ready="
      .. tostring(is_ready(buf, need_mermaid))
      .. " mermaid="
      .. tostring(need_mermaid)
      .. ")\n"
  )
  return is_ready(buf, need_mermaid)
end

local function hex_from_attr(attr, what)
  local v = vim.fn.synIDattr(attr, what == "fg" and "fg#" or "bg#")
  if v == "" or v == -1 or v == "-1" then
    return nil
  end
  if type(v) == "number" then
    return string.format("#%06x", v)
  end
  return v
end

local function ansi_color(hex, kind)
  if not hex or not hex:match("^#%x%x%x%x%x%x$") then
    return ""
  end
  local r = tonumber(hex:sub(2, 3), 16)
  local g = tonumber(hex:sub(4, 5), 16)
  local b = tonumber(hex:sub(6, 7), 16)
  if kind == "fg" then
    return string.format("\27[38;2;%d;%d;%dm", r, g, b)
  end
  return string.format("\27[48;2;%d;%d;%dm", r, g, b)
end

local function capture_window()
  vim.cmd("redraw!")
  local rows = vim.o.lines
  local cols = vim.o.columns
  local out = {}

  for row = 1, rows do
    local plain = {}
    local ansi = {}
    local last = ""
    for col = 1, cols do
      local ch = vim.fn.screenstring(row, col)
      if ch == "" then
        ch = " "
      end
      plain[#plain + 1] = ch
      local attr = vim.fn.screenattr(row, col)
      local fg = hex_from_attr(attr, "fg")
      local bg = hex_from_attr(attr, "bg")
      local bold = vim.fn.synIDattr(attr, "bold") == "1"
      local key = tostring(fg) .. "|" .. tostring(bg) .. "|" .. tostring(bold)
      if key ~= last then
        ansi[#ansi + 1] = "\27[0m"
        if bold then
          ansi[#ansi + 1] = "\27[1m"
        end
        ansi[#ansi + 1] = ansi_color(fg, "fg")
        ansi[#ansi + 1] = ansi_color(bg, "bg")
        last = key
      end
      ansi[#ansi + 1] = ch
    end
    ansi[#ansi + 1] = "\27[0m"
    local p = table.concat(plain):gsub("%s+$", "")
    if p:match("^~+$") then
      break
    end
    out[#out + 1] = table.concat(ansi):gsub("%s+\27%[0m$", "\27[0m")
  end

  local function plain_of(line)
    return line:gsub("\27%[[0-9;]*m", ""):gsub("%s+$", "")
  end

  while #out > 0 and plain_of(out[#out]) == "" do
    table.remove(out)
  end

  local min_pad = nil
  for _, line in ipairs(out) do
    local plain = line:gsub("\27%[[0-9;]*m", "")
    if plain:match("%S") then
      local pad = #(plain:match("^(%s*)") or "")
      if not min_pad or pad < min_pad then
        min_pad = pad
      end
    end
  end
  if min_pad and min_pad > 0 then
    for i, line in ipairs(out) do
      local stripped = {}
      local seen = 0
      local j = 1
      while j <= #line do
        local esc = line:match("^\27%[[0-9;]*m", j)
        if esc then
          stripped[#stripped + 1] = esc
          j = j + #esc
        else
          local ch = line:sub(j, j)
          if seen < min_pad and ch == " " then
            seen = seen + 1
          else
            stripped[#stripped + 1] = line:sub(j)
            break
          end
          j = j + 1
        end
      end
      out[i] = table.concat(stripped)
    end
  end

  return out
end

local function estimate_height(buf)
  local n = vim.api.nvim_buf_line_count(buf)
  local extra = 0
  for _, id in pairs(vim.api.nvim_get_namespaces()) do
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, id, 0, -1, { details = true })) do
      local d = m[4] or {}
      if d.virt_lines then
        extra = extra + #d.virt_lines
      end
    end
  end
  -- Mermaid often expands after first render; reserve room up front.
  if buffer_needs_mermaid(buf) and extra < 8 then
    extra = extra + 12
  end
  return n + extra + math.floor(n * 0.15) + 8
end

local function disable_anti_conceal()
  pcall(function()
    local state = require("render-markdown.state")
    if state.config and state.config.anti_conceal then
      state.config.anti_conceal.enabled = false
    end
    for _, cfg in pairs(state.cache or {}) do
      if cfg.anti_conceal then
        cfg.anti_conceal.enabled = false
      end
    end
  end)
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
  for _, client in ipairs(vim.lsp.get_clients({ name = "copilot" })) do
    pcall(function()
      client:stop(true)
    end)
  end
end

local function prepare_chrome(opts)
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
  vim.o.columns = opts.width
  vim.opt.fillchars:append({ eob = "~" })
  pcall(vim.diagnostic.enable, false)
  disable_side_effect_plugins(opts)
end

--- Dump current buffer (or open `file`) to ANSI string.
---@param opts? nap.Opts|{file?: string}
---@return string
function M.dump(opts)
  opts = merge(opts)
  prepare_chrome(opts)
  disable_side_effect_plugins(opts)

  if opts.file and opts.file ~= "" then
    vim.cmd("edit " .. vim.fn.fnameescape(opts.file))
  end

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
  vim.o.signcolumn = "no"
  vim.o.number = false
  pcall(vim.diagnostic.enable, false)

  local need_mermaid = buffer_needs_mermaid(buf)

  -- Size once (with mermaid slack), then a single settle.
  local est_h = math.min(opts.max_lines, math.max(24, estimate_height(buf)))
  vim.o.lines = est_h
  pcall(vim.api.nvim_win_set_height, win, math.max(1, est_h - 2))

  disable_anti_conceal()
  vim.cmd("normal! gg")
  try_force_render(buf, win)
  settle(buf, win, opts, need_mermaid)

  -- Re-estimate after virt_lines exist; resize + one short settle if grown.
  local est2 = math.min(opts.max_lines, math.max(est_h, estimate_height(buf)))
  if est2 > est_h then
    vim.o.lines = est2
    pcall(vim.api.nvim_win_set_height, win, math.max(1, est2 - 2))
    disable_anti_conceal()
    try_force_render(buf, win)
    settle(buf, win, {
      min_wait_ms = 40,
      settle_ms = 80,
      timeout_ms = math.min(2000, opts.timeout_ms),
    }, need_mermaid)
    est_h = est2
  else
    disable_anti_conceal()
    try_force_render(buf, win)
    vim.wait(40, function()
      return false
    end)
  end

  vim.cmd("redraw!")
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

  local lines = capture_window()

  if est_h >= opts.max_lines then
    local seen = {}
    local stitched = {}
    local function add_page(page)
      for _, line in ipairs(page) do
        local key = line:gsub("\27%[[0-9;]*m", "")
        if key:match("%S") and seen[key] then
          goto continue
        end
        if key:match("%S") then
          seen[key] = true
        end
        stitched[#stitched + 1] = line
        ::continue::
      end
    end
    add_page(lines)
    local guard = 0
    while guard < 200 do
      guard = guard + 1
      local view = vim.fn.winsaveview()
      vim.cmd("normal! \x04")
      local view2 = vim.fn.winsaveview()
      if view2.topline == view.topline then
        break
      end
      add_page(capture_window())
    end
    lines = stitched
  end

  return table.concat(lines, "\n") .. "\n"
end

--- Dump into a new scratch buffer (interactive `:NvimCat`).
---@param opts? nap.Opts|{file?: string}
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
  local function once()
    if done then
      return
    end
    done = true
    vim.defer_fn(cb, 20)
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
      if lazy_init_done() or (vim.uv.now() - t0) >= 600 then
        once()
        return
      end
      vim.defer_fn(poll, 40)
    end
    poll()
    -- Hard cap so we never hang if Lazy signals never fire in headless.
    vim.defer_fn(once, 900)
  end

  if vim.v.vim_did_enter == 1 then
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
  local root = vim.env.NVIM_ANSI_PAGER_ROOT or vim.g.nvim_ansi_pager_root
  if root and root ~= "" then
    vim.opt.rtp:prepend(root)
  end

  disable_side_effect_plugins(config)

  local opts = merge({
    width = tonumber(vim.env.NVIMCAT_WIDTH) or tonumber(vim.env.COLUMNS) or 80,
  })

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
      for i, file in ipairs(files) do
        if i > 1 then
          io.stdout:write("\n")
        end
        io.stdout:write(M.dump(vim.tbl_extend("force", opts, { file = file })))
      end
    end)
    if not ok then
      io.stderr:write("nvimcat: " .. tostring(err) .. "\n")
      vim.cmd("cquit 1")
      return
    end
    vim.cmd("qa!")
  end)
end

return M
