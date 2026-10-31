-- Go-to-definition for same-file DBML symbols.

local resolve = require("dbml.resolve")
local symbols = require("dbml.symbols")

local M = {}

local function location(document, range)
  if not range then
    return nil
  end
  return {
    uri = document.uri,
    range = {
      start = document:position_at(range.start),
      ["end"] = document:position_at(range.stop),
    },
  }
end

local function target_range(symbol, analysis)
  if symbol.kind == "table" then
    return symbol.table.name_range
  elseif symbol.kind == "column" then
    return symbol.column.name_range
  elseif symbol.kind == "enum" then
    return symbol.enum.name_range
  elseif symbol.kind == "enum_value" then
    return symbol.value.name_range
  elseif symbol.kind == "type" then
    local enum = symbol.column.type
      and symbols.find_enum(analysis.symbols, symbol.column.type)
    return enum and enum.name_range or nil
  elseif symbol.kind == "group" then
    return symbol.group.name_range
  elseif symbol.kind == "project" then
    return symbol.project.name_range
  end
  return nil
end

function M.definition(analysis, document, position)
  local offset = document:offset_at(position)
  local symbol = resolve.at(analysis, offset)
  if not symbol then
    return nil
  end
  return location(document, target_range(symbol, analysis))
end

return M
