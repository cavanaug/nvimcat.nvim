local M = {}

---@param commentstring string
---@param comments string
---@return { leader: string, blank_required: boolean }[]
function M.parse_leaders(commentstring, comments)
  local by_leader = {}

  local function add(leader, blank_required)
    if not leader or leader == "" then
      return
    end
    local prev = by_leader[leader]
    if prev == nil then
      by_leader[leader] = blank_required and true or false
    elseif blank_required then
      by_leader[leader] = true
    end
  end

  commentstring = commentstring or ""
  local pre, post = commentstring:match("^(.-)%%s(.*)$")
  if pre and (post or ""):match("^%s*$") then
    add(pre:gsub("%s+$", ""), true)
  end

  for part in ((comments or "") .. ","):gmatch("([^,]*),") do
    if part ~= "" then
      local flags, str = part:match("^([a-zA-Z0-9]*):(.*)$")
      if flags and str and str ~= "" then
        if not flags:find("[smefn]") then
          add(str, flags:find("b", 1, true) ~= nil)
        end
      end
    end
  end

  local out = {}
  for leader, blank_required in pairs(by_leader) do
    out[#out + 1] = { leader = leader, blank_required = blank_required }
  end
  table.sort(out, function(a, b)
    return a.leader < b.leader
  end)
  return out
end

---@param buf integer?
function M.line_comment_leaders(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  return M.parse_leaders(vim.bo[buf].commentstring, vim.bo[buf].comments)
end

local function empty_addon()
  return { extra_breaks = {}, suppress_blanks = {} }
end

---@param buf integer?
---@return { extra_breaks: integer[], suppress_blanks: integer[][] }
function M.treesitter_addon(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local ft = vim.bo[buf].filetype or ""
  if ft ~= "markdown" and not ft:match("^markdown") then
    return empty_addon()
  end

  local ok, parser = pcall(vim.treesitter.get_parser, buf, "markdown")
  if not ok or not parser then
    return empty_addon()
  end

  local trees = parser:parse()
  local root = trees and trees[1] and trees[1]:root()
  if not root then
    return empty_addon()
  end

  local extra, suppress, seen = {}, {}, {}
  local function add_break(row0)
    local line = row0 + 1
    if not seen[line] then
      seen[line] = true
      extra[#extra + 1] = line
    end
  end

  local function walk(node)
    local typ = node:type()
    if typ == "atx_heading" or typ == "setext_heading" then
      add_break(node:range())
    elseif typ == "fenced_code_block" then
      local open_row, close_row, block_end_row
      for child in node:iter_children() do
        if child:type() == "fenced_code_block_delimiter" then
          local row = child:range()
          if not open_row then
            open_row = row
            add_break(row)
          else
            close_row = row
          end
        end
      end
      block_end_row = select(3, node:range())
      if open_row then
        local start_line = open_row + 2
        local end_line = close_row or block_end_row
        if start_line <= end_line then
          suppress[#suppress + 1] = { start_line, end_line }
        end
      end
    end
    for child in node:iter_children() do
      walk(child)
    end
  end

  walk(root)
  table.sort(extra)
  return { extra_breaks = extra, suppress_blanks = suppress }
end

---@param buf integer?
function M.soft_break_info(buf)
  return {
    leaders = M.line_comment_leaders(buf),
    addon = M.treesitter_addon(buf),
  }
end

return M
