-- Hover information for tables, columns, enums, and refs.

local symbols = require("dbml.symbols")

local M = {}

local concat = table.concat

local function contains(range, offset)
  return range ~= nil and range.start <= offset and offset <= range.stop
end

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

local function local_column(table, name)
  for _, column in ipairs(table.columns) do
    if column.name == name then
      return column
    end
  end
  return nil
end

local function find_symbol(analysis, offset)
  for _, table in ipairs(analysis.ast.tables) do
    if contains(table.name_range, offset) or contains(table.alias_range, offset) then
      return { kind = "table", table = table, range = table.alias_range or table.name_range }
    end
    if contains(table.settings_range, offset) then
      return { kind = "table", table = table, range = table.name_range }
    end

    for _, column in ipairs(table.columns) do
      if contains(column.name_range, offset) then
        return { kind = "column", table = table, column = column, range = column.name_range }
      end
      if contains(column.type_range, offset) then
        return { kind = "type", table = table, column = column, range = column.type_range }
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
        return { kind = "enum", enum = enum, range = value.name_range }
      end
    end
    if enum.note and contains(enum.note.range, offset) then
      return { kind = "enum", enum = enum, range = enum.name_range }
    end
  end

  for _, ref in ipairs(analysis.ast.refs) do
    for _, expression in ipairs(ref.expressions) do
      if expression.from.columns then
        for _, column in ipairs(expression.from.columns) do
          if contains(column.range, offset) then
            local table = symbols.find_table(analysis.symbols, expression.from.table)
            local resolved = table and local_column(table, column.name)
            if resolved then
              return { kind = "column", table = table, column = resolved, range = column.range }
            end
          end
        end
      end
      if expression.to.columns then
        for _, column in ipairs(expression.to.columns) do
          if contains(column.range, offset) then
            local table = symbols.find_table(analysis.symbols, expression.to.table)
            local resolved = table and local_column(table, column.name)
            if resolved then
              return { kind = "column", table = table, column = resolved, range = column.range }
            end
          end
        end
      end
      if contains(expression.from.column_range, offset) then
        local table = symbols.find_table(analysis.symbols, expression.from.table)
        local column = table and local_column(table, expression.from.column)
        if column then
          return { kind = "column", table = table, column = column, range = expression.from.column_range }
        end
      end
      if contains(expression.from.table_range, offset) then
        local table = symbols.find_table(analysis.symbols, expression.from.table)
        if table then
          return { kind = "table", table = table, range = expression.from.table_range }
        end
      end
      if contains(expression.to.column_range, offset) then
        local table = symbols.find_table(analysis.symbols, expression.to.table)
        local column = table and local_column(table, expression.to.column)
        if column then
          return { kind = "column", table = table, column = column, range = expression.to.column_range }
        end
      end
      if contains(expression.to.table_range, offset) then
        local table = symbols.find_table(analysis.symbols, expression.to.table)
        if table then
          return { kind = "table", table = table, range = expression.to.table_range }
        end
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
          return { kind = "table", table = table, range = member.range }
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
  local symbol = find_symbol(analysis, offset)
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
