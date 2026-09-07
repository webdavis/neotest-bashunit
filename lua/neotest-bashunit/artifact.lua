local M = {}

M.verified_revision = "683ba16f54fee391dc30bea0a5e6201aeef72c19"
M.verified_sha256 = "429a0f25cf39b2779e3266b4a5bb2c098cb5ebed60d9a3476a1fea3c5acc7a49"

function M.sha256(executable)
  local file = io.open(executable, "rb")
  if not file then
    return nil
  end
  local contents = file:read("*a")
  file:close()
  -- The verified shell script contains no NUL. Reject it before passing a
  -- string to a Vim function, where NUL handling can change its bytes.
  if not contents or contents:find("\0", 1, true) then
    return nil
  end
  return vim.fn.sha256(contents)
end

function M.verified(executable)
  return M.sha256(executable) == M.verified_sha256
end

return M
