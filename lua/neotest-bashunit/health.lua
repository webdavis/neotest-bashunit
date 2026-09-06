-- `:checkhealth neotest-bashunit`.
--
-- Answers the one question that decides whether this adapter can work at all:
-- is bashunit here, and is it the release every rule in `parse.lua` was
-- measured against. A release that changed an output shape would leave the
-- frozen fixtures green while the adapter quietly misreported real runs, so a
-- mismatch is worth saying out loud rather than discovering through a test that
-- never goes red.

local parse = require("neotest-bashunit.parse")

local M = {}

function M.check()
  vim.health.start("neotest-bashunit")

  local executable = vim.fn.exepath("bashunit")
  if executable == "" then
    vim.health.error("bashunit is not on PATH", {
      "Install it from https://github.com/TypedDevs/bashunit",
      ("This adapter was measured against %s."):format(parse.verified_version),
    })
    return
  end
  vim.health.ok("bashunit found at " .. executable)

  local output = vim.fn.system({ executable, "--version" })
  if vim.v.shell_error ~= 0 then
    vim.health.error("`bashunit --version` exited " .. vim.v.shell_error, { vim.trim(output) })
    return
  end

  local version = parse.version_of(output)
  if not version then
    vim.health.warn("no release number in `bashunit --version`", { vim.trim(output) })
    return
  end

  if version == parse.verified_version then
    vim.health.ok(("version %s, the release this adapter was measured against"):format(version))
  else
    vim.health.warn(("version %s, but this adapter was measured against %s"):format(version, parse.verified_version), {
      "Discovery and result parsing may disagree with what this bashunit prints.",
      "Re-measure the fixtures in tests/ before moving M.verified_version in lua/neotest-bashunit/parse.lua.",
    })
  end
end

return M
