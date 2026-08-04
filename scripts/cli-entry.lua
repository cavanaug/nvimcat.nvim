-- CLI bootstrap: load nvimcat from NVIMCAT_ROOT, bypassing Lazy's require hijack.
local r = assert(vim.env.NVIMCAT_ROOT or vim.g.nvimcat_root, "NVIMCAT_ROOT unset")
package.loaded["nvimcat"] = nil
if vim.loader and vim.loader.reset then
  vim.loader.reset()
end
vim.opt.rtp:prepend(r)
local m = assert(loadfile(r .. "/lua/nvimcat/init.lua"), "missing " .. r .. "/lua/nvimcat/init.lua")()
package.loaded["nvimcat"] = m
m.cli()
