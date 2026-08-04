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
