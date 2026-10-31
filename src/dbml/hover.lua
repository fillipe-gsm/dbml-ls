-- Hover information for tables, columns, enums, and refs.

local resolve = require("dbml.resolve")
local symbols = require("dbml.symbols")

local M = {}

local concat = table.concat

local function lsp_range(document, range)
  return {
    start = document:position_at(range.start),
    ["end"] = document:position_at(range.stop),
  }
end

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

local function ref_expression_text(expression)
  return expression.from.name .. " " .. expression.operator .. " " .. expression.to.name
end

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

local function project_markdown(project)
  local lines = { "**Project** `" .. project.name .. "`" }
  for _, setting in ipairs(project.settings) do
    if setting.value then
      lines[#lines + 1] = "- `" .. setting.key .. "`: " .. setting.value
    end
  end
  return concat(lines, "\n")
end

local function markdown_for(symbol, analysis)
  if symbol.kind == "table" then
    return table_markdown(symbol.table)
  elseif symbol.kind == "column" then
    return column_markdown(symbol.table, symbol.column, analysis)
  elseif symbol.kind == "type" then
    local enum = symbols.find_enum(analysis.symbols, symbol.column.type)
    if enum then
      return enum_markdown(enum)
    end
    return "Type `" .. (symbol.column.type or "unknown") .. "`"
  elseif symbol.kind == "enum" then
    return enum_markdown(symbol.enum)
  elseif symbol.kind == "enum_value" then
    return enum_markdown(symbol.enum)
  elseif symbol.kind == "ref" then
    return ref_markdown(symbol.ref)
  elseif symbol.kind == "index" then
    return index_markdown(symbol.table, symbol.index)
  elseif symbol.kind == "group" then
    return "**TableGroup** `" .. symbol.group.name .. "`"
  elseif symbol.kind == "project" then
    return project_markdown(symbol.project)
  end
  return nil
end

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
