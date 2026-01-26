-- You can add your own plugins here or in other files in this directory!
--  I promise not to create any merge conflicts in this directory :)
--
-- See the kickstart.nvim README for more information

-- Load stack-whatchanged module (for trace functionality)
local stack_whatchanged = require('custom.stack-whatchanged')
stack_whatchanged.setup()

-- Load stack-review module (unified review experience)
local stack_review = require('custom.stack-review')
stack_review.setup()

-- Load stack-nav module (visual stack navigator)
local stack_nav = require('custom.stack-nav')
stack_nav.setup({ key = '<leader>sn' })

-- Keybindings for stack review (leader-s prefix)
vim.keymap.set('n', '<leader>sc', function()
  stack_review.open()
end, { desc = 'Stack Review: Open/resume' })

vim.keymap.set('n', '<leader>sr', function()
  stack_review.toggle_reviewed()
end, { desc = 'Stack Review: Toggle file reviewed' })

vim.keymap.set('n', '<leader>ss', function()
  stack_review.show_progress()
end, { desc = 'Stack Review: Progress' })

vim.keymap.set('n', '<leader>sa', function()
  stack_review.complete()
end, { desc = 'Stack Review: Complete (ack)' })

vim.keymap.set('n', '<leader>sq', function()
  stack_review.quit()
end, { desc = 'Stack Review: Quit (preserve)' })

vim.keymap.set('n', '<leader>st', function()
  stack_whatchanged.trace()
end, { desc = 'Stack: Trace current file' })

return {
  {
    'sindrets/diffview.nvim',
    cmd = { 'DiffviewOpen', 'DiffviewFileHistory' },
    keys = {
      { '<leader>gd', '<cmd>DiffviewOpen<cr>', desc = 'Diffview: Open (vs HEAD)' },
      { '<leader>gD', '<cmd>DiffviewOpen main<cr>', desc = 'Diffview: Open (vs main)' },
      { '<leader>gh', '<cmd>DiffviewFileHistory %<cr>', desc = 'Diffview: File history' },
      { '<leader>gH', '<cmd>DiffviewFileHistory<cr>', desc = 'Diffview: Branch history' },
    },
    opts = {
      use_icons = false,
      enhanced_diff_hl = true,
      view = {
        default = {
          layout = 'diff2_horizontal',
        },
        merge_tool = {
          layout = 'diff3_horizontal',
        },
      },
      file_panel = {
        win_config = {
          width = 35,
        },
      },
      keymaps = {
        view = {
          { 'n', 'gF', function()
            local line = vim.fn.line('.')
            local ok, lib = pcall(require, 'diffview.lib')
            if not ok then return end
            local view = lib.get_current_view()
            if not view then return end
            local file = view:infer_cur_file()
            if file and file.path then
              vim.cmd('tabedit ' .. vim.fn.fnameescape(file.path))
              vim.cmd('normal! ' .. line .. 'Gzz')
            end
          end, { desc = 'Open file at current line' } },
        },
        file_panel = {
          { 'n', 'gF', function()
            local ok, lib = pcall(require, 'diffview.lib')
            if not ok then return end
            local view = lib.get_current_view()
            if not view then return end
            local file = view:infer_cur_file()
            if file and file.path then
              vim.cmd('tabedit ' .. vim.fn.fnameescape(file.path))
            end
          end, { desc = 'Open file in new tab' } },
        },
      },
    },
  },
}
