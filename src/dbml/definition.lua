-- Go-to-definition for same-file DBML symbols.

local resolve = require("dbml.resolve")
local symbols = require("dbml.symbols")

local M = {}

---@param document dbml.Document
---@param range dbml.Range?
---@return dbml.Location?
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

---@param symbol dbml.ResolvedSymbol
---@param analysis dbml.Analysis
---@return dbml.Range?
local function target_range(symbol, analysis)
  if symbol.kind == "table" then
    local table = symbol.table
    return table and table.name_range
  elseif symbol.kind == "column" then
    local column = symbol.column
    return column and column.name_range
  elseif symbol.kind == "enum" then
    local enum = symbol.enum
    return enum and enum.name_range
  elseif symbol.kind == "enum_value" then
    local value = symbol.value
    return value and value.name_range
  elseif symbol.kind == "type" then
    local column = symbol.column
    if not column or not column.type then
      return nil
    end
    local enum = symbols.find_enum(analysis.symbols, column.type)
    return enum and enum.name_range or nil
  elseif symbol.kind == "group" then
    local group = symbol.group
    return group and group.name_range
  elseif symbol.kind == "project" then
    local project = symbol.project
    return project and project.name_range
  end
  return nil
end

---@param analysis dbml.Analysis
---@param document dbml.Document
---@param position dbml.Position
---@return dbml.Location?
function M.definition(analysis, document, position)
  local offset = document:offset_at(position)
  local symbol = resolve.at(analysis, offset)
  if not symbol then
    return nil
  end
  return location(document, target_range(symbol, analysis))
end

return M
