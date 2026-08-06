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

return M
