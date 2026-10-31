-- Resolve the semantic symbol under a byte offset.
--
-- Hover and go-to-definition share this so they never disagree about
-- what a token refers to.

local symbols = require("dbml.symbols")

local M = {}

---@param range dbml.Range?
---@param offset integer
---@return boolean
local function contains(range, offset)
  return range ~= nil and range.start <= offset and offset <= range.stop
end

---@param table dbml.Table
---@param name string?
---@return dbml.Column?
local function local_column(table, name)
  for _, column in ipairs(table.columns) do
    if column.name == name then
      return column
    end
  end
  return nil
end

---@param analysis dbml.Analysis
---@param endpoint dbml.Endpoint
---@param offset integer
---@return dbml.ResolvedSymbol?
local function resolve_endpoint(analysis, endpoint, offset)
  if endpoint.columns then
    for _, column in ipairs(endpoint.columns) do
      if contains(column.range, offset) then
        local table = symbols.find_table(analysis.symbols, endpoint.table)
        if table then
          local resolved = local_column(table, column.name)
          if resolved then
            return { kind = "column", table = table, column = resolved, range = column.range }
          end
        end
      end
    end
  end

  local column_range = endpoint.column_range
  if column_range and endpoint.column and contains(column_range, offset) then
    local table = symbols.find_table(analysis.symbols, endpoint.table)
    if table then
      local column = local_column(table, endpoint.column)
      if column then
        return { kind = "column", table = table, column = column, range = column_range }
      end
    end
  end

  if contains(endpoint.table_range, offset) then
    local table = symbols.find_table(analysis.symbols, endpoint.table)
    if table then
      return {
        kind = table.alias == endpoint.table and not endpoint.schema and "alias"
          or "table",
        table = table,
        range = endpoint.table_part_range or endpoint.table_range,
      }
    end
  end

  return nil
end

---@class dbml.ResolvedSymbol
---@field kind string
---@field range dbml.Range
---@field table? dbml.Table
---@field column? dbml.Column
---@field enum? dbml.Enum
---@field value? dbml.EnumValue
---@field ref? dbml.RefStatement
---@field index? dbml.Index
---@field group? dbml.TableGroup
---@field project? dbml.Project

---@param analysis dbml.Analysis
---@param offset integer
---@return dbml.ResolvedSymbol?
function M.at(analysis, offset)
  for _, table in ipairs(analysis.ast.tables) do
    if contains(table.name_range, offset) then
      return { kind = "table", table = table, range = table.name_range }
    end
    if contains(table.alias_range, offset) then
      return { kind = "alias", table = table, range = table.alias_range }
    end
    if contains(table.settings_range, offset) then
      return { kind = "table", table = table, range = table.name_range }
    end

    for _, include in ipairs(table.includes or {}) do
      if contains(include.range, offset) then
        local partial = symbols.find_table(analysis.symbols, include.name)
        if partial and partial.partial then
          return {
            kind = partial.alias == include.name and "alias" or "table",
            table = partial,
            range = include.name_part_range or include.range,
          }
        end
      end
    end

    for _, column in ipairs(table.columns) do
      if contains(column.name_range, offset) then
        return { kind = "column", table = table, column = column, range = column.name_range }
      end
      local type_range = column.type_range
      if type_range and contains(type_range, offset) then
        return { kind = "type", table = table, column = column, range = type_range }
      end
      for _, setting in ipairs(column.settings or {}) do
        if setting.ref and contains(setting.ref.to.range, offset) then
          return resolve_endpoint(analysis, setting.ref.to, offset)
        end
      end
      if contains(column.settings_range, offset) then
        return { kind = "column", table = table, column = column, range = column.name_range }
      end
    end

    for _, index in ipairs(table.indexes or {}) do
      for _, column in ipairs(index.columns) do
        if contains(column.range, offset) then
          local resolved = local_column(table, column.name)
          if resolved then
            return { kind = "column", table = table, column = resolved, range = column.range }
          end
        end
      end
      if contains(index.settings_range, offset) then
        return { kind = "index", table = table, index = index, range = index.range }
      end
    end

    if table.note and contains(table.note.range, offset) then
      return { kind = "table", table = table, range = table.name_range }
    end
  end

  for _, enum in ipairs(analysis.ast.enums) do
    if contains(enum.name_range, offset) or contains(enum.settings_range, offset) then
      return { kind = "enum", enum = enum, range = enum.name_range }
    end
    for _, value in ipairs(enum.values) do
      if contains(value.name_range, offset) or contains(value.settings_range, offset) then
        return {
          kind = "enum_value",
          enum = enum,
          value = value,
          range = value.name_range,
        }
      end
    end
    if enum.note and contains(enum.note.range, offset) then
      return { kind = "enum", enum = enum, range = enum.name_range }
    end
  end

  for _, ref in ipairs(analysis.ast.refs) do
    for _, expression in ipairs(ref.expressions) do
      local from = resolve_endpoint(analysis, expression.from, offset)
      if from then
        return from
      end
      local to = resolve_endpoint(analysis, expression.to, offset)
      if to then
        return to
      end
      if contains(expression.range, offset) then
        return { kind = "ref", ref = ref, range = expression.range }
      end
    end
  end

  for _, group in ipairs(analysis.ast.groups) do
    if contains(group.name_range, offset) or contains(group.settings_range, offset) then
      return { kind = "group", group = group, range = group.name_range }
    end
    for _, member in ipairs(group.members) do
      if contains(member.range, offset) then
        local table = symbols.find_table(analysis.symbols, member.name)
        if table then
          return {
            kind = table.alias == member.name and "alias" or "table",
            table = table,
            range = member.name_part_range or member.range,
          }
        end
      end
    end
  end

  for _, project in ipairs(analysis.ast.projects) do
    if contains(project.name_range, offset) then
      return { kind = "project", project = project, range = project.name_range }
    end
    for _, setting in ipairs(project.settings) do
      if contains(setting.key_range, offset) or contains(setting.value_range, offset) then
        return { kind = "project", project = project, range = setting.key_range }
      end
    end
  end

  return nil
end

return M
