-- Shared prep for nvimcat dump and agent-terminal compare harness.
local ok, nvimcat = pcall(require, "nvimcat")
if not ok then
  -- rtp may need a moment after spawn -c
  vim.opt.rtp:prepend(vim.env.NVIMCAT_ROOT or vim.g.nvimcat_root or "")
  nvimcat = require("nvimcat")
end
nvimcat.prep_compare()
