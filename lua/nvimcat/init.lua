--- nvimcat: dump a buffer as ANSI using the user's full Neovim config.
local M = {}

---@class nvimcat.Opts
---@field width? integer
---@field min_wait_ms? integer
---@field settle_ms? integer
---@field timeout_ms? integer
---@field max_lines? integer
---@field install_cli? boolean
---@field disable_plugins? string[]

local DEFAULTS = {
  -- width: nil → NVIMCAT_WIDTH / COLUMNS / vim.o.columns (see prepare_chrome)
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

local config = vim.deepcopy(DEFAULTS)

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
    require("render-markdown.core.ui").update(buf, win, "nvimcat", true)
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

---@param name string|string[]|nil
---@param into table
local function merge_hl(name, into)
  if not name then
    return
  end
  if type(name) == "table" then
    for _, n in ipairs(name) do
      merge_hl(n, into)
    end
    return
  end
  local h = vim.api.nvim_get_hl(0, { name = name, link = false })
  if h.fg then
    into.fg = string.format("#%06x", h.fg)
  end
  if h.bg then
    into.bg = string.format("#%06x", h.bg)
  end
  if h.bold then
    into.bold = true
  end
  if h.italic then
    into.italic = true
  end
  if h.underline then
    into.underline = true
  end
end

--- Build per-cell styles from extmarks + treesitter.
--- Headless screenattr misses extmark composition; screenpos() is wrong for
--- concealed/virt_lines rows (e.g. mermaid), so all mapping is screen-text find.
---@param win integer
---@param rows integer
---@param cols integer
---@return table<integer, table<integer, table>>
local function build_style_grid(win, rows, cols)
  local grid = {}
  local function cell(r, c)
    grid[r] = grid[r] or {}
    grid[r][c] = grid[r][c] or {}
    return grid[r][c]
  end

  local buf = vim.api.nvim_win_get_buf(win)
  local normal = {}
  merge_hl("Normal", normal)

  -- Per screen row: assembled text (non-empty cells) + byte→col map.
  local assembled = {}
  local byte_to_col = {}
  for r = 1, rows do
    local s = ""
    local map = {}
    for c = 1, cols do
      local ch = vim.fn.screenstring(r, c)
      if ch ~= "" then
        local b0 = #s
        s = s .. ch
        for b = b0 + 1, #s do
          map[b] = c
        end
      end
    end
    assembled[r] = s
    byte_to_col[r] = map
  end

  ---@param text string
  ---@param apply fun(dest: table)
  ---@param opts? { all_cols?: boolean, allow_virt?: boolean, row?: integer, all_matches?: boolean }
  local function paint_text(text, apply, opts)
    opts = opts or {}
    if not text or text == "" or text:find("\n", 1, true) then
      return
    end
    local row_from, row_to = 1, rows
    if opts.row then
      row_from, row_to = opts.row, opts.row
    end
    local found_row
    for r = row_from, row_to do
      local search_from = 1
      while true do
        local start = assembled[r]:find(text, search_from, true)
        if not start then
          break
        end
        local map = byte_to_col[r]
        local c0 = map[start]
        local c1 = map[start + #text - 1]
        if c0 and c1 then
          if opts.all_cols then
            c0, c1 = 1, cols
          end
          for c = c0, c1 do
            local dest = cell(r, c)
            if opts.allow_virt or not dest._virt then
              apply(dest)
            end
          end
          found_row = r
          if not opts.all_matches then
            return r
          end
        end
        search_from = start + 1
      end
    end
    return found_row
  end

  local function row_for_buffer_line(br)
    local bline = vim.api.nvim_buf_get_lines(buf, br, br + 1, false)[1] or ""
    local hint = bline:gsub("^#+%s*", ""):gsub("^>%s*", ""):match("[%w][%w%-%_ ][%w%-%_ ]+")
    if hint then
      hint = hint:gsub("%s+$", "")
      for r = 1, rows do
        if assembled[r]:find(hint, 1, true) then
          return r
        end
      end
    end
  end

  local marks = {}
  for _, id in pairs(vim.api.nvim_get_namespaces()) do
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, id, 0, -1, { details = true })) do
      marks[#marks + 1] = m
    end
  end

  -- Full-line backgrounds from render-markdown (headings + fenced code).
  -- Locate by buffer text on screen — screenpos() is wrong near virt_lines.
  for _, m in ipairs(marks) do
    local d = m[4] or {}
    local hl = d.hl_group or d.line_hl_group
    if hl and d.hl_eol and type(hl) == "string" then
      local style = {}
      merge_hl(hl, style)
      local blines = vim.api.nvim_buf_get_lines(buf, m[2], m[2] + 1, false)
      local text = blines[1] or ""
      if hl:find("RenderMarkdownH%d+Bg") then
        text = text:gsub("^#+%s*", "")
      end
      if text:find("%S") then
        paint_text(text, function(dest)
          for k, v in pairs(style) do
            dest[k] = v
          end
        end, { all_cols = true, allow_virt = true })
      end
    end
  end

  -- Treesitter: markdown markup + injected languages (e.g. rust in ```rust).
  pcall(function()
    local parser = vim.treesitter.get_parser(buf)
    if not parser then
      return
    end
    parser:parse()
    parser:for_each_tree(function(tree, ltree)
      local lang = ltree:lang()
      local q = vim.treesitter.query.get(lang, "highlights")
      if not q then
        return
      end
      local is_md = lang == "markdown" or lang == "markdown_inline"
      for id, node in q:iter_captures(tree:root(), buf, 0, -1) do
        local name = q.captures[id] or ""
        if name:sub(1, 1) == "_" then
          goto continue
        end
        local raw = vim.treesitter.get_node_text(node, buf)
        if not is_md then
          -- Injected code: paint @capture colors onto visible text.
          if raw and #raw > 0 and #raw < 160 and not raw:find("\n", 1, true) then
            local style = {}
            merge_hl("@" .. name .. "." .. lang, style)
            if not style.fg and not style.bold and not style.italic then
              merge_hl("@" .. name, style)
            end
            if style.fg or style.bold or style.italic or style.underline then
              paint_text(raw, function(dest)
                if style.fg then
                  dest.fg = style.fg
                end
                if style.bold then
                  dest.bold = true
                end
                if style.italic then
                  dest.italic = true
                end
                if style.underline then
                  dest.underline = true
                end
              end)
            end
          end
          goto continue
        end
        if name:match("heading%.%d") then
          local text = raw:gsub("^#+%s*", ""):gsub("\n.*", "")
          local level = name:match("heading%.(%d)")
          local fg_style = {}
          if level then
            merge_hl("RenderMarkdownH" .. level, fg_style)
          end
          paint_text(text, function(dest)
            dest.bold = true
            if fg_style.fg and not dest.fg then
              dest.fg = fg_style.fg
            end
          end)
        elseif name == "markup.heading" or name:match("heading$") then
          -- Pipe-table header cells share capture name with ATX; not heading.N.
          -- Keep trailing space from capture ("Tool ") — matches TUI cell padding.
          local text = raw:gsub("\n.*", "")
          if not text:find("%S") then
            text = nil
          end
          local style = {}
          merge_hl("RenderMarkdownTableHead", style)
          paint_text(text, function(dest)
            for k, v in pairs(style) do
              dest[k] = v
            end
          end)
        elseif name:find("strong", 1, true) then
          local text = raw:gsub("^%*%*", ""):gsub("%*%*$", ""):gsub("^__", ""):gsub("__$", "")
          paint_text(text, function(dest)
            dest.bold = true
            dest.fg = normal.fg
            dest.bg = nil
          end)
        elseif name:find("italic", 1, true) or name:find("emphasis", 1, true) then
          local text = raw:gsub("^[*_]", ""):gsub("[*_]$", "")
          paint_text(text, function(dest)
            dest.italic = true
            dest.fg = normal.fg
            dest.bg = nil
          end)
        elseif name == "markup.raw" or name == "code" then
          local text = raw:gsub("^`", ""):gsub("`$", "")
          local style = {}
          merge_hl("@markup.raw.markdown_inline", style)
          merge_hl("RenderMarkdownCodeInline", style)
          paint_text(text, function(dest)
            if style.fg then
              dest.fg = style.fg
            end
            if style.bg then
              dest.bg = style.bg
            end
          end)
        elseif name:find("quote", 1, true) then
          local text = raw:gsub("^>%s*", ""):gsub("\n.*", "")
          local style = {}
          merge_hl("RenderMarkdownQuote", style)
          paint_text(text, function(dest)
            if style.fg then
              dest.fg = style.fg
            end
            dest.bg = normal.bg
          end)
        end
        ::continue::
      end
    end)
  end)

  -- Virt text last (icons, table rules, language bars with █ fill).
  local punct = {}
  merge_hl("@punctuation.special.markdown", punct)
  for _, m in ipairs(marks) do
    local d = m[4] or {}
    if d.virt_text then
      local row_hint = row_for_buffer_line(m[2])
      for _, chunk in ipairs(d.virt_text) do
        local text = chunk[1] or ""
        if text:find("%S") or text:find("█") then
          local style = {}
          merge_hl(chunk[2], style)
          if text:find("█") then
            -- Language/code border filler: color every on-screen █ (full width).
            if not style.bg then
              style.bg = normal.bg
            end
            for r = 1, rows do
              for c = 1, cols do
                if vim.fn.screenstring(r, c) == "█" then
                  local dest = cell(r, c)
                  for k, v in pairs(style) do
                    dest[k] = v
                  end
                  dest._virt = true
                end
              end
            end
          else
            local short = vim.fn.strchars(text) <= 2
            local row = paint_text(text, function(dest)
              for k, v in pairs(style) do
                dest[k] = v
              end
              dest._virt = true
            end, {
              allow_virt = true,
              row = short and row_hint or nil,
              all_matches = short and row_hint ~= nil,
            })
            -- Quote marker replaces '>'; TUI keeps the following space as
            -- @punctuation.special (yellow) from the concealed '> '.
            if row and text:find("▋") and punct.fg then
              local map = byte_to_col[row]
              local start = assembled[row]:find(text, 1, true)
              if start then
                local c = map[start + #text - 1]
                if c then
                  local dest = cell(row, c + 1)
                  dest.fg = punct.fg
                end
              end
            end
          end
        end
      end
    end
  end

  -- Mermaid diagram rows sit on RenderMarkdownCode bg in the TUI.
  local code_bg = {}
  merge_hl("RenderMarkdownCode", code_bg)
  if code_bg.bg then
    local lo, hi
    for r = 1, rows do
      if assembled[r]:find("◇", 1, true) then
        lo = lo or r
        hi = r
      end
    end
    if lo and hi then
      for r = lo, hi do
        for c = 1, cols do
          local dest = cell(r, c)
          if not dest.bg then
            dest.bg = code_bg.bg
          end
        end
      end
    end
  end

  return grid
end

local function capture_window()
  vim.cmd("redraw!")
  local rows = vim.o.lines
  local cols = vim.o.columns
  local win = vim.api.nvim_get_current_win()
  -- Match interactive chrome: no folds/statuscol ghosts in the grid.
  pcall(function()
    vim.wo[win].foldcolumn = "0"
    vim.wo[win].statuscolumn = ""
    vim.wo[win].signcolumn = "no"
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].list = false
    vim.wo[win].cursorline = false
  end)
  vim.cmd("redraw!")
  local styles = build_style_grid(win, rows, cols)
  local normal = {}
  merge_hl("Normal", normal)
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
      local st = styles[row] and styles[row][col]
      -- ponytail: ignore screenattr — headless attr near virt_lines/conceal lies.
      -- Default fg to Normal so unstyled text (mermaid boxes, prose) still matches TUI.
      local fg = (st and st.fg) or normal.fg
      local bg = st and st.bg or nil
      local bold = st and st.bold or false
      local italic = st and st.italic or false
      local underline = st and st.underline or false
      local key = table.concat({
        tostring(fg),
        tostring(bg),
        bold and "b" or "",
        italic and "i" or "",
        underline and "u" or "",
      }, "|")
      if key ~= last then
        ansi[#ansi + 1] = "\27[0m"
        if bold then
          ansi[#ansi + 1] = "\27[1m"
        end
        if italic then
          ansi[#ansi + 1] = "\27[3m"
        end
        if underline then
          ansi[#ansi + 1] = "\27[4m"
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
    local line = table.concat(ansi)
    -- Keep trailing spaces when they carry a bg (RenderMarkdownH*Bg hl_eol bars).
    local has_bg = false
    for col = 1, cols do
      local st = styles[row] and styles[row][col]
      if st and st.bg then
        has_bg = true
        break
      end
    end
    if not has_bg then
      line = line:gsub("%s+\27%[0m$", "\27[0m")
    end
    out[#out + 1] = line
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

local function silence_ui_noise()
  pcall(vim.diagnostic.enable, false)
  pcall(vim.diagnostic.hide)
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

  -- Park cursor off content and re-render so anti-conceal / cursorline
  -- variants match the "cursor not on this line" look.
  silence_ui_noise()
  disable_anti_conceal()
  -- Cursor off the content (anti-conceal), but keep topline at 1 so we
  -- capture the start of the file, not whatever the cursor scrolled to.
  pcall(function()
    local last = vim.api.nvim_buf_line_count(buf)
    vim.fn.winrestview({ lnum = last, col = 0, topline = 1, leftcol = 0 })
  end)
  try_force_render(buf, win)
  vim.wait(80, function()
    return false
  end)

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
  local root = vim.env.NVIMCAT_ROOT or vim.g.nvimcat_root
  if root and root ~= "" then
    vim.opt.rtp:prepend(root)
  end

  disable_side_effect_plugins(config)

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
