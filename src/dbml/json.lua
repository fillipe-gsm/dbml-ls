-- Thin wrapper around the vendored dkjson implementation.
--
-- dkjson has one important quirk: it treats tables as JSON arrays by
-- default and only encodes an empty table as an object when the table's
-- metatable carries __jsontype = "object".  LSP has plenty of empty
-- objects and empty arrays, so we expose explicit constructors here
-- instead of scattering that detail throughout the codebase.

local dkjson = require("vendor.dkjson")

local M = {}

M.null = dkjson.null

--- Decode a JSON string.  `null` is preserved as M.null instead of nil so
--- that it keeps its place inside arrays.
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

function M.encode(value)
  return dkjson.encode(value)
end

--- An empty table that must be encoded as [].
function M.array(values)
  return values or {}
end

--- An empty table that must be encoded as {}.
function M.object(values)
  values = values or {}
  if next(values) == nil then
    return setmetatable(values, { __jsontype = "object" })
  end
  return values
end

return M
