-- You can add your own plugins here or in other files in this directory!
--  I promise not to create any merge conflicts in this directory :)
--
-- See the kickstart.nvim README for more information
return {
  {
    'sindrets/diffview.nvim',
    cmd = { 'DiffviewOpen', 'DiffviewFileHistory' },
    keys = {
      { '<leader>gd', '<cmd>DiffviewOpen<cr>', desc = 'Diffview: Open (vs HEAD)' },
      { '<leader>gD', '<cmd>DiffviewOpen main<cr>', desc = 'Diffview: Open (vs main)' },
      { '<leader>gh', '<cmd>DiffviewFileHistory %<cr>', desc = 'Diffview: File history' },
      { '<leader>gH', '<cmd>DiffviewFileHistory<cr>', desc = 'Diffview: Branch history' },
      {
        '<leader>gr',
        function()
          require('custom.diffview-reviewed').toggle()
        end,
        desc = 'Diffview: Toggle file reviewed',
      },
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
          { 'n', 'gC', function()
            local ok, lib = pcall(require, 'diffview.lib')
            if not ok then return end
            local view = lib.get_current_view()
            if not view then return end
            local branch = nil
            -- Try to get branch from right rev (tostring calls __tostring metamethod)
            if view.right then
              local rev_str = tostring(view.right)
              -- Check if it's a branch name (not a commit hash or special ref)
              if rev_str and rev_str ~= '' and not rev_str:match('^%x+$') and rev_str ~= 'LOCAL' then
                branch = rev_str
              end
            end
            if branch then
              vim.fn.jobstart({'git', 'checkout', branch}, {
                on_exit = function(_, code)
                  if code == 0 then
                    vim.schedule(function()
                      vim.notify('Checked out: ' .. branch, vim.log.levels.INFO)
                    end)
                  else
                    vim.schedule(function()
                      vim.notify('Failed to checkout: ' .. branch, vim.log.levels.ERROR)
                    end)
                  end
                end
              })
            else
              vim.notify('Could not detect branch (might be viewing working dir changes)', vim.log.levels.WARN)
            end
          end, { desc = 'Checkout reviewed branch' } },
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
          { 'n', 'gC', function()
            local ok, lib = pcall(require, 'diffview.lib')
            if not ok then return end
            local view = lib.get_current_view()
            if not view then return end
            local branch = nil
            if view.right then
              local rev_str = tostring(view.right)
              if rev_str and rev_str ~= '' and not rev_str:match('^%x+$') and rev_str ~= 'LOCAL' then
                branch = rev_str
              end
            end
            if branch then
              vim.fn.jobstart({'git', 'checkout', branch}, {
                on_exit = function(_, code)
                  if code == 0 then
                    vim.schedule(function()
                      vim.notify('Checked out: ' .. branch, vim.log.levels.INFO)
                    end)
                  else
                    vim.schedule(function()
                      vim.notify('Failed to checkout: ' .. branch, vim.log.levels.ERROR)
                    end)
                  end
                end
              })
            else
              vim.notify('Could not detect branch (might be viewing working dir changes)', vim.log.levels.WARN)
            end
          end, { desc = 'Checkout reviewed branch' } },
        },
      },
    },
    config = function(_, opts)
      require('diffview').setup(opts)
      -- Load reviewed module so autocmds are registered
      require('custom.diffview-reviewed')
    end,
  },
}
