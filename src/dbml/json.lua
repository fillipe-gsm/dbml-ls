-- Thin wrapper around the vendored dkjson implementation.
--
-- dkjson has one important quirk: it treats tables as JSON arrays by
-- default and only encodes an empty table as an object when the table's
-- metatable carries __jsontype = "object".  LSP has plenty of empty
-- objects and empty arrays, so we expose explicit constructors here
-- instead of scattering that detail throughout the codebase.

local dkjson = require("vendor.dkjson")

local M = {}

---@type table
M.null = dkjson.null

--- Decode a JSON string.  `null` is preserved as M.null instead of nil so
--- that it keeps its place inside arrays.
---@param text string
---@return table? value
---@return string? err
function M.decode(text)
  local value, pos, err = dkjson.decode(text, 1, dkjson.null)
  if value == nil then
    return nil, err or "invalid JSON"
  end
  if text:sub(pos):match("%S") then
    return nil, "trailing characters"
  end
  return value
end

---@param value any
---@return string
function M.encode(value)
  local encoded, err = dkjson.encode(value)
  if not encoded then
    error(err or "could not encode JSON", 2)
  end
  ---@cast encoded string
  return encoded
end

--- An empty table that must be encoded as [].
---@param values table?
---@return table
function M.array(values)
  return values or {}
end

--- An empty table that must be encoded as {}.
---@param values table?
---@return table
function M.object(values)
  values = values or {}
  if next(values) == nil then
    return setmetatable(values, { __jsontype = "object" })
  end
  return values
end

return M
