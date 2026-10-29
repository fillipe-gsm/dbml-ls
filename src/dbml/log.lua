-- Logging must never touch stdout: stdout is the JSON-RPC channel.

local M = {}

local enabled = os.getenv("DBML_LS_LOG") ~= nil

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

function M.debug(fmt, ...)
  emit("debug", fmt, ...)
end

function M.info(fmt, ...)
  emit("info", fmt, ...)
end

function M.warn(fmt, ...)
  emit("warn", fmt, ...)
end

function M.error(fmt, ...)
  emit("error", fmt, ...)
end

return M
