local async = require 'neotest.async'
local Path = require 'plenary.path'
local lib = require 'neotest.lib'

-- plenary maps r to rebol by default
require('plenary.filetype').add_file 'r'

local script_path = function()
  local str = debug.getinfo(2, 'S').source:sub(2)
  return str:match '(.*/)'
end

local script = (Path.new(script_path()):parent():parent() / 'R' / 'run.R').filename

local normalize_path = function(path)
  local normal = path:gsub('\\', '/')
  if normal:find '^~' then
    normal = vim.env.HOME .. normal:sub(2)
  end
  return normal
end

---@type neotest.Adapter
local RNeotestAdapter = { name = 'neotest-r' }

RNeotestAdapter.root = lib.files.match_root_pattern 'DESCRIPTION'

---@return boolean
RNeotestAdapter.is_test_file = function(file_path)
  file_path = normalize_path(file_path)
  return file_path:match 'tests/testthat/test.*%.[rR]$'
end

---@async
---@return neotest.Tree | nil
RNeotestAdapter.discover_positions = function(file_path)
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
  return lib.treesitter.parse_positions(file_path, query, {
    -- position_id = function(position, namespaces)
    --   id = position.path .. ':' .. position.range[1]
    --   print(id)
    --   return id
    -- end,
    -- nested_namespaces = true,

    -- position_id = function(position, namespaces)
    --   local id = table.concat(
    --     vim.tbl_flatten({
    --       position.path,
    --       vim.tbl_map(function(pos)
    --         return pos.name
    --       end, namespaces),
    --       position.name,
    --     }),
    --     "::"
    --   )
    --   print(id)
    --   return id
    -- end,
  })
end

---@async
---@param args neotest.RunArgs
---@return neotest.RunSpec
RNeotestAdapter.build_spec = function(args)
  local position = args.tree:data()

  local lookup = {}
  for _, node in args.tree:iter() do
    if node.type == 'test' then
      if not lookup[node.path] then
        lookup[node.path] = {}
      end

      lookup[node.path][node.id] = node.range[1] + 1 -- 1-indexed line number
    end
  end

  local out = async.fn.tempname()

  local script_args = {
    '--type',
    position.type,
    '--path',
    position.path,
    '--out',
    out,
    '--lookup',
    vim.json.encode(lookup),
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
RNeotestAdapter.results = function(spec, result, tree)
  local ok, data = pcall(lib.files.read, spec.context.out)
  if not ok then
    data = '{}'
  end

  local results = vim.json.decode(data, { luanil = { object = true } })

  return results
end

return RNeotestAdapter
