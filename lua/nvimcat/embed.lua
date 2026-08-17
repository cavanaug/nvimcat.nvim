--- Helpers executed inside the embedded nvim by bin/nvimcat.
--- Loaded via loadfile() with the root from NVIMCAT_ROOT (see scripts/cli-entry.lua)
--- so Lazy's require hijack cannot reroute these to a plugin spec.
local M = {}

function M.compose_load_plugins()
  local ok = pcall(require, "lazy")
  if ok then
    local loader_ok, loader = pcall(require, "lazy.core.loader")
    if loader_ok then
      pcall(loader.load, {
        plugins = {
          "render-markdown.nvim",
          "render-markdown-mermaid.nvim",
        },
      }, { start = "nvimcat-compose" })
    end
    pcall(vim.cmd, "doautocmd FileType " .. (vim.bo.filetype ~= "" and vim.bo.filetype or "markdown"))
  end
  local width = tonumber(vim.env.NVIMCAT_WIDTH)
  if width then
    vim.o.columns = width
  end
  pcall(function()
    vim.wo[vim.api.nvim_get_current_win()].conceallevel = 2
    vim.wo[vim.api.nvim_get_current_win()].concealcursor = "nvic"
  end)
  local ok_ui, ui = pcall(require, "render-markdown.core.ui")
  if ok_ui then
    pcall(function() require("render-markdown").set(true) end)
    pcall(ui.update, vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win(),
      "nvimcat-compose", true)
    vim.cmd("redraw!")
  end
  return ok_ui
end

--- Strip statusline/tabline/winbar chrome, re-assert conceal settings, and
--- silence the plugins that repaint mid-stitch (lualine/noice/snacks/rumdl).
function M.silence_chrome()
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_get_current_buf()
  vim.o.laststatus = 0
  vim.o.showtabline = 0
  vim.o.cmdheight = 0
  -- Stitch parks cursor on topline; keep links concealed (not anti-conceal raw).
  vim.wo[win].conceallevel = 2
  vim.wo[win].concealcursor = "nvic"
  pcall(function()
    local state = require("render-markdown.state")
    local function disable(cfg)
      if not cfg then return end
      if cfg.anti_conceal then cfg.anti_conceal.enabled = false end
      cfg.win_options = cfg.win_options or {}
      cfg.win_options.concealcursor = cfg.win_options.concealcursor or {}
      cfg.win_options.concealcursor.rendered = "nvic"
    end
    disable(state.config)
    for _, cfg in pairs(state.cache or {}) do disable(cfg) end
  end)
  pcall(function()
    vim.o.winbar = ""
    vim.wo[win].winbar = ""
  end)
  pcall(function()
    require("lualine").hide({
      place = { "statusline", "tabline", "winbar" },
      unhide = false,
    })
  end)
  pcall(function()
    require("snacks").notifier.hide()
  end)
  pcall(function()
    require("noice").disable()
  end)
  pcall(function()
    local opts = require("noice.config").options
    if opts and opts.lsp and opts.lsp.progress then
      opts.lsp.progress.enabled = false
    end
  end)
  for _, client in ipairs(vim.lsp.get_clients()) do
    local name = tostring(client.name or ""):lower()
    if name:find("rumdl", 1, true) then
      pcall(vim.lsp.stop_client, client.id, true)
    end
  end
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local ok, cfg = pcall(vim.api.nvim_win_get_config, w)
    if ok and cfg.relative ~= nil and cfg.relative ~= "" then
      pcall(vim.api.nvim_win_close, w, true)
    end
  end
  for name, id in pairs(vim.api.nvim_get_namespaces()) do
    local n = tostring(name):lower()
    if n:find("rumdl", 1, true) or n:find("notifier", 1, true)
      or n:find("notify", 1, true) or n:find("snacks", 1, true)
      or n:find("noice", 1, true) then
      pcall(vim.api.nvim_buf_clear_namespace, buf, id, 0, -1)
    end
  end
end

function M.pre_stitch_render()
  local buf = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()
  local ok, ui = pcall(require, "render-markdown.core.ui")
  if not ok then
    vim.cmd("redraw!")
    return
  end
  pcall(function() require("render-markdown").set(true) end)
  local decorator = ui.get(buf)
  local before = decorator.n
  pcall(function()
    ui.update(buf, win, "nvimcat-pre-stitch", true)
  end)
  local stable = 0
  local last = before
  vim.wait(5000, function()
    if decorator.running then
      stable = 0
      return false
    end
    local now = decorator.n
    -- ui.update can legitimately be a no-op when the full syntax node is
    -- already decorated. Waiting for a generation bump in that case burns the
    -- entire timeout even though the renderer is idle and stable.
    if now == last then
      stable = stable + 1
      return stable >= 5
    end
    last = now
    stable = 0
    return false
  end, 25)
  vim.cmd("redraw!")
end

--- Scroll so topline=top (1-based) and force a render-markdown update for the
--- new viewport, waiting for the page's parse to settle.
function M.scroll_page(top)
  top = math.max(1, math.floor(tonumber(top) or 1))
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_get_current_buf()
  local view = vim.fn.winsaveview()
  vim.fn.winrestview({ lnum = top, col = 0, topline = top, leftcol = 0 })
  M.silence_chrome()
  if (view.topline or 1) == top then
    vim.cmd("redraw!")
    return
  end
  local ok, ui = pcall(require, "render-markdown.core.ui")
  if not ok then
    vim.cmd("redraw!")
    return
  end
  local decorator = ui.get(buf)
  local before = decorator.n
  pcall(function()
    ui.update(buf, win, "nvimcat-page", true)
  end)
  -- Wait for this page's parse to finish, not just bump decorator.n once.
  local last = before
  local stable = 0
  vim.wait(3000, function()
    if decorator.running then
      stable = 0
      return false
    end
    local now = decorator.n
    if now == last then
      stable = stable + 1
      return stable >= 3
    end
    last = now
    stable = 0
    return false
  end, 20)
  vim.cmd("redraw!")
end

--- Soft-break facts for the current buffer (leaders + treesitter addon).
function M.soft_break_info()
  local ok, sb = pcall(require, "nvimcat.soft_break")
  if not ok then
    return { leaders = {}, addon = { extra_breaks = {}, suppress_blanks = {} } }
  end
  local leaders = sb.line_comment_leaders()
  local addon = sb.treesitter_addon()
  return { leaders = leaders, addon = addon }
end

return M
