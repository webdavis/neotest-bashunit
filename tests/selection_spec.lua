local adapter = require("neotest-bashunit")
local parse = require("neotest-bashunit.parse")

local function fixture(names)
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, "p")
  local path = root .. "/selection.test.sh"
  local lines = {}
  for _, name in ipairs(names) do
    lines[#lines + 1] = ("function %s() { assert_same 1 1; }"):format(name)
  end
  vim.fn.writefile(lines, path)
  vim.fn.writefile({}, root .. "/.bashunitrc")
  local positions = parse.positions(path, lines)
  local nodes, file, by_name = {}, {}, {}
  function file.data()
    return positions[1]
  end
  function file.iter_nodes()
    return ipairs(nodes)
  end
  nodes[1] = file
  for i = 2, #positions do
    local position, node = positions[i], {}
    function node.data()
      return position
    end
    function node.parent()
      return file
    end
    function node:iter_nodes()
      return ipairs({ self })
    end
    nodes[#nodes + 1] = node
    by_name[names[i - 1]] = node
  end
  return file, by_name, root
end

local function run(tree, args)
  args = vim.tbl_extend("force", args or {}, { tree = tree })
  local spec = assert(adapter.build_spec(args))
  local result = vim.system(spec.command, { cwd = args.cwd or spec.cwd, env = spec.env, text = true }):wait(1000)
  assert(result.code == 0, result.stdout .. result.stderr)
  local report = vim.json.decode(table.concat(vim.fn.readfile(spec.context.report), "\n"))
  local output = vim.fn.tempname()
  vim.fn.writefile(vim.split(result.stdout .. result.stderr, "\n"), output)
  return report.tests, adapter.results(spec, { output = output }, tree)
end

local function one_test(tree, title, args)
  local rows, results = run(tree, args)
  assert(#rows == 1, "expected exactly one raw row, got " .. #rows)
  assert(rows[1].name == title and rows[1].status == "passed", vim.inspect(rows))
  assert(results[tree:data().id].status == "passed", vim.inspect(results))
end

local function unverified_build(tree)
  local original = vim.env.PATH
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, "p")
  vim.fn.writefile({ "#!/bin/sh", "printf 'bashunit - 0.50.1\\n'" }, root .. "/bashunit")
  vim.fn.setfperm(root .. "/bashunit", "rwx------")
  vim.env.PATH = root .. ":" .. original
  local ok, result = pcall(adapter.build_spec, { tree = tree })
  vim.env.PATH = original
  return ok, result
end

return {
  ["verified beta exclusions preserve brackets stars and question marks literally"] = function()
    local _, nodes = fixture({ "test_a", "test_a,[bc]", "test_a,*", "test_a,?" })
    one_test(nodes.test_a, "A")
  end,

  ["generated beta exclusions escape a backslash without changing the selected filter"] = function()
    -- A synthetic tree exercises the argument boundary. Bash refuses literal
    -- backslashes in function definitions, so this is not a discovery claim.
    local _, nodes = fixture({ "test_a", "test_a,\\b" })
    local spec = adapter.build_spec({ tree = nodes.test_a })
    assert(spec.command[1] == vim.fn.exepath("bashunit"), "run the executable whose bytes were verified")
    assert(spec.command[6] == "test_a", vim.inspect(spec.command))
    assert(spec.command[8] == "test_a,\\\\b", vim.inspect(spec.command))
  end,

  ["an unreadable build cannot enable the beta exception"] = function()
    local artifact = require("neotest-bashunit.artifact")
    assert(not artifact.verified(vim.fn.tempname()), "missing bytes must not certify an executable")
  end,

  ["the verified beta isolates a test beside a comma-containing sibling"] = function()
    local _, nodes = fixture({ "test_a", "test_a,{b}" })
    one_test(nodes.test_a, "A")
  end,

  ["an exclusion that splits onto the selected name refuses the run with file guidance"] = function()
    local _, nodes = fixture({ "test_a", "test_a,{b}" })
    local ok, message = unverified_build(nodes.test_a)
    assert(not ok, "the unsafe individual run must be refused before returning a command")
    assert(message:find("test_a", 1, true) and message:find("test_a,{b}", 1, true), message)
    assert(message:find("whole file", 1, true), message)
  end,

  ["a later comma fragment that matches the selection also refuses the run"] = function()
    local _, nodes = fixture({ "test_a", "test_b,a" })
    local ok, message = unverified_build(nodes.test_a)
    assert(not ok, "the later exclusion fragment must not erase the selected test")
    assert(message:find("whole file", 1, true), message)
  end,

  ["a comma fragment pattern that matches the selection refuses the run"] = function()
    local _, nodes = fixture({ "test_ab", "test_abz,[ab]" })
    local ok, message = unverified_build(nodes.test_ab)
    assert(not ok, "the comma fragment pattern must not erase the selected test")
    assert(message:find("whole file", 1, true), message)
  end,

  ["an unavailable exclusion check refuses the individual run with file guidance"] = function()
    local _, nodes = fixture({ "test_foo", "test_foobar,baz" })
    local system = vim.system
    vim.system = function()
      error("exclusion probe unavailable")
    end
    local ok, message = unverified_build(nodes.test_foo)
    vim.system = system
    assert(not ok, "an unchecked exclusion must not be launched")
    assert(message:find("whole file", 1, true), message)
  end,

  ["exclusion pathname expansion uses the requested working directory"] = function()
    local _, nodes, root = fixture({ "test_a", "test_az,[ab]" })
    local cwd = root .. "/run-here"
    vim.fn.mkdir(cwd, "p")
    vim.fn.writefile({}, cwd .. "/b")
    one_test(nodes.test_a, "A", { cwd = cwd })
  end,

  ["an incomplete exclusion check refuses the individual run with file guidance"] = function()
    local _, nodes = fixture({ "test_foo", "test_foobar,baz" })
    local system = vim.system
    vim.system = function()
      return {
        wait = function()
          return { code = 124, stdout = "", stderr = "" }
        end,
      }
    end
    local ok, message = unverified_build(nodes.test_foo)
    vim.system = system
    assert(not ok, "an incomplete exclusion check must not allow a launch")
    assert(message:find("whole file", 1, true), message)
  end,

  ["an ordinary individual selection excludes its longer sibling"] = function()
    local _, nodes = fixture({ "test_a", "test_a_extended" })
    one_test(nodes.test_a, "A")
  end,

  ["a comma in the selected name still runs exactly that test"] = function()
    local _, nodes = fixture({ "test_a", "test_a,{b}" })
    one_test(nodes["test_a,{b}"], "A,{b}")
  end,

  ["a comma exclusion that leaves the selected test intact remains supported"] = function()
    local _, nodes = fixture({ "test_foo", "test_foobar,baz" })
    one_test(nodes.test_foo, "Foo")
  end,

  ["a colon name still selects the original file and excludes its longer sibling"] = function()
    local _, nodes = fixture({ "test_a:test_tail", "test_a:test_tail_more" })
    one_test(nodes["test_a:test_tail"], "A:test tail")
  end,

  ["a file run preserves both comma-related test rows"] = function()
    local file = fixture({ "test_a", "test_a,{b}" })
    local rows, results = run(file)
    assert(#rows == 2, "expected both raw rows, got " .. #rows)
    for _, node in file:iter_nodes() do
      if node:data().type == "test" then
        assert(results[node:data().id].status == "passed", vim.inspect(results))
      end
    end
  end,

  ["a directory run preserves both comma-related test rows"] = function()
    local file, _, root = fixture({ "test_a", "test_a,{b}" })
    file:data().type, file:data().id, file:data().path = "dir", root, root
    local rows, results = run(file)
    assert(#rows == 2, "expected both raw rows, got " .. #rows)
    for _, node in file:iter_nodes() do
      if node:data().type == "test" then
        assert(results[node:data().id].status == "passed", vim.inspect(results))
      end
    end
  end,
}
