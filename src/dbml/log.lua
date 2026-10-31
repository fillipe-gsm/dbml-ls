-- Logging must never touch stdout: stdout is the JSON-RPC channel.

local M = {}

local enabled = os.getenv("DBML_LS_LOG") ~= nil

---@param level string
---@param fmt string
---@param ... any
local function emit(level, fmt, ...)
  if not enabled then
    return
  end
  local ok, message = pcall(string.format, fmt, ...)
  if not ok then
    message = tostring(fmt)
  end
  io.stderr:write("[dbml-ls] " .. level .. " " .. message .. "\n")
  io.stderr:flush()
end

---@param fmt string
---@param ... any
function M.debug(fmt, ...)
  emit("debug", fmt, ...)
end

---@param fmt string
---@param ... any
function M.info(fmt, ...)
  emit("info", fmt, ...)
end

---@param fmt string
---@param ... any
function M.warn(fmt, ...)
  emit("warn", fmt, ...)
end

---@param fmt string
---@param ... any
function M.error(fmt, ...)
  emit("error", fmt, ...)
end

return M
