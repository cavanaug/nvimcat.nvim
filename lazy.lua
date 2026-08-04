return {
  "cavanaug/nvimcat.nvim",
  cmd = "NvimCat",
  opts = {},
  build = function()
    require("nvimcat").install_cli()
  end,
}
