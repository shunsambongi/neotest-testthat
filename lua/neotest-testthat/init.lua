local async = require 'neotest.async'
local Path = require 'plenary.path'
local lib = require 'neotest.lib'

-- plenary maps r to rebol by default
require('plenary.filetype').add_file 'r'

local script_path = function()
  local str = debug.getinfo(2, 'S').source:sub(2)
  return str:match '(.*/)'
end

local script = (Path.new(script_path()):parent():parent() / 'neotest.R').filename

local normalize_path = function(path)
  local normal = path:gsub('\\', '/')
  if normal:find '^~' then
    normal = vim.env.HOME .. normal:sub(2)
  end
  return normal
end

---@type neotest.Adapter
local TestthatNeotestAdapter = { name = 'neotest-testthat' }

TestthatNeotestAdapter.root = lib.files.match_root_pattern 'DESCRIPTION'

---@return boolean
TestthatNeotestAdapter.is_test_file = function(file_path)
  file_path = normalize_path(file_path)
  return file_path:match 'tests/testthat/test.*%.[rR]$'
end

---@async
---@return neotest.Tree | nil
TestthatNeotestAdapter.discover_positions = function(file_path)
  local query = [[
    (
      (call
        function: (identifier) @func_name
        arguments: (arguments (_) @test.name (_))) 
      (#match? @func_name "^(test_that|it)$")
    ) @test.definition

    (
      (call
        function: (namespace_get
          namespace: (identifier) @pkg_name
          function: (identifier) @func_name) 
        arguments: (arguments (_) @test.name (_))) 
      (#match? @pkg_name "^testthat$")
      (#match? @func_name "^(test_that|it)$")
    ) @test.definition

    (
      (call
        function: (identifier) @func_name
        arguments: (arguments (_) @namespace.name (_))) 
      (#match? @func_name "^describe$")
    ) @namespace.definition

    (
      (call
        function: (namespace_get
          namespace: (identifier) @pkg_name
          function: (identifier) @func_name) 
        arguments: (arguments (_) @namespace.name (_))) 
      (#match? @pkg_name "^testthat$")
      (#match? @func_name "^describe$")
    ) @namespace.definition
  ]]
  return lib.treesitter.parse_positions(file_path, query, {})
end

local prune_test = function(lines, position)
  local start_line = position.range[1] + 1
  local end_line = position.range[3] + 1

  if start_line == end_line then
    lines[start_line] = string.sub(lines[start_line], position.range[2] + 1, position.range[4])
    return
  end

  lines[start_line] = string.sub(lines[start_line], 1, position.range[2])
  lines[end_line] = string.sub(lines[end_line], position.range[4] + 1, #lines[end_line])

  if end_line - start_line == 1 then
    return
  end

  for i = start_line + 1, end_line - 1 do
    lines[i] = ''
  end
end

local write_temp_test_file = function(file_path, content)
  local open_err, file_fd = async.uv.fs_open(file_path, 'w', 438)
  assert(not open_err, open_err)
  local write_err, _ = async.uv.fs_write(file_fd, content)
  assert(not write_err, write_err)
  local close_err = async.uv.fs_close(file_fd)
  assert(not close_err, close_err)
end

---@param args neotest.RunArgs
---@param keep_node fun(node: neotest.Tree): boolean
local generate_pruned_test_file = function(args, keep_node)
  local position = args.tree:data()

  local file
  for parent in args.tree:iter_parents() do
    if parent:data().path == position.path then
      file = parent
    end
  end

  local lines = lib.files.read_lines(position.path)

  for _, node in file:iter_nodes() do
    local node_position = node:data()
    if node_position.type == 'test' and not keep_node(node) then
      prune_test(lines, node_position)
    end
  end

  local tmp = async.fn.tempname()
  local content = table.concat(lines, '\n')

  write_temp_test_file(tmp, content)

  return tmp
end

---@async
---@param args neotest.RunArgs
---@return neotest.RunSpec
TestthatNeotestAdapter.build_spec = function(args)
  local position = args.tree:data()
  local path = position.path

  if position.type == 'test' then
    path = generate_pruned_test_file(args, function(node)
      return node:data().id == position.id
    end)
  elseif position.type == 'namespace' then
    path = generate_pruned_test_file(args, function(node)
      for parent in node:iter_parents() do
        if parent:data().id == position.id then
          return true
        end
      end
      return false
    end)
  end

  local lookup = {}
  for _, node in args.tree:iter() do
    if node.type == 'test' then
      lookup[node.path] = lookup[node.path] or {}
      lookup[node.path][node.id] = node.range[1] + 1 -- convert to 1-indexed line number
    end
  end

  local out = async.fn.tempname()

  -- stylua: ignore
  local script_args = {
    '--type', position.type,
    '--root', TestthatNeotestAdapter.root(position.path),
    '--path', path,
    '--realpath', position.path,
    '--out', out,
    '--lookup', vim.json.encode(lookup),
  }

  local command = vim.tbl_flatten { 'Rscript', '--vanilla', script, script_args }

  return {
    command = command,
    context = { out = out },
  }
end

---@async
---@param spec neotest.RunSpec
---@param result neotest.StrategyResult
---@param tree neotest.Tree
---@return table<string, neotest.Result>
TestthatNeotestAdapter.results = function(spec, result, tree)
  local ok, data = pcall(lib.files.read, spec.context.out)
  if not ok then
    data = '{}'
  end

  local results = vim.json.decode(data, { luanil = { object = true } })
  return results
end

return TestthatNeotestAdapter
