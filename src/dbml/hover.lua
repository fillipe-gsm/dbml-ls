-- Hover information for tables, columns, enums, and refs.

local resolve = require("dbml.resolve")
local symbols = require("dbml.symbols")

local M = {}

local concat = table.concat

---@param document dbml.Document
---@param range dbml.Range
---@return dbml.LspRange
local function lsp_range(document, range)
  return {
    start = document:position_at(range.start),
    ["end"] = document:position_at(range.stop),
  }
end

---@param settings dbml.Setting[]?
---@return string
local function settings_text(settings)
  local parts = {}
  for _, setting in ipairs(settings or {}) do
    if setting.value then
      parts[#parts + 1] = setting.key .. ": " .. setting.value
    else
      parts[#parts + 1] = setting.key
    end
  end
  return concat(parts, ", ")
end

---@param table dbml.Table
---@return string
local function table_markdown(table)
  local lines = { "**Table** `" .. table.full_name .. "`" }
  if table.alias then
    lines[#lines + 1] = "Alias: `" .. table.alias .. "`"
  end
  if table.settings and #table.settings > 0 then
    lines[#lines + 1] = "Settings: " .. settings_text(table.settings)
  end
  if #table.columns > 0 then
    lines[#lines + 1] = ""
    for _, column in ipairs(table.columns) do
      local line = "- `" .. column.name .. "` — `" .. (column.type or "unknown") .. "`"
      if #column.settings > 0 then
        line = line .. " [" .. settings_text(column.settings) .. "]"
      end
      lines[#lines + 1] = line
    end
  end
  if table.note then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "> " .. table.note.text
  end
  return concat(lines, "\n")
end

---@param table dbml.Table
---@param column dbml.Column
---@param analysis dbml.Analysis
---@return string
local function column_markdown(table, column, analysis)
  local lines = {
    "**Column** `" .. table.full_name .. "." .. column.name .. "`",
    "",
    "Type: `" .. (column.type or "unknown") .. "`",
  }
  if #column.settings > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Settings: " .. settings_text(column.settings)
  end

  local enum = column.type and symbols.find_enum(analysis.symbols, column.type)
  if enum then
    lines[#lines + 1] = ""
    local values = {}
    for _, value in ipairs(enum.values) do
      values[#values + 1] = value.name
    end
    lines[#lines + 1] = "Enum `" .. enum.name .. "`: " .. concat(values, ", ")
  end

  return concat(lines, "\n")
end

---@param enum dbml.Enum
---@return string
local function enum_markdown(enum)
  local lines = { "**Enum** `" .. (enum.full_name or enum.name) .. "`" }
  if #enum.values > 0 then
    lines[#lines + 1] = ""
    for _, value in ipairs(enum.values) do
      local line = "- `" .. value.name .. "`"
      if #value.settings > 0 then
        line = line .. " [" .. settings_text(value.settings) .. "]"
      end
      lines[#lines + 1] = line
    end
  end
  if enum.note then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "> " .. enum.note.text
  end
  return concat(lines, "\n")
end

---@param expression dbml.Reference
---@return string
local function ref_expression_text(expression)
  return expression.from.name .. " " .. expression.operator .. " " .. expression.to.name
end

---@param ref dbml.RefStatement
---@return string
local function ref_markdown(ref)
  local lines = { "**Ref**" }
  for _, expression in ipairs(ref.expressions) do
    local line = "- `" .. ref_expression_text(expression) .. "`"
    if expression.settings and #expression.settings > 0 then
      line = line .. " [" .. settings_text(expression.settings) .. "]"
    end
    lines[#lines + 1] = line
  end
  return concat(lines, "\n")
end

---@param table dbml.Table
---@param index dbml.Index
---@return string
local function index_markdown(table, index)
  local lines = { "**Index** on `" .. table.full_name .. "`" }

  if index.columns and #index.columns > 0 then
    local names = {}
    for _, column in ipairs(index.columns) do
      names[#names + 1] = column.name
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Columns: " .. concat(names, ", ")
  end

  if index.expressions and #index.expressions > 0 then
    local expressions = {}
    for _, expression in ipairs(index.expressions) do
      expressions[#expressions + 1] = expression.text
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Expressions: " .. concat(expressions, ", ")
  end

  if index.settings and #index.settings > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Settings: " .. settings_text(index.settings)
  end

  return concat(lines, "\n")
end

---@param project dbml.Project
---@return string
local function project_markdown(project)
  local lines = { "**Project** `" .. project.name .. "`" }
  for _, setting in ipairs(project.settings) do
    if setting.value then
      lines[#lines + 1] = "- `" .. setting.key .. "`: " .. setting.value
    end
  end
  return concat(lines, "\n")
end

---@param symbol dbml.ResolvedSymbol
---@param analysis dbml.Analysis
---@return string?
local function markdown_for(symbol, analysis)
  if symbol.kind == "table" then
    local table = symbol.table
    return table and table_markdown(table)
  elseif symbol.kind == "column" then
    local table, column = symbol.table, symbol.column
    if not table or not column then
      return nil
    end
    return column_markdown(table, column, analysis)
  elseif symbol.kind == "type" then
    local column = symbol.column
    if not column or not column.type then
      return "Type `unknown`"
    end
    local enum = symbols.find_enum(analysis.symbols, column.type)
    if enum then
      return enum_markdown(enum)
    end
    return "Type `" .. column.type .. "`"
  elseif symbol.kind == "enum" then
    local enum = symbol.enum
    return enum and enum_markdown(enum)
  elseif symbol.kind == "enum_value" then
    local enum = symbol.enum
    return enum and enum_markdown(enum)
  elseif symbol.kind == "ref" then
    local ref = symbol.ref
    return ref and ref_markdown(ref)
  elseif symbol.kind == "index" then
    local table, index = symbol.table, symbol.index
    if not table or not index then
      return nil
    end
    return index_markdown(table, index)
  elseif symbol.kind == "group" then
    local group = symbol.group
    return group and ("**TableGroup** `" .. group.name .. "`")
  elseif symbol.kind == "project" then
    local project = symbol.project
    return project and project_markdown(project)
  end
  return nil
end

---@param analysis dbml.Analysis
---@param document dbml.Document
---@param position dbml.Position
---@return dbml.Hover?
function M.hover(analysis, document, position)
  local offset = document:offset_at(position)
  local symbol = resolve.at(analysis, offset)
  if not symbol then
    return nil
  end
  local markdown = markdown_for(symbol, analysis)
  if not markdown then
    return nil
  end
  return {
    contents = {
      kind = "markdown",
      value = markdown,
    },
    range = lsp_range(document, symbol.range),
  }
end

return M
