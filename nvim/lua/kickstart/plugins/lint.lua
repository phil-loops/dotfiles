return {

  { -- Linting
    'mfussenegger/nvim-lint',
    event = { 'BufReadPre', 'BufNewFile' },
    config = function()
      local lint = require 'lint'
      lint.linters_by_ft = {
        markdown = { 'markdownlint' },
        typescript = { 'oxlint' },
        typescriptreact = { 'oxlint' },
        javascript = { 'oxlint' },
      }

      -- To allow other plugins to add linters to require('lint').linters_by_ft,
      -- instead set linters_by_ft like this:
      -- lint.linters_by_ft = lint.linters_by_ft or {}
      -- lint.linters_by_ft['markdown'] = { 'markdownlint' }
      --
      -- However, note that this will enable a set of default linters,
      -- which will cause errors unless these tools are available:
      -- {
      --   clojure = { "clj-kondo" },
      --   dockerfile = { "hadolint" },
      --   inko = { "inko" },
      --   janet = { "janet" },
      --   json = { "jsonlint" },
      --   markdown = { "vale" },
      --   rst = { "vale" },
      --   ruby = { "ruby" },
      --   terraform = { "tflint" },
      --   text = { "vale" }
      -- }
      --
      -- You can disable the default linters by setting their filetypes to nil:
      -- lint.linters_by_ft['clojure'] = nil
      -- lint.linters_by_ft['dockerfile'] = nil
      -- lint.linters_by_ft['inko'] = nil
      -- lint.linters_by_ft['janet'] = nil
      -- lint.linters_by_ft['json'] = nil
      -- lint.linters_by_ft['markdown'] = nil
      -- lint.linters_by_ft['rst'] = nil
      -- lint.linters_by_ft['ruby'] = nil
      -- lint.linters_by_ft['terraform'] = nil
      -- lint.linters_by_ft['text'] = nil

      -- Resolve the linters configured for this buffer's filetype down to the
      -- ones whose executable is actually on PATH. A standalone file outside a
      -- project (e.g. ~/design-docs/foo.ts with no local node_modules) otherwise
      -- spawns oxlint and throws ENOENT on every BufEnter/InsertLeave.
      local function runnable_linters()
        local runnable = {}
        for _, name in ipairs(lint.linters_by_ft[vim.bo.filetype] or {}) do
          local linter = lint.linters[name]
          local cmd = type(linter) == 'table' and linter.cmd or nil
          if type(cmd) == 'function' then
            cmd = cmd()
          end
          if cmd and vim.fn.executable(cmd) == 1 then
            table.insert(runnable, name)
          end
        end
        return runnable
      end

      -- Create autocommand which carries out the actual linting
      -- on the specified events.
      local lint_augroup = vim.api.nvim_create_augroup('lint', { clear = true })
      vim.api.nvim_create_autocmd({ 'BufEnter', 'BufWritePost', 'InsertLeave' }, {
        group = lint_augroup,
        callback = function()
          -- Only run the linter in buffers that you can modify in order to
          -- avoid superfluous noise, notably within the handy LSP pop-ups that
          -- describe the hovered symbol using Markdown.
          if not vim.opt_local.modifiable:get() then
            return
          end
          local linters = runnable_linters()
          if #linters > 0 then
            lint.try_lint(linters)
          end
        end,
      })
    end,
  },
}
