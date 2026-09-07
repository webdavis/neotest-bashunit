-- neotest-bashunit: a neotest adapter for `<name>.test.sh` files.
--
-- A failing test gets an output buffer holding its report message.
-- Passing tests retain the run's output because bashunit gives them no message.
-- A single-test run excludes siblings that bashunit's substring filter would
-- otherwise include.
--
-- Discovery and report rules live in `parse.lua` as pure functions, verified
-- by `tests/` under a bare headless Neovim. This file owns the neotest interface,
-- the file system, commands and Bash's exclusion-pattern check.

local parse = require("neotest-bashunit.parse")
local artifact = require("neotest-bashunit.artifact")

---@type neotest.Adapter
local adapter = { name = "neotest-bashunit" }

---@param name string
---@return boolean
function adapter.filter_dir(name)
  -- `.bashunit` is bashunit's own run state, `target` is cargo's: both are
  -- large, neither can hold a test file.
  return name ~= ".git" and name ~= ".bashunit" and name ~= "node_modules" and name ~= "target"
end

---Whether any bashunit test file is reachable below `root`.
---
---`vim.fs.dir` rather than `vim.fs.find`: find's downward walk has no way to
---prune a directory, so on a root holding no test it queues `node_modules` and
---`.git` and reads the whole tree. `vim.fs.dir` is a lazy iterator, so the
---first match ends the walk and the pruned directories are never opened.
---
---`skip` is handed the path RELATIVE to `root`, so the comparison is against
---the last component: whole-path equality would let `src/node_modules`
---through. `fixtures` is skipped here but NOT in `filter_dir`, because this is
---only the question of whether to attach at all; a fixture tree is where a
---sample test file would sit without being anybody's test to run, while
---`filter_dir` decides what neotest may DISCOVER and must not hide a real one.
---@param root string
---@return boolean
local function holds_a_test(root)
  for name, kind in
    vim.fs.dir(root, {
      depth = math.huge,
      skip = function(relative)
        local base = vim.fs.basename(relative)
        return adapter.filter_dir(base) and base ~= "fixtures"
      end,
    })
  do
    if kind == "file" and parse.is_test_file(name) then
      return true
    end
  end
  return false
end

---@param dir string
---@return string|nil
function adapter.root(dir)
  local root = vim.fs.root(dir, { ".bashunitrc", ".git" })
  -- The marker alone is not the answer. `.git` sits at the top of every
  -- repository there is, so claiming on it attached this adapter to all of
  -- them, and neotest hands a whole-directory run to the single non-JavaScript
  -- adapter that attached: a project with no bash in it ran its "all tests"
  -- through bashunit. A `.bashunitrc` is somebody writing the configuration on
  -- purpose and is taken at its word, test files or not; a bare `.git` has to
  -- be backed by a test file that is actually there.
  if not root or vim.uv.fs_stat(root .. "/.bashunitrc") then
    return root
  end
  return holds_a_test(root) and root or nil
end

---@param file_path string
---@return boolean
function adapter.is_test_file(file_path)
  return parse.is_test_file(file_path)
end

---@param file_path string
---@return neotest.Tree
function adapter.discover_positions(file_path)
  local lines = vim.fn.readfile(file_path)
  return require("neotest.types").Tree.from_list(parse.positions(file_path, lines), function(position)
    return position.id
  end)
end

---Every test function discovered in the file that holds this test position,
---the selected one included. Empty when neotest handed over a detached node.
---@param test_node neotest.Tree
---@return string[]
local function sibling_function_names(test_node)
  local file_node = test_node:parent()
  if not file_node then
    return {}
  end
  local names = {}
  for _, node in file_node:iter_nodes() do
    local data = node:data()
    if data.type == "test" then
      names[#names + 1] = data.id:match("::(.*)$")
    end
  end
  return names
end

local EXCLUSION_CHECK = [=[
set -euo pipefail
selected=$1
shift
IFS=,
for exclusion in "$@"; do
  # bashunit splits on commas and expands pathnames before its case match.
  # shellcheck disable=SC2086
  for fragment in $exclusion; do
    fragment=${fragment/test_/}
    if [[ -n $fragment ]]; then
      case "$selected" in
        test_*${fragment}*) printf '%s' "$exclusion"; exit 1 ;;
      esac
    fi
  done
done
]=]

local function check_exclusions(selected, excludes, cwd)
  local has_comma = false
  for _, name in ipairs(excludes) do
    has_comma = has_comma or name:find(",", 1, true) ~= nil
  end
  if not has_comma then
    return
  end
  local executable = vim.fn.exepath("bashunit")
  if artifact.verified(executable) then
    return executable
  end
  local command = { "bash", "--noprofile", "--norc", "-c", EXCLUSION_CHECK, "bash", selected }
  vim.list_extend(command, excludes)
  local ok, result = pcall(function()
    return vim.system(command, { cwd = cwd, env = { BASH_ENV = "" }, text = true }):wait(1000)
  end)
  if ok and result.code == 0 then
    return
  end
  if ok and result.code == 1 then
    error(
      ("bashunit cannot run %q alone: the comma-separated exclusion for %q also excludes it. Run the whole file instead."):format(
        selected,
        result.stdout
      ),
      0
    )
  end
  error(("bashunit could not check exclusions for %q. Run the whole file instead."):format(selected), 0)
end

---@param args neotest.RunArgs
---@return neotest.RunSpec|nil
function adapter.build_spec(args)
  local position = args.tree:data()
  if position.type ~= "dir" and position.type ~= "file" and position.type ~= "test" then
    return nil
  end

  local cwd = adapter.root(position.path) or vim.fs.dirname(position.path)
  local report = vim.fn.tempname() .. ".json"
  local command = { "bashunit", position.path, "--report-json", report }

  if position.type == "test" then
    -- One test, by function name, and one test only. `--filter` is a SUBSTRING
    -- match on 0.50.1 (`case "$fn" in test_*${needle}*`, needle being the name
    -- with `test_` stripped), so `--filter test_alpha` on its own also runs
    -- `test_alpha_extended` AND `test_beta_alpha`, measured. It is not a regular
    -- expression, so anchoring it matches nothing at all. Every sibling the
    -- needle would drag in is named back as an `--exclude-filter`, which is
    -- repeatable and reduces the run to the one test (measured).
    local selected = position.id:match("::(.*)$")
    local excludes = parse.exclude_filters(selected, sibling_function_names(args.tree))
    local verified = check_exclusions(selected, excludes, args.cwd or cwd)
    if verified then
      command[1] = verified
    end
    vim.list_extend(command, { "--filter", selected })
    for _, sibling in ipairs(excludes) do
      -- The beta keeps each comma-containing argument whole, but still uses
      -- shell patterns. Escape generated names so brackets and backslashes
      -- exclude that sibling literally. The selected filter is unchanged.
      if verified then
        sibling = sibling:gsub("([\\*?%[%]])", "\\%1")
      end
      vim.list_extend(command, { "--exclude-filter", sibling })
    end
  end
  vim.list_extend(command, args.extra_args or {})

  return {
    command = command,
    cwd = cwd,
    context = { report = report },
    -- NO_COLOR, not --no-color: the flag is ignored in either position on
    -- 0.50.1, and neotest runs its command under a pty, so bashunit would
    -- otherwise colour output that `parse.failing_lines` has to read.
    env = { NO_COLOR = "1" },
  }
end

---@param path string|nil
---@return string|nil
local function read_file(path)
  if not path or vim.fn.filereadable(path) ~= 1 then
    return nil
  end
  return table.concat(vim.fn.readfile(path, "b"), "\n")
end

---A file holding one failing test's report message.
---@param message string
---@return string
local function write_output(message)
  local path = vim.fn.tempname()
  vim.fn.writefile(vim.split(message, "\n"), path)
  return path
end

---@param spec neotest.RunSpec
---@param result neotest.StrategyResult
---@param tree neotest.Tree
---@return table<string, neotest.Result>
function adapter.results(spec, result, tree)
  local rows, report_error = parse.report_rows(read_file(spec.context and spec.context.report))
  if not rows then
    -- The run never produced a report: bashunit is missing, the file did not
    -- parse, or the process died. Failing the position that was asked for, with
    -- the run's own output attached, says so; returning nothing would read as
    -- "nothing ran" and leave the tree looking untouched.
    return {
      [tree:data().id] = { status = "failed", short = report_error, output = result.output },
    }
  end

  local positions, results = {}, {}
  for _, node in tree:iter_nodes() do
    local data = node:data()
    if data.type == "test" then
      positions[#positions + 1] = data
      -- Discovery already found this title on a second test in the same file.
      -- No report row can be attributed to either side, so both are failed with
      -- the collision named rather than one of them taking the other's verdict.
      if data.ambiguous then
        results[data.id] = { status = "failed", short = data.ambiguous, output = result.output }
      end
    end
  end

  local failing_lines = parse.failing_lines(read_file(result.output))
  -- match_rows never returns an ambiguous position, so nothing below overwrites
  -- an ambiguity verdict recorded above.
  for id, row in pairs(parse.match_rows(rows, positions)) do
    local entry = { status = row.status, output = result.output }
    if row.message ~= "" then
      entry.short = row.message
      entry.output = write_output(row.message)
    end
    if row.status == "failed" then
      local candidates = failing_lines[row.file .. "\0" .. row.name]
      local line
      if candidates and #candidates == 1 then
        line = candidates[1]
      else
        -- bashunit listed every assertion in the function, or none, so the jump
        -- goes to where the test starts. Saying so beats a confident jump to an
        -- assertion that passed.
        line = parse.message_line(row.message)
        if candidates then
          entry.short = ("%s\n\nneotest-bashunit: bashunit listed %d assertions under Source:, which does not say which one failed, so this points at the test's own line."):format(
            entry.short or "",
            #candidates
          )
        end
      end
      entry.errors = { { message = row.message, line = line and line - 1 or nil } }
    end
    results[id] = entry
  end
  return results
end

return adapter
