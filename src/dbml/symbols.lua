-- Symbol table built from the AST, plus LSP document symbols.

local M = {}

local function lower(value)
  return value and value:lower() or nil
end

local function put_first(map, key, value)
  if key and map[key] == nil then
    map[key] = value
  end
end

function M.build(ast)
  local symbols = {
    tables = {},
    table_list = {},
    aliases = {},
    enums = {},
    enum_list = {},
    columns = {},
  }

  for _, table in ipairs(ast.tables) do
    symbols.table_list[#symbols.table_list + 1] = table
    put_first(symbols.tables, table.full_name, table)
    put_first(symbols.tables, table.name, table)
    if table.alias then
      put_first(symbols.aliases, table.alias, table)
    end

    local columns = {}
    for _, column in ipairs(table.columns) do
      put_first(columns, column.name, column)
    end
    put_first(symbols.columns, table.full_name, columns)
    put_first(symbols.columns, table.name, columns)
    if table.alias then
      put_first(symbols.columns, table.alias, columns)
    end
  end

  for _, enum in ipairs(ast.enums) do
    symbols.enum_list[#symbols.enum_list + 1] = enum
    put_first(symbols.enums, enum.full_name or enum.name, enum)
    put_first(symbols.enums, enum.name, enum)
  end

  return symbols
end

local function case_insensitive(map, name)
  if not name then
    return nil
  end
  local wanted = lower(name)
  for key, value in pairs(map) do
    if lower(key) == wanted then
      return value
    end
  end
  return nil
end

function M.find_table(symbols, name)
  if not name then
    return nil
  end
  return symbols.tables[name] or symbols.aliases[name] or case_insensitive(symbols.tables, name)
end

function M.find_enum(symbols, name)
  if not name then
    return nil
  end
  return symbols.enums[name] or case_insensitive(symbols.enums, name)
end

function M.columns_for(symbols, name)
  if not name then
    return nil
  end
  return symbols.columns[name] or case_insensitive(symbols.columns, name)
end

function M.find_column(symbols, table_name, column_name)
  local columns = M.columns_for(symbols, table_name)
  if not columns or not column_name then
    return nil
  end
  return columns[column_name] or case_insensitive(columns, column_name)
end

local function lsp_range(document, range)
  return {
    start = document:position_at(range.start),
    ["end"] = document:position_at(range.stop),
  }
end

function M.document_symbols(ast, document)
  local result = {}

  for _, statement in ipairs(ast.statements) do
    if statement.kind == "table" then
      local children = {}
      for _, column in ipairs(statement.columns) do
        children[#children + 1] = {
          name = column.name,
          kind = 8, -- Field
          detail = column.type,
          range = lsp_range(document, column.range),
          selectionRange = lsp_range(document, column.name_range),
        }
      end
      local symbol = {
        name = statement.full_name,
        kind = 5, -- Class
        detail = statement.partial and "table partial" or "table",
        range = lsp_range(document, statement.range),
        selectionRange = lsp_range(document, statement.name_range),
      }
      if #children > 0 then
        symbol.children = children
      end
      result[#result + 1] = symbol

    elseif statement.kind == "enum" then
      local children = {}
      for _, value in ipairs(statement.values) do
        children[#children + 1] = {
          name = value.name,
          kind = 22, -- EnumMember
          range = lsp_range(document, value.range),
          selectionRange = lsp_range(document, value.name_range),
        }
      end
      local symbol = {
        name = statement.full_name or statement.name,
        kind = 10, -- Enum
        detail = "enum",
        range = lsp_range(document, statement.range),
        selectionRange = lsp_range(document, statement.name_range),
      }
      if #children > 0 then
        symbol.children = children
      end
      result[#result + 1] = symbol

    elseif statement.kind == "ref" then
      local expression = statement.expressions[1]
      local name
      if expression then
        name = expression.from.name .. " " .. expression.operator .. " " .. expression.to.name
        if #statement.expressions > 1 then
          name = name .. " (+" .. (#statement.expressions - 1) .. ")"
        end
      else
        name = statement.name or "ref"
      end
      local selection = (expression and expression.from.range)
        or statement.name_range
        or statement.range
      result[#result + 1] = {
        name = name,
        kind = 25, -- Operator
        detail = "ref",
        range = lsp_range(document, statement.range),
        selectionRange = lsp_range(document, selection),
      }

    elseif statement.kind == "table_group" then
      result[#result + 1] = {
        name = statement.name,
        kind = 11, -- Interface
        detail = "table group",
        range = lsp_range(document, statement.range),
        selectionRange = lsp_range(document, statement.name_range),
      }

    elseif statement.kind == "project" then
      result[#result + 1] = {
        name = statement.name,
        kind = 2, -- Module
        detail = "project",
        range = lsp_range(document, statement.range),
        selectionRange = lsp_range(document, statement.name_range),
      }
    end
  end

  return result
end

return M
