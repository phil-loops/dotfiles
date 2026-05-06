-- Custom plugins
return {
  {
    "phil-loops/diffview.nvim",
    branch = "stack-drift",
    cmd = { "DiffviewOpen", "DiffviewFileHistory", "DiffviewClose" },
    opts = {
      use_icons = false,
      file_panel = { listing_style = "list" },
    },
  },
  {
    "folke/persistence.nvim",
    event = "BufReadPre",
    opts = {},
    keys = {
      { "<leader>qs", function() require("persistence").load() end, desc = "Restore session" },
      { "<leader>qS", function() require("persistence").select() end, desc = "Select session" },
      { "<leader>ql", function() require("persistence").load({ last = true }) end, desc = "Restore last session" },
      { "<leader>qd", function() require("persistence").stop() end, desc = "Don't save current session" },
    },
  },
  {
    "MeanderingProgrammer/render-markdown.nvim",
    dependencies = { "nvim-treesitter/nvim-treesitter", "nvim-tree/nvim-web-devicons" },
    ft = { "markdown" },
    init = function()
      vim.filetype.add({ extension = { mdx = "markdown" } })
    end,
    opts = {},
  },
}
