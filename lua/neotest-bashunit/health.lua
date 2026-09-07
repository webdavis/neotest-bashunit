-- `:checkhealth neotest-bashunit` checks the measured version and build.

local parse = require("neotest-bashunit.parse")
local artifact = require("neotest-bashunit.artifact")

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

  if version == parse.verified_version and artifact.verified(executable) then
    vim.health.ok(
      ("version %s, verified beta %s (SHA-256 %s)"):format(
        version,
        artifact.verified_revision,
        artifact.verified_sha256
      )
    )
  else
    vim.health.warn(
      ("version %s, but the measured beta requires version %s and SHA-256 %s"):format(
        version,
        parse.verified_version,
        artifact.verified_sha256
      ),
      {
        "Discovery and result parsing may disagree with what this bashunit prints.",
        "Re-measure the fixtures before changing the version in parse.lua or the build identity in artifact.lua.",
      }
    )
  end
end

return M
