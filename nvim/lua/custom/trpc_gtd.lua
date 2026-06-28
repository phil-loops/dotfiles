-- trpc_gtd: LSP-backend-agnostic "go to procedure" for tRPC chains.
--
-- Problem: GTD on `api.<router>.<procedure>` lands on the flattened pre-built
-- type (either `.gen/trpc-types/**/root.d.ts` or — via declarationMap — the
-- bottom of `trpc/root.ts`).
--
-- Approach:
--   1. Extract the chain at cursor via treesitter:
--        ['loops', 'getLoop']  or  ['audienceSegments', 'duplicateSegment']
--   2. Make the normal LSP definition request. If it lands at an aggregator
--      (trpc/root.ts or .gen/trpc-types/), narrow the search to the router's
--      directory/file and use treesitter to find:
--        - `export const <procedure>` (per-procedure file pattern), or
--        - `<procedure>: ...` inside a `createTRPCRouter({...})` (inline)
--   3. Otherwise behave like normal GTD.

local M = {}

local AGGREGATOR_PATTERNS = {
  '%.gen/trpc%-types/',
  '/trpc/root%.ts$',
}

local CHAIN_ROOTS = { api = true, trpc = true }
local CHAIN_PASSTHROUGH = { useUtils = true, useContext = true }

local function looks_prebuilt(loc)
  local uri = loc.uri or loc.targetUri
  if not uri then return false end
  for _, p in ipairs(AGGREGATOR_PATTERNS) do
    if uri:match(p) then return true end
  end
  return false
end

local function project_root(bufnr)
  local fname = vim.api.nvim_buf_get_name(bufnr)
  if fname == '' then return vim.fn.getcwd() end
  local found = vim.fs.find({ '.git', 'package.json' }, {
    path = fname,
    upward = true,
    stop = vim.loop.os_homedir(),
  })[1]
  if not found then return vim.fn.getcwd() end
  return vim.fs.dirname(found)
end

local function to_kebab(camel)
  return (camel:gsub('([a-z0-9])([A-Z])', '%1-%2'):gsub('([A-Z])([A-Z][a-z])', '%1-%2')):lower()
end

-- Climb to the topmost member_expression in the access chain at the cursor,
-- then collect names from left to right. Passes through call_expressions
-- (so `a.b().c.d` still yields {a, b, c, d}). Truncates the chain at the
-- cursor's own segment, so `api.foo.bar.useMutation` with cursor on `bar`
-- yields {foo, bar}.
local function extract_chain(bufnr)
  local ok, cursor_node = pcall(vim.treesitter.get_node, { bufnr = bufnr })
  if not ok or not cursor_node then return nil end

  -- Capture the cursor's own segment text (typically a property_identifier
  -- or identifier). Used to truncate trailing chain segments later.
  local cursor_seg
  if cursor_node:type() == 'property_identifier' or cursor_node:type() == 'identifier' then
    cursor_seg = vim.treesitter.get_node_text(cursor_node, bufnr)
  end

  local node = cursor_node
  while node and node:type() ~= 'member_expression' do
    node = node:parent()
  end
  if not node then return nil end

  while node:parent() do
    local p = node:parent()
    if p:type() == 'member_expression' then
      node = p
    elseif p:type() == 'call_expression' and p:field('function')[1] == node then
      local pp = p:parent()
      if pp and pp:type() == 'member_expression' then
        node = pp
      else
        break
      end
    else
      break
    end
  end

  local parts = {}
  local function collect(n)
    if not n then return end
    local t = n:type()
    if t == 'member_expression' then
      collect(n:field('object')[1])
      local prop = n:field('property')[1]
      if prop then table.insert(parts, vim.treesitter.get_node_text(prop, bufnr)) end
    elseif t == 'call_expression' then
      collect(n:field('function')[1])
    elseif t == 'identifier' or t == 'property_identifier' then
      table.insert(parts, vim.treesitter.get_node_text(n, bufnr))
    end
  end
  collect(node)

  if #parts < 2 then return nil end
  if not CHAIN_ROOTS[parts[1]] then return nil end

  -- Truncate to cursor's segment if it appears in the chain. This handles
  -- `api.foo.bar.useMutation` where cursor on `bar` should yield {foo, bar},
  -- not {foo, bar, useMutation}.
  if cursor_seg then
    for i = #parts, 1, -1 do
      if parts[i] == cursor_seg then
        for _ = i + 1, #parts do table.remove(parts) end
        break
      end
    end
  end

  local trimmed = {}
  for i = 2, #parts do
    if not CHAIN_PASSTHROUGH[parts[i]] then table.insert(trimmed, parts[i]) end
  end
  if #trimmed < 2 then return nil end
  return trimmed
end

-- ── AST search ─────────────────────────────────────────────────────────────

-- Read a file's contents.
local function read_file(path)
  local f = io.open(path, 'r')
  if not f then return nil end
  local s = f:read('*a')
  f:close()
  return s
end

-- Parse `source` with the typescript treesitter parser.
local function parse_ts(source)
  local ok, parser = pcall(vim.treesitter.get_string_parser, source, 'typescript')
  if not ok or not parser then return nil end
  local trees = parser:parse()
  return trees and trees[1] or nil
end

-- Byte offset (0-indexed) to {row, col} (1-indexed row, 0-indexed col).
local function offset_to_pos(source, byte_offset)
  local row, line_start = 1, 0
  for i = 1, byte_offset do
    if source:sub(i, i) == '\n' then
      row = row + 1
      line_start = i
    end
  end
  return row, byte_offset - line_start
end

-- Find `export const <symbol>` or `<symbol>:` inside a `createTRPCRouter({...})`
-- argument object. Returns { file, line, col } or nil.
local function ast_find_in_file(path, symbol)
  local source = read_file(path)
  if not source then return nil end
  local tree = parse_ts(source)
  if not tree then return nil end
  local root = tree:root()

  -- Query 1: top-level `export const <name> = ...`
  local q_export = vim.treesitter.query.parse('typescript', [[
    (export_statement
      (lexical_declaration
        (variable_declarator
          name: (identifier) @name)))
  ]])
  for _, node, _ in q_export:iter_captures(root, source) do
    if vim.treesitter.get_node_text(node, source) == symbol then
      local start_byte, _ = node:start(), node:end_()
      local sb = select(3, node:start())
      local row, col = offset_to_pos(source, sb)
      return { file = path, line = row, col = col }
    end
  end

  -- Query 2: pair `<name>: <something>` inside a createTRPCRouter({...}) call
  local q_pair = vim.treesitter.query.parse('typescript', [[
    (call_expression
      function: (identifier) @fn (#eq? @fn "createTRPCRouter")
      arguments: (arguments
        (object
          (pair
            key: [(property_identifier) (string)] @key))))
  ]])
  for id, node, _ in q_pair:iter_captures(root, source) do
    local name = q_pair.captures[id]
    if name == 'key' then
      local text = vim.treesitter.get_node_text(node, source)
      -- strings come with surrounding quotes; strip them
      local key = text:gsub('^["\']', ''):gsub('["\']$', '')
      if key == symbol then
        local sb = select(3, node:start())
        local row, col = offset_to_pos(source, sb)
        return { file = path, line = row, col = col }
      end
    end
  end

  return nil
end

-- Recursively list .ts files (skipping tests + obvious noise dirs).
local function list_ts_files(dir)
  local out = {}
  local function walk(d)
    local handle = vim.loop.fs_scandir(d)
    if not handle then return end
    while true do
      local name, type_ = vim.loop.fs_scandir_next(handle)
      if not name then break end
      local full = d .. '/' .. name
      if type_ == 'file' then
        if name:sub(-3) == '.ts' and not name:match('%.test%.ts$') then
          table.insert(out, full)
        end
      elseif type_ == 'directory' and name ~= 'node_modules' and name ~= '.gen' then
        walk(full)
      end
    end
  end
  walk(dir)
  return out
end

-- Resolve a chain to a procedure location by:
--   1. narrowing the search to a router subdir/file using the chain segments
--   2. preferring a kebab-named file matching the procedure
--   3. otherwise scanning each .ts in the narrowed scope with treesitter
local function resolve_chain(root, chain)
  local symbol = chain[#chain]
  if not symbol or symbol:match('[^%w_]') then return nil end

  local routers_dir = root .. '/trpc/routers'
  if vim.fn.isdirectory(routers_dir) == 0 then return nil end

  -- Walk router segments to narrow the path; collect candidate scopes
  -- (most-narrowed first). Both `<seg>.ts` and `<seg>/` can exist (e.g.
  -- `contacts.ts` is the router, `contacts/` is a sibling dir of helpers);
  -- include both, sibling file first since it's the common "router-as-file"
  -- pattern, then descend into the subdir for the next segment.
  local scopes = {}
  local cur = routers_dir
  for i = 1, #chain - 1 do
    local seg = to_kebab(chain[i])
    local subdir = cur .. '/' .. seg
    local subfile = cur .. '/' .. seg .. '.ts'
    local has_dir = vim.fn.isdirectory(subdir) == 1
    local has_file = vim.fn.filereadable(subfile) == 1
    -- Insert dir first, then file second so file ends up at index 1
    -- (highest priority — sibling file is the common "router-as-file" case).
    if has_dir then
      table.insert(scopes, 1, { kind = 'dir', path = subdir })
      cur = subdir
    end
    if has_file then
      table.insert(scopes, 1, { kind = 'file', path = subfile })
    end
    if not has_dir and not has_file then break end
    if not has_dir then break end
  end
  table.insert(scopes, { kind = 'dir', path = routers_dir })

  local symbol_kebab = to_kebab(symbol)
  for _, scope in ipairs(scopes) do
    local files = {}
    if scope.kind == 'file' then
      files = { scope.path }
    else
      -- Prefer the per-procedure file if it exists
      local preferred = scope.path .. '/' .. symbol_kebab .. '.ts'
      if vim.fn.filereadable(preferred) == 1 then
        table.insert(files, preferred)
      end
      for _, f in ipairs(list_ts_files(scope.path)) do
        if f ~= preferred then table.insert(files, f) end
      end
    end
    for _, f in ipairs(files) do
      local hit = ast_find_in_file(f, symbol)
      if hit then return hit end
    end
  end
  return nil
end

-- ── Main entry ─────────────────────────────────────────────────────────────

local function jump_to(target)
  vim.cmd('normal! m`')   -- drop a jumplist mark so <C-o> comes back
  -- Switch via the buffer API, not `:edit` — `:edit` throws E37 ("No write since last
  -- change") when the current buffer has unsaved edits, and reloads (also E37) when the
  -- target IS the current file. nvim_win_set_buf just hides the modified buffer instead.
  local buf = vim.fn.bufadd(target.file)
  vim.fn.bufload(buf)
  vim.api.nvim_win_set_buf(0, buf)
  vim.api.nvim_win_set_cursor(0, { target.line, target.col })
end

function M.go()
  local bufnr = vim.api.nvim_get_current_buf()
  local params = vim.lsp.util.make_position_params(0, 'utf-8')
  local chain = extract_chain(bufnr)

  vim.lsp.buf_request(bufnr, 'textDocument/definition', params, function(err, result)
    if err or not result or (type(result) == 'table' and vim.tbl_isempty(result)) then
      vim.notify('[trpc_gtd] no definition', vim.log.levels.WARN)
      return
    end

    local locs = (vim.islist and vim.islist(result)) and result or { result }
    local first = locs[1]

    if chain and looks_prebuilt(first) then
      local target = resolve_chain(project_root(bufnr), chain)
      if target then
        jump_to(target)
        return
      end
      vim.notify(
        ('[trpc_gtd] no procedure found for %s'):format(table.concat(chain, '.')),
        vim.log.levels.INFO
      )
    end

    local path = first.uri and vim.uri_to_fname(first.uri)
      or first.targetUri and vim.uri_to_fname(first.targetUri)
    local range = first.range or first.targetSelectionRange or first.targetRange
    if path and range then
      jump_to({ file = path, line = range.start.line + 1, col = range.start.character })
    end
  end)
end

function M.setup(opts)
  opts = opts or {}
  local lhs = opts.keymap or 'gd'
  vim.keymap.set('n', lhs, M.go, { desc = '[G]oto [D]efinition (tRPC-aware)' })
end

-- Internals exposed for testing.
M._extract_chain = extract_chain
M._resolve_chain = resolve_chain
M._ast_find_in_file = ast_find_in_file

return M
