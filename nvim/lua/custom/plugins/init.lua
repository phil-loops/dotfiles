-- Custom plugins
return {
  {
    "phil-loops/diffview.nvim",
    branch = "stack-drift",
    cmd = { "DiffviewOpen", "DiffviewFileHistory", "DiffviewClose" },
    opts = function()
      local actions = require("diffview.actions")
      return {
        use_icons = false,
        file_panel = {
          listing_style = "tree",
          tree_options = { flatten_dirs = false, folder_statuses = "always" },
        },
        keymaps = {
          file_panel = {
            { "n", "<Tab>",   actions.select_next_entry, { desc = "Open next file" } },
            { "n", "<S-Tab>", actions.select_prev_entry, { desc = "Open prev file" } },
            { "n", "<CR>",    actions.select_entry,     { desc = "Open selected file" } },
            { "n", "o",       actions.select_entry,     { desc = "Open selected file" } },
            { "n", "j",       actions.next_entry,       { desc = "Move cursor to next entry" } },
            { "n", "k",       actions.prev_entry,       { desc = "Move cursor to prev entry" } },
          },
          view = {
            { "n", "<Tab>",   actions.select_next_entry, { desc = "Open next file" } },
            { "n", "<S-Tab>", actions.select_prev_entry, { desc = "Open prev file" } },
          },
        },
      }
    end,
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
