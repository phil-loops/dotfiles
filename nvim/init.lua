--[[

=====================================================================
==================== READ THIS BEFORE CONTINUING ====================
=====================================================================
========                                    .-----.          ========
========         .----------------------.   | === |          ========
========         |.-""""""""""""""""""-.|   |-----|          ========
========         ||                    ||   | === |          ========
========         ||   KICKSTART.NVIM   ||   |-----|          ========
========         ||                    ||   | === |          ========
========         ||                    ||   |-----|          ========
========         ||:Tutor              ||   |:::::|          ========
========         |'-..................-'|   |____o|          ========
========         `"")----------------(""`   ___________      ========
========        /::::::::::|  |::::::::::\  \ no mouse \     ========
========       /:::========|  |==hjkl==:::\  \ required \    ========
========      '""""""""""""'  '""""""""""""'  '""""""""""'   ========
========                                                     ========
=====================================================================
=====================================================================

What is Kickstart?

  Kickstart.nvim is *not* a distribution.

  Kickstart.nvim is a starting point for your own configuration.
    The goal is that you can read every line of code, top-to-bottom, understand
    what your configuration is doing, and modify it to suit your needs.

    Once you've done that, you can start exploring, configuring and tinkering to
    make Neovim your own! That might mean leaving Kickstart just the way it is for a while
    or immediately breaking it into modular pieces. It's up to you!

    If you don't know anything about Lua, I recommend taking some time to read through
    a guide. One possible example which will only take 10-15 minutes:
      - https://learnxinyminutes.com/docs/lua/

    After understanding a bit more about Lua, you can use `:help lua-guide` as a
    reference for how Neovim integrates Lua.
    - :help lua-guide
    - (or HTML version): https://neovim.io/doc/user/lua-guide.html

Kickstart Guide:

  TODO: The very first thing you should do is to run the command `:Tutor` in Neovim.

    If you don't know what this means, type the following:
      - <escape key>
      - :
      - Tutor
      - <enter key>

    (If you already know the Neovim basics, you can skip this step.)

  Once you've completed that, you can continue working through **AND READING** the rest
  of the kickstart init.lua.

  Next, run AND READ `:help`.
    This will open up a help window with some basic information
    about reading, navigating and searching the builtin help documentation.

    This should be the first place you go to look when you're stuck or confused
    with something. It's one of my favorite Neovim features.

    MOST IMPORTANTLY, we provide a keymap "<space>sh" to [s]earch the [h]elp documentation,
    which is very useful when you're not exactly sure of what you're looking for.

  I have left several `:help X` comments throughout the init.lua
    These are hints about where to find more information about the relevant settings,
    plugins or Neovim features used in Kickstart.

   NOTE: Look for lines like this

    Throughout the file. These are for you, the reader, to help you understand what is happening.
    Feel free to delete them once you know what you're doing, but they should serve as a guide
    for when you are first encountering a few different constructs in your Neovim config.

If you experience any errors while trying to install kickstart, run `:checkhealth` for more info.

I hope you enjoy your Neovim journey,
- TJ

P.S. You can delete this when you're done too. It's your config now! :)
--]]

-- Set <space> as the leader key
-- review-nvim is often spawned outside an interactive shell (a tmux/launcher pane), so its
-- PATH misses the dirs the shell rc adds — volta shims, homebrew, ~/.local/bin — and EVERY
-- tool nvim spawns (LSPs like tsgo, formatters, linters) then fails to resolve. Prepend the
-- known tool dirs that exist and aren't already present, once, before anything spawns.
do
  local want = { vim.fn.expand '~/.volta/bin', '/opt/homebrew/bin', '/usr/local/bin', vim.fn.expand '~/.local/bin' }
  local cur = vim.env.PATH or ''
  local have = {}
  for dir in cur:gmatch '[^:]+' do
    have[dir] = true
  end
  local prepend = {}
  for _, dir in ipairs(want) do
    if vim.fn.isdirectory(dir) == 1 and not have[dir] then
      prepend[#prepend + 1] = dir
    end
  end
  if #prepend > 0 then
    vim.env.PATH = table.concat(prepend, ':') .. ':' .. cur
  end
end

-- See `:help mapleader`
--  NOTE: Must happen before plugins are loaded (otherwise wrong leader will be used)
vim.g.mapleader = ' '
vim.g.maplocalleader = ' '

-- Expose a per-pid socket so external tooling (claude, nvr) can drive this instance.
pcall(vim.fn.serverstart, '/tmp/nvim-' .. vim.fn.getpid())

-- Set to true if you have a Nerd Font installed and selected in the terminal
vim.g.have_nerd_font = false

-- [[ Setting options ]]
-- See `:help vim.opt`
-- NOTE: You can change these options as you wish!
--  For more options, you can see `:help option-list`

-- Make line numbers default
vim.opt.number = true
-- You can also add relative line numbers, to help with jumping.
--  Experiment for yourself to see if you like it!
-- vim.opt.relativenumber = true

-- Enable mouse mode, can be useful for resizing splits for example!
vim.opt.mouse = 'a'

-- Don't show the mode, since it's already in the status line
vim.opt.showmode = false

-- Sync clipboard between OS and Neovim.
--  Schedule the setting after `UiEnter` because it can increase startup-time.
--  Remove this option if you want your OS clipboard to remain independent.
--  See `:help 'clipboard'`
vim.schedule(function()
  vim.opt.clipboard = 'unnamedplus'
end)

-- Enable break indent
vim.opt.breakindent = true

-- Save undo history
vim.opt.undofile = true

-- Case-insensitive searching UNLESS \C or one or more capital letters in the search term
vim.opt.ignorecase = true
vim.opt.smartcase = true

-- Keep signcolumn on by default
vim.opt.signcolumn = 'yes'

-- Decrease update time
vim.opt.updatetime = 250

-- Decrease mapped sequence wait time
vim.opt.timeoutlen = 300

-- Configure how new splits should be opened
vim.opt.splitright = true
vim.opt.splitbelow = true

-- Sets how neovim will display certain whitespace characters in the editor.
--  See `:help 'list'`
--  and `:help 'listchars'`
vim.opt.list = true
vim.opt.listchars = { tab = '» ', trail = '·', nbsp = '␣' }

-- Preview substitutions live, as you type!
vim.opt.inccommand = 'split'

-- Show which line your cursor is on
vim.opt.cursorline = true

-- Minimal number of screen lines to keep above and below the cursor.
vim.opt.scrolloff = 10

-- [[ Basic Keymaps ]]
--  See `:help vim.keymap.set()`

-- Clear highlights on search when pressing <Esc> in normal mode
--  See `:help hlsearch`
vim.keymap.set('n', '<Esc>', '<cmd>nohlsearch<CR>')

-- Diagnostic keymaps
vim.keymap.set('n', '<leader>q', vim.diagnostic.setloclist, { desc = 'Open diagnostic [Q]uickfix list' })

-- Yank relative file path to clipboard
vim.keymap.set('n', '<leader>yf', function()
  vim.fn.setreg('+', vim.fn.fnamemodify(vim.fn.expand '%', ':.'))
end, { desc = '[Y]ank [F]ile path (relative to project root)' })

-- Run `task test -- <current file>` async, populate quickfix on failure
vim.keymap.set('n', '<leader>tt', function()
  local file = vim.fn.fnamemodify(vim.fn.expand '%', ':.')
  vim.notify('task test -- ' .. file)
  vim.system({ 'task', 'test', '--', file }, { text = true }, function(obj)
    vim.schedule(function()
      local out = (obj.stdout or '') .. (obj.stderr or '')
      vim.fn.setqflist({}, ' ', {
        title = 'task test ' .. file,
        lines = vim.split(out, '\n'),
        efm = [[%.%#at\ %.%#(%f:%l:%c)]],
      })
      if obj.code == 0 then
        vim.notify '✓ tests passed'
        vim.cmd 'cclose'
      else
        vim.cmd 'copen'
      end
    end)
  end)
end, { desc = '[T]ask [T]est current file' })

-- Exit terminal mode in the builtin terminal with a shortcut that is a bit easier
-- for people to discover. Otherwise, you normally need to press <C-\><C-n>, which
-- is not what someone will guess without a bit more experience.
--
-- NOTE: This won't work in all terminal emulators/tmux/etc. Try your own mapping
-- or just use <C-\><C-n> to exit terminal mode
vim.keymap.set('t', '<Esc><Esc>', '<C-\\><C-n>', { desc = 'Exit terminal mode' })

-- TIP: Disable arrow keys in normal mode
-- vim.keymap.set('n', '<left>', '<cmd>echo "Use h to move!!"<CR>')
-- vim.keymap.set('n', '<right>', '<cmd>echo "Use l to move!!"<CR>')
-- vim.keymap.set('n', '<up>', '<cmd>echo "Use k to move!!"<CR>')
-- vim.keymap.set('n', '<down>', '<cmd>echo "Use j to move!!"<CR>')

-- Keybinds to make split navigation easier.
--  Use CTRL+<hjkl> to switch between windows
--
--  See `:help wincmd` for a list of all window commands
vim.keymap.set('n', '<C-h>', '<C-w><C-h>', { desc = 'Move focus to the left window' })
vim.keymap.set('n', '<C-l>', '<C-w><C-l>', { desc = 'Move focus to the right window' })
vim.keymap.set('n', '<C-j>', '<C-w><C-j>', { desc = 'Move focus to the lower window' })
vim.keymap.set('n', '<C-k>', '<C-w><C-k>', { desc = 'Move focus to the upper window' })
vim.keymap.set('n', '<C-w>d', ':vsp<CR>gd', { desc = 'Open the definition in a vertical split' })
-- Scrolling with centering
vim.keymap.set('n', '<C-d>', '<C-d>zz', { desc = 'Scroll down half-page and center' })
vim.keymap.set('n', '<C-u>', '<C-u>zz', { desc = 'Scroll up half-page and center' })

-- [[ Basic Autocommands ]]
--  See `:help lua-guide-autocommands`

-- Highlight when yanking (copying) text
--  Try it with `yap` in normal mode
--  See `:help vim.highlight.on_yank()`
vim.api.nvim_create_autocmd('TextYankPost', {
  desc = 'Highlight when yanking (copying) text',
  group = vim.api.nvim_create_augroup('kickstart-highlight-yank', { clear = true }),
  callback = function()
    vim.highlight.on_yank()
  end,
})

-- [[ Install `lazy.nvim` plugin manager ]]
--    See `:help lazy.nvim.txt` or https://github.com/folke/lazy.nvim for more info
local lazypath = vim.fn.stdpath 'data' .. '/lazy/lazy.nvim'
if not (vim.uv or vim.loop).fs_stat(lazypath) then
  local lazyrepo = 'https://github.com/folke/lazy.nvim.git'
  local out = vim.fn.system { 'git', 'clone', '--filter=blob:none', '--branch=stable', lazyrepo, lazypath }
  if vim.v.shell_error ~= 0 then
    error('Error cloning lazy.nvim:\n' .. out)
  end
end ---@diagnostic disable-next-line: undefined-field
vim.opt.rtp:prepend(lazypath)

-- [[ Configure and install plugins ]]
--
--  To check the current status of your plugins, run
--    :Lazy
--
--  You can press `?` in this menu for help. Use `:q` to close the window
--
--  To update plugins you can run
--    :Lazy update
--
-- NOTE: Here is where you install your plugins.
require('lazy').setup({
  -- NOTE: Plugins can be added with a link (or for a github repo: 'owner/repo' link).
  'tpope/vim-sleuth', -- Detect tabstop and shiftwidth automatically
  'tpope/vim-fugitive', -- git integration
  'tpope/vim-rhubarb', -- GitHub integration for fugitive (:GBrowse)
  -- NOTE: Plugins can also be added by using a table,
  -- with the first argument being the link and the following
  -- keys can be used to configure plugin behavior/loading/etc.
  --
  -- Use `opts = {}` to force a plugin to be loaded.
  --

  -- Here is a more advanced example where we pass configuration
  -- options to `gitsigns.nvim`. This is equivalent to the following Lua:
  --    require('gitsigns').setup({ ... })
  --
  -- See `:help gitsigns` to understand what the configuration keys do
  { -- Adds git related signs to the gutter, as well as utilities for managing changes
    'lewis6991/gitsigns.nvim',
    opts = {
      signs = {
        add = { text = '+' },
        change = { text = '~' },
        delete = { text = '_' },
        topdelete = { text = '‾' },
        changedelete = { text = '~' },
      },
    },
  },

  -- NOTE: Plugins can also be configured to run Lua code when they are loaded.
  --
  -- This is often very useful to both group configuration, as well as handle
  -- lazy loading plugins that don't need to be loaded immediately at startup.
  --
  -- For example, in the following configuration, we use:
  --  event = 'VimEnter'
  --
  -- which loads which-key before all the UI elements are loaded. Events can be
  -- normal autocommands events (`:help autocmd-events`).
  --
  -- Then, because we use the `opts` key (recommended), the configuration runs
  -- after the plugin has been loaded as `require(MODULE).setup(opts)`.

  { -- Useful plugin to show you pending keybinds.
    'folke/which-key.nvim',
    event = 'VimEnter', -- Sets the loading event to 'VimEnter'
    opts = {
      -- delay between pressing a key and opening which-key (milliseconds)
      -- this setting is independent of vim.opt.timeoutlen
      delay = 0,
      icons = {
        -- set icon mappings to true if you have a Nerd Font
        mappings = vim.g.have_nerd_font,
        -- If you are using a Nerd Font: set icons.keys to an empty table which will use the
        -- default which-key.nvim defined Nerd Font icons, otherwise define a string table
        keys = vim.g.have_nerd_font and {} or {
          Up = '<Up> ',
          Down = '<Down> ',
          Left = '<Left> ',
          Right = '<Right> ',
          C = '<C-…> ',
          M = '<M-…> ',
          D = '<D-…> ',
          S = '<S-…> ',
          CR = '<CR> ',
          Esc = '<Esc> ',
          ScrollWheelDown = '<ScrollWheelDown> ',
          ScrollWheelUp = '<ScrollWheelUp> ',
          NL = '<NL> ',
          BS = '<BS> ',
          Space = '<Space> ',
          Tab = '<Tab> ',
          F1 = '<F1>',
          F2 = '<F2>',
          F3 = '<F3>',
          F4 = '<F4>',
          F5 = '<F5>',
          F6 = '<F6>',
          F7 = '<F7>',
          F8 = '<F8>',
          F9 = '<F9>',
          F10 = '<F10>',
          F11 = '<F11>',
          F12 = '<F12>',
        },
      },

      -- Document existing key chains
      spec = {
        { '<leader>c', group = '[C]ode', mode = { 'n', 'x' } },
        { '<leader>d', group = '[D]ocument' },
        { '<leader>r', group = '[R]ename' },
        { '<leader>s', group = '[S]earch/Stack' },
        { '<leader>w', group = '[W]orkspace' },
        { '<leader>t', group = '[T]oggle' },
        { '<leader>h', group = 'Git [H]unk', mode = { 'n', 'v' } },
        { '<leader>g', group = '[G]it' },
        { ']', group = '+Next' },
        { '[', group = '+Prev' },
      },
    },
  },

  -- NOTE: Plugins can specify dependencies.
  --
  -- The dependencies are proper plugin specifications as well - anything
  -- you do for a plugin at the top level, you can do for a dependency.
  --
  -- Use the `dependencies` key to specify the dependencies of a particular plugin

  { -- Fuzzy Finder (files, lsp, etc)
    'nvim-telescope/telescope.nvim',
    event = 'VimEnter',
    dependencies = {
      'nvim-lua/plenary.nvim',
      { -- If encountering errors, see telescope-fzf-native README for installation instructions
        'nvim-telescope/telescope-fzf-native.nvim',

        -- `build` is used to run some command when the plugin is installed/updated.
        -- This is only run then, not every time Neovim starts up.
        build = 'make',

        -- `cond` is a condition used to determine whether this plugin should be
        -- installed and loaded.
        cond = function()
          return vim.fn.executable 'make' == 1
        end,
      },
      { 'nvim-telescope/telescope-ui-select.nvim' },

      -- Useful for getting pretty icons, but requires a Nerd Font.
      { 'nvim-tree/nvim-web-devicons', enabled = vim.g.have_nerd_font },
    },
    config = function()
      -- Telescope is a fuzzy finder that comes with a lot of different things that
      -- it can fuzzy find! It's more than just a "", it can search
      -- many different aspects of Neovim, your workspace, LSP, and more!
      --
      -- The easiest way to use Telescope, is to start by doing something like:
      --  :Telescope help_tags
      --
      -- After running this command, a window will open up and you're able to
      -- type in the prompt window. You'll see a list of `help_tags` options and
      -- a corresponding preview of the help.
      --
      -- Two important keymaps to use while in Telescope are:
      --  - Insert mode: <c-/>
      --  - Normal mode: ?
      --
      -- This opens a window that shows you all of the keymaps for the current
      -- Telescope picker. This is really useful to discover what Telescope can
      -- do as well as how to actually do it!

      -- [[ Configure Telescope ]]
      -- See `:help telescope` and `:help telescope.setup()`
      require('telescope').setup {
        -- You can put your default mappings / updates / etc. in here
        --  All the info you're looking for is in `:help telescope.setup()`
        --
        -- defaults = {
        --   mappings = {
        --     i = { ['<c-enter>'] = 'to_fuzzy_refine' },
        --   },
        -- },
        defaults = {
          file_ignore_patterns = {
            'node_modules/.*',
            'serverless%-framework',
          },
          mappings = {
            i = {
              ['<tab>'] = 'toggle_selection',
              ['<C-o>'] = function(prompt_bufnr)
                local actions = require 'telescope.actions'
                local action_state = require 'telescope.actions.state'
                local picker = action_state.get_current_picker(prompt_bufnr)

                -- Get marked entries
                local marked = picker:get_multi_selection()

                -- Create a set of marked filenames
                local marked_files = {}
                for _, entry in ipairs(marked) do
                  if entry.filename then
                    marked_files[entry.filename] = true
                  end
                end

                -- Track unique files
                local seen_files = {}

                -- Process each entry safely
                for _, entry in ipairs(picker.finder.results or {}) do
                  if entry.filename and not marked_files[entry.filename] and not seen_files[entry.filename] then
                    seen_files[entry.filename] = true
                    vim.cmd('tabnew ' .. vim.fn.fnameescape(entry.filename))
                    vim.api.nvim_win_set_cursor(0, { entry.lnum, 0 })
                  end
                end

                actions.close(prompt_bufnr)
              end,
            },
          },
        },
        -- pickers = {}
        extensions = {
          ['ui-select'] = {
            require('telescope.themes').get_dropdown(),
          },
        },
      }

      -- Enable Telescope extensions if they are installed
      pcall(require('telescope').load_extension, 'fzf')
      pcall(require('telescope').load_extension, 'ui-select')

      -- See `:help telescope.builtin`
      local builtin = require 'telescope.builtin'
      vim.keymap.set('n', '<leader>sh', builtin.help_tags, { desc = '[S]earch [H]elp' })
      vim.keymap.set('n', '<leader>sk', builtin.keymaps, { desc = '[S]earch [K]eymaps' })
      vim.keymap.set('n', '<leader>sf', builtin.find_files, { desc = '[S]earch [F]iles' })
      vim.keymap.set('n', '<leader>ss', builtin.builtin, { desc = '[S]earch [S]elect Telescope' })
      vim.keymap.set('n', '<leader>sw', builtin.grep_string, { desc = '[S]earch current [W]ord' })
      vim.keymap.set('n', '<leader>sg', builtin.live_grep, { desc = '[S]earch by [G]rep' })
      vim.keymap.set('n', '<leader>sd', builtin.diagnostics, { desc = '[S]earch [D]iagnostics' })
      vim.keymap.set('n', '<leader>sr', builtin.resume, { desc = '[S]earch [R]esume' })
      vim.keymap.set('n', '<leader>s.', builtin.oldfiles, { desc = '[S]earch Recent Files ("." for repeat)' })
      vim.keymap.set('n', '<leader><leader>', builtin.buffers, { desc = '[ ] Find existing buffers' })

      -- Slightly advanced example of overriding default behavior and theme
      vim.keymap.set('n', '<leader>/', function()
        -- You can pass additional configuration to Telescope to change the theme, layout, etc.
        builtin.current_buffer_fuzzy_find(require('telescope.themes').get_dropdown {
          winblend = 10,
          previewer = false,
        })
      end, { desc = '[/] Fuzzily search in current buffer' })

      -- It's also possible to pass additional configuration options.
      --  See `:help telescope.builtin.live_grep()` for information about particular keys
      vim.keymap.set('n', '<leader>s/', function()
        builtin.live_grep {
          grep_open_files = true,
          prompt_title = 'Live Grep in Open Files',
        }
      end, { desc = '[S]earch [/] in Open Files' })

      -- Shortcut for searching your Neovim configuration files
      vim.keymap.set('n', '<leader>sn', function()
        builtin.find_files { cwd = vim.fn.stdpath 'config' }
      end, { desc = '[S]earch [N]eovim files' })

      -- Show files changed since diverging from main (fetches origin/main so it's always current)
      vim.keymap.set('n', '<leader>gm', function()
        vim.fn.system('git fetch origin main --quiet')
        local base = vim.fn.system('git merge-base origin/main HEAD'):gsub('%s+$', '')
        local cur = vim.fn.system('git rev-parse --abbrev-ref HEAD'):gsub('%s+$', '')

        -- Diffview only lists untracked files in its index→worktree view; it
        -- hard-codes that they're never shown when diffing against a base rev
        -- (so the `--untracked-files` flag does nothing here). To get net-new
        -- files into the merge-base diff we intent-to-add them (`git add -N`),
        -- which makes them appear as added without staging their contents. We
        -- undo it (scoped to exactly those paths) when the view is closed, so the
        -- index is left clean -- a lingering `-N` entry makes `git rebase` abort
        -- with "unstaged changes", which would break the stack workflow.
        local untracked = vim.fn.systemlist({ 'git', 'ls-files', '--others', '--exclude-standard' })
        if #untracked > 0 then
          vim.fn.system(vim.list_extend({ 'git', 'add', '-N', '--' }, untracked))
          vim.api.nvim_create_autocmd('User', {
            pattern = 'DiffviewViewClosed',
            once = true,
            callback = function()
              vim.fn.system(vim.list_extend({ 'git', 'reset', '-q', '--' }, untracked))
            end,
          })
        end

        -- Re-target review-bindings to current HEAD so <leader>gf doesn't try to
        -- checkout a stale branch from a previous review session in this nvim session.
        require('custom.review-bindings').setup({
          get_branch = function() return cur end,
          get_base = function() return base end,
          get_unreviewed = function() return {} end,
        })
        vim.cmd('DiffviewOpen ' .. base)
      end, { desc = '[G]it diff from [M]ain (merge-base)' })

      -- Show working tree status (staged, unstaged, untracked)
      vim.keymap.set('n', '<leader>gs', function()
        vim.cmd('DiffviewOpen')
      end, { desc = '[G]it [S]tatus (working tree)' })

      -- Open current line/selection on GitHub (main branch)
      vim.keymap.set('n', '<leader>go', ':GBrowse main:%<CR>', { desc = '[G]it [O]pen on GitHub (main)' })
      vim.keymap.set('v', '<leader>go', ':GBrowse main:%<CR>', { desc = '[G]it [O]pen on GitHub (main)' })
      -- Open current line/selection on GitHub (current branch)
      vim.keymap.set('n', '<leader>gO', ':GBrowse<CR>', { desc = '[G]it [O]pen on GitHub (branch)' })
      vim.keymap.set('v', '<leader>gO', ':GBrowse<CR>', { desc = '[G]it [O]pen on GitHub (branch)' })
    end,
  },

  -- LSP Plugins
  {
    -- `lazydev` configures Lua LSP for your Neovim config, runtime and plugins
    -- used for completion, annotations and signatures of Neovim apis
    'folke/lazydev.nvim',
    ft = 'lua',
    opts = {
      library = {
        -- Load luvit types when the `vim.uv` word is found
        { path = '${3rd}/luv/library', words = { 'vim%.uv' } },
      },
    },
  },
  {
    -- Main LSP Configuration
    'neovim/nvim-lspconfig',
    dependencies = {
      -- Automatically install LSPs and related tools to stdpath for Neovim
      -- Mason must be loaded before its dependents so we need to set it up here.
      -- NOTE: `opts = {}` is the same as calling `require('mason').setup({})`
      { 'williamboman/mason.nvim', opts = {} },
      'williamboman/mason-lspconfig.nvim',
      'WhoIsSethDaniel/mason-tool-installer.nvim',

      -- Useful status updates for LSP.
      { 'j-hui/fidget.nvim', opts = {} },

      -- Allows extra capabilities provided by nvim-cmp
      'hrsh7th/cmp-nvim-lsp',
    },
    config = function()
      -- Brief aside: **What is LSP?**
      --
      -- LSP is an initialism you've probably heard, but might not understand what it is.
      --
      -- LSP stands for Language Server Protocol. It's a protocol that helps editors
      -- and language tooling communicate in a standardized fashion.
      --
      -- In general, you have a "server" which is some tool built to understand a particular
      -- language (such as `gopls`, `lua_ls`, `rust_analyzer`, etc.). These Language Servers
      -- (sometimes called LSP servers, but that's kind of like ATM Machine) are standalone
      -- processes that communicate with some "client" - in this case, Neovim!
      --
      -- LSP provides Neovim with features like:
      --  - Go to definition
      --  - Find references
      --  - Autocompletion
      --  - Symbol Search
      --  - and more!
      --
      -- Thus, Language Servers are external tools that must be installed separately from
      -- Neovim. This is where `mason` and related plugins come into play.
      --
      -- If you're wondering about lsp vs treesitter, you can check out the wonderfully
      -- and elegantly composed help section, `:help lsp-vs-treesitter`

      --  This function gets run when an LSP attaches to a particular buffer.
      --    That is to say, every time a new file is opened that is associated with
      --    an lsp (for example, opening `main.rs` is associated with `rust_analyzer`) this
      --    function will be executed to configure the current buffer
      vim.api.nvim_create_autocmd('LspAttach', {
        group = vim.api.nvim_create_augroup('kickstart-lsp-attach', { clear = true }),
        callback = function(event)
          -- NOTE: Remember that Lua is a real programming language, and as such it is possible
          -- to define small helper and utility functions so you don't have to repeat yourself.
          --
          -- In this case, we create a function that lets us more easily define mappings specific
          -- for LSP related items. It sets the mode, buffer and description for us each time.
          local map = function(keys, func, desc, mode)
            mode = mode or 'n'
            vim.keymap.set(mode, keys, func, { buffer = event.buf, desc = 'LSP: ' .. desc })
          end

          -- Jump to the definition of the word under your cursor.
          --  This is where a variable was first declared, or where a function is defined, etc.
          --  To jump back, press <C-t>.
          --  tRPC-aware: when GTD lands at the aggregator (trpc/root.ts or
          --  .gen/trpc-types/), trpc_gtd narrows to the actual procedure.
          map('gd', function() require('custom.trpc_gtd').go() end, '[G]oto [D]efinition')

          -- Find references for the word under your cursor.
          map('gr', require('telescope.builtin').lsp_references, '[G]oto [R]eferences')

          -- Jump to the implementation of the word under your cursor.
          --  Useful when your language has ways of declaring types without an actual implementation.
          map('gI', require('telescope.builtin').lsp_implementations, '[G]oto [I]mplementation')

          -- Jump to the type of the word under your cursor.
          --  Useful when you're not sure what type a variable is and you want to see
          --  the definition of its *type*, not where it was *defined*.
          map('<leader>D', require('telescope.builtin').lsp_type_definitions, 'Type [D]efinition')

          -- Fuzzy find all the symbols in your current document.
          --  Symbols are things like variables, functions, types, etc.
          map('<leader>ds', require('telescope.builtin').lsp_document_symbols, '[D]ocument [S]ymbols')

          -- Fuzzy find all the symbols in your current workspace.
          --  Similar to document symbols, except searches over your entire project.
          map('<leader>ws', require('telescope.builtin').lsp_dynamic_workspace_symbols, '[W]orkspace [S]ymbols')

          -- Rename the variable under your cursor.
          --  Most Language Servers support renaming across files, etc.
          map('<leader>rn', vim.lsp.buf.rename, '[R]e[n]ame')

          -- Execute a code action, usually your cursor needs to be on top of an error
          -- or a suggestion from your LSP for this to activate.
          map('<leader>ca', vim.lsp.buf.code_action, '[C]ode [A]ction', { 'n', 'x' })

          -- WARN: This is not Goto Definition, this is Goto Declaration.
          --  For example, in C this would take you to the header.
          map('gD', vim.lsp.buf.declaration, '[G]oto [D]eclaration')
          map('<leader>gi', vim.diagnostic.open_float, '[G]oto [I]nfo (Diagnostics)')

          -- The following two autocommands are used to highlight references of the
          -- word under your cursor when your cursor rests there for a little while.
          --    See `:help CursorHold` for information about when this is executed
          --
          -- When you move your cursor, the highlights will be cleared (the second autocommand).
          local client = vim.lsp.get_client_by_id(event.data.client_id)
          if client and client.supports_method(vim.lsp.protocol.Methods.textDocument_documentHighlight) then
            local highlight_augroup = vim.api.nvim_create_augroup('kickstart-lsp-highlight', { clear = false })
            vim.api.nvim_create_autocmd({ 'CursorHold', 'CursorHoldI' }, {
              buffer = event.buf,
              group = highlight_augroup,
              callback = vim.lsp.buf.document_highlight,
            })

            vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI' }, {
              buffer = event.buf,
              group = highlight_augroup,
              callback = vim.lsp.buf.clear_references,
            })

            vim.api.nvim_create_autocmd('LspDetach', {
              group = vim.api.nvim_create_augroup('kickstart-lsp-detach', { clear = true }),
              callback = function(event2)
                vim.lsp.buf.clear_references()
                vim.api.nvim_clear_autocmds { group = 'kickstart-lsp-highlight', buffer = event2.buf }
              end,
            })
          end

          -- The following code creates a keymap to toggle inlay hints in your
          -- code, if the language server you are using supports them
          --
          -- This may be unwanted, since they displace some of your code
          if client and client.supports_method(vim.lsp.protocol.Methods.textDocument_inlayHint) then
            map('<leader>th', function()
              vim.lsp.inlay_hint.enable(not vim.lsp.inlay_hint.is_enabled { bufnr = event.buf })
            end, '[T]oggle Inlay [H]ints')
          end
        end,
      })

      -- Change diagnostic symbols in the sign column (gutter)
      -- if vim.g.have_nerd_font then
      --   local signs = { ERROR = '', WARN = '', INFO = '', HINT = '' }
      --   local diagnostic_signs = {}
      --   for type, icon in pairs(signs) do
      --     diagnostic_signs[vim.diagnostic.severity[type]] = icon
      --   end
      --   vim.diagnostic.config { signs = { text = diagnostic_signs } }
      -- end

      -- LSP servers and clients are able to communicate to each other what features they support.
      --  By default, Neovim doesn't support everything that is in the LSP specification.
      --  When you add nvim-cmp, luasnip, etc. Neovim now has *more* capabilities.
      --  So, we create new capabilities with nvim cmp, and then broadcast that to the servers.
      local capabilities = vim.lsp.protocol.make_client_capabilities()
      capabilities = vim.tbl_deep_extend('force', capabilities, require('cmp_nvim_lsp').default_capabilities())

      -- Enable the following language servers
      --  Feel free to add/remove any LSPs that you want here. They will automatically be installed.
      --
      --  Add any additional override configuration in the following tables. Available keys are:
      --  - cmd (table): Override the default command used to start the server
      --  - filetypes (table): Override the default list of associated filetypes for the server
      --  - capabilities (table): Override fields in capabilities. Can be used to disable certain LSP features.
      --  - settings (table): Override the default settings passed when initializing the server.
      --        For example, to see the options for `lua_ls`, you could go to: https://luals.github.io/wiki/settings/
      local servers = {
        -- clangd = {},
        -- gopls = {},
        -- pyright = {},
        -- rust_analyzer = {},
        -- ... etc. See `:help lspconfig-all` for a list of all the pre-configured LSPs
        --
        -- TypeScript is handled by tsgo (registered manually below) — not in mason.
        lua_ls = {
          -- cmd = { ... },
          -- filetypes = { ... },
          -- capabilities = {},
          settings = {
            Lua = {
              completion = {
                callSnippet = 'Replace',
              },
              -- You can toggle below to ignore Lua_LS's noisy `missing-fields` warnings
              -- diagnostics = { disable = { 'missing-fields' } },
            },
          },
        },
      }

      -- Ensure the servers and tools above are installed
      --
      -- To check the current status of installed tools and/or manually install
      -- other tools, you can run
      --    :Mason
      --
      -- You can press `g?` for help in this menu.
      --
      -- `mason` had to be setup earlier: to configure its options see the
      -- `dependencies` table for `nvim-lspconfig` above.
      --
      -- You can add other tools here that you want Mason to install
      -- for you, so that they are available from within Neovim.
      local ensure_installed = vim.tbl_keys(servers or {})
      vim.list_extend(ensure_installed, {
        'stylua', -- Used to format Lua code
      })
      require('mason-tool-installer').setup { ensure_installed = ensure_installed }

      require('mason-lspconfig').setup {
        handlers = {
          function(server_name)
            local server = servers[server_name] or {}
            -- This handles overriding only values explicitly passed
            -- by the server configuration above. Useful when disabling
            -- certain features of an LSP (for example, turning off formatting for ts_ls)
            server.capabilities = vim.tbl_deep_extend('force', {}, capabilities, server.capabilities or {})
            require('lspconfig')[server_name].setup(server)
          end,
        },
      }

      -- tsgo (TypeScript native preview). Install with `npm i -g @typescript/native-preview`.
      --
      -- Driven via vim.lsp.start directly, NOT lspconfig's manager. review-nvim is one
      -- warm instance that opens files across many git worktrees; lspconfig collapses
      -- them all onto a SINGLE tsgo client rooted wherever it first started (e.g. the
      -- main checkout), so a worktree's branch code gets type-checked against the wrong
      -- source tree and reads as stale/invisible. vim.lsp.start dedups per
      -- (name, root_dir), so each worktree gets its own tsgo — correct per-branch types.
      local lspconfig_util = require('lspconfig.util')
      local tsgo_root = lspconfig_util.root_pattern('tsconfig.json', 'jsconfig.json', 'package.json', '.git')

      -- Resolve tsgo to an ABSOLUTE path. When review-nvim is spawned outside an
      -- interactive shell (e.g. a tmux/launcher pane), ~/.volta/bin isn't on PATH, so a
      -- bare 'tsgo' fails to spawn ("not installed, missing from PATH"). Prefer PATH when
      -- it has it; else fall back to the volta-managed binary.
      local function resolve_tsgo()
        local p = vim.fn.exepath('tsgo')
        if p ~= '' then return p end
        for _, cand in ipairs({ '~/.volta/bin/tsgo', '~/.local/bin/tsgo' }) do
          local abs = vim.fn.expand(cand)
          if vim.fn.executable(abs) == 1 then return abs end
        end
        return 'tsgo' -- last resort; errors visibly if genuinely absent
      end
      local tsgo_bin = resolve_tsgo()

      -- LRU cap: per-worktree rooting means one tsgo per branch you open, and they do
      -- NOT auto-stop when buffers close — so a long review session would accumulate a
      -- tsgo (and its workers) per branch ever touched. Keep only the N most-recently-
      -- FOCUSED clients alive; stop the stalest. The active worktree is always freshest
      -- so it's never evicted; re-entering an evicted worktree respawns its tsgo (~1.5s).
      -- Each tsgo holds the whole program in memory (~0.5–1.2GB, file-dependent), so
      -- this N is a memory dial: 3 ≈ ~2–3GB ceiling (active branch + 2 recent). Raise it
      -- if you have RAM and bounce between many branches; lower it to 2 to stay lean.
      local TSGO_MAX = 3
      local tsgo_used = {} -- client_id -> focus tick
      local tsgo_tick = 0

      local function tsgo_on_screen(client)
        for _, buf in ipairs(vim.lsp.get_buffers_by_client_id(client.id)) do
          if vim.fn.bufwinid(buf) ~= -1 then
            return true
          end
        end
        return false
      end

      local function ensure_tsgo(buf)
        if not (buf and vim.api.nvim_buf_is_valid(buf)) then
          return
        end
        local fname = vim.api.nvim_buf_get_name(buf)
        if fname == '' then
          return
        end
        local root = tsgo_root(fname)
        if not root then
          return -- no project root → don't attach (no single-file fallback)
        end
        local id = vim.lsp.start({
          name = 'tsgo',
          cmd = { tsgo_bin, '--lsp', '-stdio' },
          root_dir = root,
          capabilities = capabilities,
        }, {
          bufnr = buf,
          -- exact-root reuse: one tsgo per worktree, never adopt a foreign root
          reuse_client = function(client, config)
            return client.name == config.name and client.config.root_dir == config.root_dir
          end,
        })
        if not id then
          return
        end
        tsgo_tick = tsgo_tick + 1
        tsgo_used[id] = tsgo_tick -- mark freshest

        -- evict stalest beyond the cap. The just-started client may not be in
        -- get_clients yet (still initializing), so count it explicitly and never evict
        -- it; also never evict a client whose buffer is currently on screen.
        -- Count only clients still considered live: tsgo_used is cleared on stop, and
        -- vim.lsp.stop_client is async (a stopping client lingers in get_clients), so
        -- filtering by tsgo_used excludes ones already on their way out. The just-started
        -- client may not be registered yet, so count it explicitly. Never evict it or a
        -- client whose buffer is currently on screen.
        local live = {}
        local found_new = false
        for _, c in ipairs(vim.lsp.get_clients { name = 'tsgo' }) do
          if tsgo_used[c.id] ~= nil then
            live[#live + 1] = c
            if c.id == id then
              found_new = true
            end
          end
        end
        local over = #live + (found_new and 0 or 1) - TSGO_MAX
        if over <= 0 then
          return
        end
        table.sort(live, function(a, b)
          return (tsgo_used[a.id] or 0) < (tsgo_used[b.id] or 0)
        end)
        for _, c in ipairs(live) do
          if over <= 0 then
            break
          end
          if c.id ~= id and not tsgo_on_screen(c) then
            vim.lsp.stop_client(c.id, true)
            tsgo_used[c.id] = nil
            over = over - 1
          end
        end
      end

      local ts_ft = {
        javascript = true,
        javascriptreact = true,
        ['javascript.jsx'] = true,
        typescript = true,
        typescriptreact = true,
        ['typescript.tsx'] = true,
      }
      local tsgo_grp = vim.api.nvim_create_augroup('tsgo-per-worktree', { clear = true })
      vim.api.nvim_create_autocmd('FileType', {
        group = tsgo_grp,
        pattern = vim.tbl_keys(ts_ft),
        callback = function(args)
          ensure_tsgo(args.buf)
        end,
      })
      -- re-mark recency on focus (and respawn tsgo if this buffer's worktree was evicted)
      vim.api.nvim_create_autocmd('BufEnter', {
        group = tsgo_grp,
        callback = function(args)
          if ts_ft[vim.bo[args.buf].filetype] then
            ensure_tsgo(args.buf)
          end
        end,
      })
    end,
  },

  { -- Autoformat
    'stevearc/conform.nvim',
    event = { 'BufWritePre' },
    cmd = { 'ConformInfo' },
    keys = {
      {
        '<leader>f',
        function()
          require('conform').format { async = true, lsp_format = 'fallback' }
        end,
        mode = '',
        desc = '[F]ormat buffer',
      },
    },
    opts = {
      notify_on_error = false,
      format_on_save = function(bufnr)
        -- Disable "format_on_save lsp_fallback" for languages that don't
        -- have a well standardized coding style. You can add additional
        -- languages here or re-enable it for the disabled ones.
        local disable_filetypes = { c = true, cpp = true }
        local lsp_format_opt
        if disable_filetypes[vim.bo[bufnr].filetype] then
          lsp_format_opt = 'never'
        else
          lsp_format_opt = 'fallback'
        end
        return {
          timeout_ms = 500,
          lsp_format = lsp_format_opt,
        }
      end,
      formatters_by_ft = {
        lua = { 'stylua' },
        -- Conform can also run multiple formatters sequentially
        -- python = { "isort", "black" },
        --
        -- You can use 'stop_after_first' to run the first available formatter from the list
        javascript = { 'oxfmt' },
        typescript = { 'oxfmt' },
        typescriptreact = { 'oxfmt' },
      },
    },
  },

  { -- Autocompletion
    'hrsh7th/nvim-cmp',
    event = 'InsertEnter',
    dependencies = {
      -- Snippet Engine & its associated nvim-cmp source
      {
        'L3MON4D3/LuaSnip',
        build = (function()
          -- Build Step is needed for regex support in snippets.
          -- This step is not supported in many windows environments.
          -- Remove the below condition to re-enable on windows.
          if vim.fn.has 'win32' == 1 or vim.fn.executable 'make' == 0 then
            return
          end
          return 'make install_jsregexp'
        end)(),
        dependencies = {
          -- `friendly-snippets` contains a variety of premade snippets.
          --    See the README about individual language/framework/plugin snippets:
          --    https://github.com/rafamadriz/friendly-snippets
          -- {
          --   'rafamadriz/friendly-snippets',
          --   config = function()
          --     require('luasnip.loaders.from_vscode').lazy_load()
          --   end,
          -- },
        },
      },
      'saadparwaiz1/cmp_luasnip',

      -- Adds other completion capabilities.
      --  nvim-cmp does not ship with all sources by default. They are split
      --  into multiple repos for maintenance purposes.
      'hrsh7th/cmp-nvim-lsp',
      'hrsh7th/cmp-path',
    },
    config = function()
      -- See `:help cmp`
      local cmp = require 'cmp'
      local luasnip = require 'luasnip'
      luasnip.config.setup {}

      cmp.setup {
        snippet = {
          expand = function(args)
            luasnip.lsp_expand(args.body)
          end,
        },
        completion = { completeopt = 'menu,menuone,noinsert' },

        -- For an understanding of why these mappings were
        -- chosen, you will need to read `:help ins-completion`
        --
        -- No, but seriously. Please read `:help ins-completion`, it is really good!
        mapping = cmp.mapping.preset.insert {
          -- Select the [n]ext item
          ['<C-n>'] = cmp.mapping.select_next_item(),
          -- Select the [p]revious item
          ['<C-p>'] = cmp.mapping.select_prev_item(),

          -- Scroll the documentation window [b]ack / [f]orward
          ['<C-b>'] = cmp.mapping.scroll_docs(-4),
          ['<C-f>'] = cmp.mapping.scroll_docs(4),

          -- Accept ([y]es) the completion.
          --  This will auto-import if your LSP supports it.
          --  This will expand snippets if the LSP sent a snippet.
          ['<C-y>'] = cmp.mapping.confirm { select = true },

          -- If you prefer more traditional completion keymaps,
          -- you can uncomment the following lines
          --['<CR>'] = cmp.mapping.confirm { select = true },
          --['<Tab>'] = cmp.mapping.select_next_item(),
          --['<S-Tab>'] = cmp.mapping.select_prev_item(),

          -- Manually trigger a completion from nvim-cmp.
          --  Generally you don't need this, because nvim-cmp will display
          --  completions whenever it has completion options available.
          ['<C-Space>'] = cmp.mapping.complete {},

          -- TODO
          --
          -- Think of <c-l> as moving to the right of your snippet expansion.
          --  So if you have a snippet that's like:
          --  function $name($args)
          --    $body
          --  end
          --
          -- <c-l> will move you to the right of each of the expansion locations.
          -- <c-h> is similar, except moving you backwards.
          ['<C-l>'] = cmp.mapping(function()
            if luasnip.expand_or_locally_jumpable() then
              luasnip.expand_or_jump()
            end
          end, { 'i', 's' }),
          ['<C-h>'] = cmp.mapping(function()
            if luasnip.locally_jumpable(-1) then
              luasnip.jump(-1)
            end
          end, { 'i', 's' }),

          -- For more advanced Luasnip keymaps (e.g. selecting choice nodes, expansion) see:
          --    https://github.com/L3MON4D3/LuaSnip?tab=readme-ov-file#keymaps
        },
        sources = {
          {
            name = 'lazydev',
            -- set group index to 0 to skip loading LuaLS completions as lazydev recommends it
            group_index = 0,
          },
          { name = 'nvim_lsp' },
          { name = 'luasnip' },
          { name = 'path' },
        },
      }
    end,
  },

  { -- You can easily change to a different colorscheme.
    -- Change the name of the colorscheme plugin below, and then
    -- change the command in the config to whatever the name of that colorscheme is.
    --
    -- If you want to see what colorschemes are already installed, you can use `:Telescope colorscheme`.
    'folke/tokyonight.nvim',
    priority = 1000, -- Make sure to load this before all the other start plugins.
    init = function()
      -- Load the colorscheme here.
      -- Like many other themes, this one has different styles, and you could load
      -- any other, such as 'tokyonight-storm', 'tokyonight-moon', or 'tokyonight-day'.
      vim.cmd.colorscheme 'habamax'

      -- You can configure highlights by doing something like:
      vim.cmd.hi 'Comment gui=none'
      vim.api.nvim_set_hl(0, 'CursorLine', { bg = '#3d3d3d' })
      vim.api.nvim_set_hl(0, 'CursorLineNr', { fg = '#ffcc00', bold = true })
    end,
  },

  -- Highlight todo, notes, etc in comments
  { 'folke/todo-comments.nvim', event = 'VimEnter', dependencies = { 'nvim-lua/plenary.nvim' }, opts = { signs = false } },

  { -- Collection of various small independent plugins/modules
    'echasnovski/mini.nvim',
    config = function()
      -- Better Around/Inside textobjects
      --
      -- Examples:
      --  - va)  - [V]isually select [A]round [)]paren
      --  - yinq - [Y]ank [I]nside [N]ext [Q]uote
      --  - ci'  - [C]hange [I]nside [']quote
      local ai = require 'mini.ai'
      ai.setup {
        n_lines = 500,
        custom_textobjects = {
          -- `c` = a comment block (e.g. JSDoc /** ... */), via the @comment.outer
          -- treesitter query. Makes dac/cac/vac/yac work in JS/TS. mini.ai owns a/i,
          -- so the old nvim-treesitter-textobjects `['ac']` keymap never fired (and
          -- that plugin is pinned to its rewritten `main` branch anyway) — register it
          -- here instead so it goes through the engine that actually handles a/i.
          c = ai.gen_spec.treesitter { a = '@comment.outer', i = '@comment.outer' },
        },
      }

      -- Add/delete/replace surroundings (brackets, quotes, etc.)
      -- - ssaiw) - [S]urround [A]dd [I]nner [W]ord [)]Paren
      -- - ssd'   - [S]urround [D]elete [']quotes
      -- - ssr)'  - [S]urround [R]eplace [)] [']
      require('mini.surround').setup({
        mappings = {
          add = 'ssa',
          delete = 'ssd',
          replace = 'ssr',
          find = 'ssf',
          find_left = 'ssF',
          highlight = 'ssh',
          update_n_lines = 'ssn',
        },
      })

      -- Simple and easy statusline.
      --  You could remove this setup call if you don't like it,
      --  and try some other statusline plugin
      local statusline = require 'mini.statusline'
      -- set use_icons to true if you have a Nerd Font
      statusline.setup { use_icons = vim.g.have_nerd_font }

      -- You can configure sections in the statusline by overriding their
      -- default behavior. For example, here we set the section for
      -- cursor location to LINE:COLUMN
      ---@diagnostic disable-next-line: duplicate-set-field
      statusline.section_location = function()
        return '%2l:%-2v'
      end

      -- ... and there is more!
      --  Check out: https://github.com/echasnovski/mini.nvim
    end,
  },
  { -- Highlight, edit, and navigate code
    'nvim-treesitter/nvim-treesitter',
    build = ':TSUpdate',
    dependencies = {
      -- pin to `master`: it's the branch whose API integrates via
      -- `nvim-treesitter.configs.setup{ textobjects = … }` (matching core, also on
      -- master). The default `main` branch is a rewrite that ignores that config.
      { 'nvim-treesitter/nvim-treesitter-textobjects', branch = 'master' },
    },
    config = function()
      -- [[ Configure Treesitter ]] See `:help nvim-treesitter`
      require('nvim-treesitter.configs').setup {
        ensure_installed = { 'bash', 'c', 'diff', 'html', 'lua', 'luadoc', 'markdown', 'markdown_inline', 'query', 'vim', 'vimdoc' },
        -- Autoinstall languages that are not installed
        auto_install = true,
        highlight = {
          enable = true,
          -- Some languages depend on vim's regex highlighting system (such as Ruby) for indent rules.
          --  If you are experiencing weird indenting issues, add the language to
          --  the list of additional_vim_regex_highlighting and disabled languages for indent.
          additional_vim_regex_highlighting = { 'ruby' },
        },
        indent = { enable = true, disable = { 'ruby' } },
        -- NB: comment textobjects (dac/cac/vac/yac for /** … */) are owned by
        -- mini.ai's custom `c` object (see its setup), not by a textobjects.select
        -- block here — mini.ai owns a/i, so a select keymap would just shadow-conflict.
      }

      -- Navigate between function declarations (skipping callback arrow functions)
      -- Matches: function_declaration, method_definition, and top-level const arrow functions
      local function is_toplevel_arrow(node)
        -- Match: arrow_function -> variable_declarator -> lexical_declaration
        if node:type() ~= 'arrow_function' then return false end
        local body = nil
        for child in node:iter_children() do
          if child:type() == 'statement_block' then body = child; break end
        end
        if not body then return false end -- skip single-expression arrows like `x => x + 1`
        local parent = node:parent()
        if not parent or parent:type() ~= 'variable_declarator' then return false end
        local grandparent = parent:parent()
        if not grandparent then return false end
        local gtype = grandparent:type()
        return gtype == 'lexical_declaration' or gtype == 'variable_declaration'
      end

      local function is_function_node(node)
        local ntype = node:type()
        if ntype == 'function_declaration' or ntype == 'method_definition' then return true end
        return is_toplevel_arrow(node)
      end

      -- Get the outermost wrapping node for navigation (export_statement or lexical_declaration)
      local function get_outer_node(node)
        local target = node
        local parent = node:parent()
        if parent and parent:type() == 'variable_declarator' then
          parent = parent:parent() -- lexical_declaration
          if parent then target = parent end
        end
        if parent and parent:type() == 'export_statement' then
          target = parent
        elseif target:parent() and target:parent():type() == 'export_statement' then
          target = target:parent()
        end
        return target
      end

      local function find_function_node(forward, goto_end)
        local bufnr = vim.api.nvim_get_current_buf()
        local parser = vim.treesitter.get_parser(bufnr)
        if not parser then return end
        parser:parse(true)

        local row, col = unpack(vim.api.nvim_win_get_cursor(0))
        row = row - 1 -- 0-indexed

        local best_row, best_col

        parser:for_each_tree(function(tree)
          local function walk(node)
            if is_function_node(node) then
              local outer = get_outer_node(node)
              local sr, sc, er, ec = outer:range()
              local tr, tc = sr, sc
              if goto_end then tr, tc = er, ec > 0 and ec - 1 or 0 end
              if forward then
                if tr > row or (tr == row and tc > col) then
                  if not best_row or tr < best_row or (tr == best_row and tc < best_col) then
                    best_row, best_col = tr, tc
                  end
                end
              else
                if tr < row or (tr == row and tc < col) then
                  if not best_row or tr > best_row or (tr == best_row and tc > best_col) then
                    best_row, best_col = tr, tc
                  end
                end
              end
              return -- don't recurse into function bodies
            end
            for child in node:iter_children() do
              walk(child)
            end
          end
          walk(tree:root())
        end)

        if best_row then
          vim.cmd("normal! m'")
          vim.api.nvim_win_set_cursor(0, { best_row + 1, best_col })
        end
      end

      local function select_function(outer)
        local bufnr = vim.api.nvim_get_current_buf()
        local parser = vim.treesitter.get_parser(bufnr)
        if not parser then return end
        parser:parse(true)

        local row, col = unpack(vim.api.nvim_win_get_cursor(0))
        row = row - 1

        local best_node, best_len

        parser:for_each_tree(function(tree)
          local function walk(node)
            if is_function_node(node) then
              local check = get_outer_node(node)
              local sr, _, er, _ = check:range()
              if row >= sr and row <= er then
                local len = er - sr
                if not best_len or len < best_len then
                  best_node = node
                  best_len = len
                end
              end
              return
            end
            for child in node:iter_children() do
              walk(child)
            end
          end
          walk(tree:root())
        end)

        if best_node then
          local target = outer and get_outer_node(best_node) or best_node
          local sr, sc, er, ec = target:range()
          -- For 'if', select just the body
          if not outer then
            for child in best_node:iter_children() do
              if child:type() == 'statement_block' then
                sr, sc, er, ec = child:range()
                sc = sc + 1
                ec = ec - 1
                break
              end
            end
          end
          vim.api.nvim_win_set_cursor(0, { sr + 1, sc })
          local mode = vim.api.nvim_get_mode().mode
          if mode ~= 'v' and mode ~= 'V' then vim.cmd('normal! v') end
          vim.api.nvim_win_set_cursor(0, { er + 1, math.max(ec - 1, 0) })
        end
      end

      vim.keymap.set({ 'n', 'x', 'o' }, ']f', function() find_function_node(true, false) end, { desc = 'Next function start' })
      vim.keymap.set({ 'n', 'x', 'o' }, '[f', function() find_function_node(false, false) end, { desc = 'Prev function start' })
      vim.keymap.set({ 'n', 'x', 'o' }, ']F', function() find_function_node(true, true) end, { desc = 'Next function end' })
      vim.keymap.set({ 'n', 'x', 'o' }, '[F', function() find_function_node(false, true) end, { desc = 'Prev function end' })
      vim.keymap.set({ 'x', 'o' }, 'af', function() select_function(true) end, { desc = 'around function' })
      vim.keymap.set({ 'x', 'o' }, 'if', function() select_function(false) end, { desc = 'inside function' })
    end,
  },

  -- The following comments only work if you have downloaded the kickstart repo, not just copy pasted the
  -- init.lua. If you want these files, they are in the repository, so you can just download them and
  -- place them in the correct locations.

  -- NOTE: Next step on your Neovim journey: Add/Configure additional plugins for Kickstart
  --
  --  Here are some example plugins that I've included in the Kickstart repository.
  --  Uncomment any of the lines below to enable them (you will need to restart nvim).
  --
  -- require 'kickstart.plugins.debug',
  -- require 'kickstart.plugins.indent_line',
  require 'kickstart.plugins.lint',
  -- require 'kickstart.plugins.autopairs',
  -- require 'kickstart.plugins.neo-tree',
  -- require 'kickstart.plugins.gitsigns', -- adds gitsigns recommend keymaps

  -- NOTE: The import below can automatically add your own plugins, configuration, etc from `lua/custom/plugins/*.lua`
  --    This is the easiest way to modularize your config.
  --
  --  Uncomment the following line and add your plugins to `lua/custom/plugins/*.lua` to get going.
  { import = 'custom.plugins' },
  --
  -- For additional information with loading, sourcing and examples see `:help lazy.nvim-🔌-plugin-spec`
  -- Or use telescope!
  -- In normal mode type `<space>sh` then write `lazy.nvim-plugin`
  -- you can continue same window with `<space>sr` which resumes last telescope search
}, {
  change_detection = {
    enabled = true,
    notify = true,
  },
  ui = {
    -- If you are using a Nerd Font: set icons to an empty table which will use the
    -- default lazy.nvim defined Nerd Font icons, otherwise define a unicode icons table
    icons = vim.g.have_nerd_font and {} or {
      cmd = '⌘',
      config = '🛠',
      event = '📅',
      ft = '📂',
      init = '⚙',
      keys = '🗝',
      plugin = '🔌',
      runtime = '💻',
      require = '🌙',
      source = '📄',
      start = '🚀',
      task = '📌',
      lazy = '💤 ',
    },
  },
})

require('custom.wc') -- :wc / :Wc — write + commit the current file (ledger review loop)
require('custom.submit') -- :submit / :Submit — hand a design doc back to the Claude session

-- The line beneath this is called `modeline`. See `:help modeline`
-- vim: ts=2 sts=2 sw=2 et
