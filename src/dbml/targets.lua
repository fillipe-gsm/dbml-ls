-- Resolve a cursor position to a renameable/referenceable symbol target.

local resolve = require("dbml.resolve")
local symbols = require("dbml.symbols")

local M = {}

---@param range dbml.Range?
---@param offset integer
---@return boolean
local function contains(range, offset)
  return range ~= nil and range.start <= offset and offset <= range.stop
end

---@param analysis dbml.Analysis
---@param symbol dbml.ResolvedSymbol
---@return dbml.RenameTarget?
function M.from_symbol(analysis, symbol)
  if symbol.kind == "table" or symbol.kind == "alias" then
    local table = symbol.table
    if not table then
      return nil
    end
    return { kind = symbol.kind, table = table }
  elseif symbol.kind == "column" then
    local table, column = symbol.table, symbol.column
    if not table or not column then
      return nil
    end
    return { kind = "column", table = table, column = column }
  elseif symbol.kind == "enum" then
    local enum = symbol.enum
    if not enum then
      return nil
    end
    return { kind = "enum", enum = enum }
  elseif symbol.kind == "enum_value" then
    local enum, value = symbol.enum, symbol.value
    if not enum or not value then
      return nil
    end
    return { kind = "enum_value", enum = enum, value = value }
  elseif symbol.kind == "type" then
    local column = symbol.column
    if not column or not column.type then
      return nil
    end
    local enum = symbols.find_enum(analysis.symbols, column.type)
    if not enum then
      return nil
    end
    return { kind = "enum", enum = enum }
  elseif symbol.kind == "group" then
    local group = symbol.group
    if not group then
      return nil
    end
    return { kind = "group", group = group }
  elseif symbol.kind == "project" then
    local project = symbol.project
    if not project then
      return nil
    end
    return { kind = "project", project = project }
  end
  return nil
end

---@param target dbml.RenameTarget
---@return string?
function M.name(target)
  if target.kind == "table" then
    local table = target.table
    return table and table.name
  elseif target.kind == "alias" then
    local table = target.table
    return table and table.alias
  elseif target.kind == "column" then
    local column = target.column
    return column and column.name
  elseif target.kind == "enum" then
    local enum = target.enum
    return enum and enum.name
  elseif target.kind == "enum_value" then
    local value = target.value
    return value and value.name
  elseif target.kind == "group" then
    local group = target.group
    return group and group.name
  elseif target.kind == "project" then
    local project = target.project
    return project and project.name
  end
  return nil
end

---@param analysis dbml.Analysis
---@param document dbml.Document
---@param position dbml.Position
---@return dbml.RenameTarget?
---@return dbml.ResolvedSymbol?
function M.at(analysis, document, position)
  local offset = document:offset_at(position)
  local symbol = resolve.at(analysis, offset)
  if not symbol or not contains(symbol.range, offset) then
    return nil
  end
  return M.from_symbol(analysis, symbol), symbol
end

return M
