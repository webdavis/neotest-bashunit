local health = require("neotest-bashunit.health")

local function messages(version)
  local original_health, original_path = vim.health, vim.env.PATH
  if version then
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    vim.fn.writefile({ "#!/bin/sh", "printf 'bashunit - " .. version .. "\\n'" }, root .. "/bashunit")
    vim.fn.setfperm(root .. "/bashunit", "rwx------")
    vim.env.PATH = root .. ":" .. original_path
  end
  local found = { ok = {}, warn = {}, error = {} }
  vim.health = { start = function() end }
  for _, kind in ipairs({ "ok", "warn", "error" }) do
    vim.health[kind] = function(message)
      found[kind][#found[kind] + 1] = message
    end
  end
  local ok, err = pcall(health.check)
  vim.health, vim.env.PATH = original_health, original_path
  assert(ok, err)
  return found
end

return {
  ["health identifies the verified beta artifact"] = function()
    local found = messages()
    assert(#found.warn == 0 and #found.error == 0, vim.inspect(found))
    assert(table.concat(found.ok, " "):find("verified beta", 1, true), vim.inspect(found))
  end,

  ["health warns about an unverified executable with the same version"] = function()
    local found = messages("0.50.1")
    assert(#found.warn == 1 and found.warn[1]:find("SHA-256", 1, true), vim.inspect(found))
  end,

  ["health still warns about another release"] = function()
    local found = messages("0.49.0")
    assert(#found.warn == 1 and found.warn[1]:find("0.49.0", 1, true), vim.inspect(found))
  end,
}
