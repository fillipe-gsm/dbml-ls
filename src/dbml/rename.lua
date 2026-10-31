-- Same-file rename for DBML symbols.

local refs = require("dbml.ref")
local resolve = require("dbml.resolve")
local symbols = require("dbml.symbols")

local M = {}

local RESERVED = {
  as = true,
  checks = true,
  enum = true,
  indexes = true,
  note = true,
  project = true,
  records = true,
  ref = true,
  table = true,
  tablegroup = true,
  tablepartial = true,
}

---@param range dbml.Range?
---@param offset integer
---@return boolean
local function contains(range, offset)
  return range ~= nil and range.start <= offset and offset <= range.stop
end

---@param document dbml.Document
---@param range dbml.Range|dbml.RenameEdit
---@return dbml.LspRange
local function lsp_range(document, range)
  return {
    start = document:position_at(range.start),
    ["end"] = document:position_at(range.stop),
  }
end

---@param value string
---@return string
local function trim(value)
  return value:match("^%s*(.-)%s*$") or value
end

---@param value any
---@return string?
local function normalize_new_name(value)
  if type(value) ~= "string" then
    return nil
  end
  local name = trim(value)
  if name:sub(1, 1) == '"' and name:sub(-1) == '"' and #name >= 2 then
    name = name:sub(2, -2)
  end
  if name == "" or name:find("[\r\n]") then
    return nil
  end
  return name
end

---@param name string
---@return string
local function format_name(name)
  if name:match("^[%a_][%w_]*$") and not RESERVED[name:lower()] then
    return name
  end
  local escaped = name:gsub("\\", "\\\\"):gsub('"', '\\"')
  return '"' .. escaped .. '"'
end

---@param value string
---@return string
local function format_string(value)
  local escaped = value:gsub("\\", "\\\\"):gsub("'", "\\'")
  return "'" .. escaped .. "'"
end

---@param edits dbml.RenameEdit[]
---@param seen table<string, boolean>
---@param range dbml.Range?
---@param text string
local function add_edit(edits, seen, range, text)
  if not range or not text then
    return
  end
  local key = range.start .. ":" .. range.stop
  if seen[key] then
    return
  end
  seen[key] = true
  edits[#edits + 1] = {
    start = range.start,
    stop = range.stop,
    text = text,
  }
end

---@param document dbml.Document
---@param edits dbml.RenameEdit[]
---@return table[]
local function lsp_edits(document, edits)
  table.sort(edits, function(a, b)
    if a.start ~= b.start then
      return a.start < b.start
    end
    return a.stop < b.stop
  end)

  local result = {}
  for _, edit in ipairs(edits) do
    result[#result + 1] = {
      range = lsp_range(document, edit),
      newText = edit.text,
    }
  end
  return result
end

---@param analysis dbml.Analysis
---@param symbol dbml.ResolvedSymbol
---@return dbml.RenameTarget?
local function target_for(analysis, symbol)
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
local function target_name(target)
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

---@param endpoint dbml.Endpoint
---@param table dbml.Table
---@return boolean
local function schema_matches(endpoint, table)
  if endpoint.schema and table.schema then
    return endpoint.schema == table.schema
  end
  if endpoint.schema and not table.schema then
    return false
  end
  return true
end

--- Whether a ref endpoint spells the table's actual name (not its alias).
---@param endpoint dbml.Endpoint
---@param table dbml.Table
---@return boolean
local function endpoint_uses_table_name(endpoint, table)
  return endpoint.table == table.name and schema_matches(endpoint, table)
end

--- Whether a ref endpoint refers to the table through its name or alias.
---@param endpoint dbml.Endpoint
---@param table dbml.Table
---@return boolean
local function endpoint_uses_table(endpoint, table)
  if endpoint.table == table.name and schema_matches(endpoint, table) then
    return true
  end
  return table.alias ~= nil and endpoint.table == table.alias and not endpoint.schema
end

---@param analysis dbml.Analysis
---@param target dbml.RenameTarget
---@param new_name string
---@return boolean
local function target_collides(analysis, target, new_name)
  if target.kind == "table" then
    local table = target.table
    if not table then
      return true
    end
    if table.alias == new_name then
      return true
    end
    local full_name = table.schema and (table.schema .. "." .. new_name) or new_name
    local existing = symbols.find_table(analysis.symbols, full_name)
      or symbols.find_table(analysis.symbols, new_name)
    if existing and existing ~= table then
      return true
    end
  elseif target.kind == "alias" then
    local table = target.table
    if not table then
      return true
    end
    if table.name == new_name or table.full_name == new_name then
      return true
    end
    local existing_table = symbols.find_table(analysis.symbols, new_name)
    if existing_table and existing_table ~= table then
      return true
    end
    for _, other in ipairs(analysis.ast.tables) do
      if other ~= table and other.alias == new_name then
        return true
      end
    end
  elseif target.kind == "column" then
    local table, target_column = target.table, target.column
    if not table or not target_column then
      return true
    end
    for _, column in ipairs(table.columns) do
      if column ~= target_column and column.name == new_name then
        return true
      end
    end
  elseif target.kind == "enum" then
    local enum = target.enum
    if not enum then
      return true
    end
    local full_name = enum.schema
        and (enum.schema .. "." .. new_name)
      or new_name
    local existing = symbols.find_enum(analysis.symbols, full_name)
      or symbols.find_enum(analysis.symbols, new_name)
    if existing and existing ~= enum then
      return true
    end
  elseif target.kind == "enum_value" then
    local enum, target_value = target.enum, target.value
    if not enum or not target_value then
      return true
    end
    for _, value in ipairs(enum.values) do
      if value ~= target_value and value.name == new_name then
        return true
      end
    end
  elseif target.kind == "group" then
    local target_group = target.group
    if not target_group then
      return true
    end
    for _, group in ipairs(analysis.ast.groups) do
      if group ~= target_group and group.name == new_name then
        return true
      end
    end
  elseif target.kind == "project" then
    local target_project = target.project
    if not target_project then
      return true
    end
    for _, project in ipairs(analysis.ast.projects) do
      if project ~= target_project and project.name == new_name then
        return true
      end
    end
  end

  return false
end

---@param analysis dbml.Analysis
---@param document dbml.Document
---@param position dbml.Position
---@return dbml.RenameTarget?
---@return dbml.ResolvedSymbol?
local function resolve_target(analysis, document, position)
  local offset = document:offset_at(position)
  local symbol = resolve.at(analysis, offset)
  if not symbol or not contains(symbol.range, offset) then
    return nil
  end
  return target_for(analysis, symbol), symbol
end

---@param analysis dbml.Analysis
---@param target dbml.RenameTarget
---@param new_text string
---@param edits dbml.RenameEdit[]
---@param seen table<string, boolean>
local function rename_table(analysis, target, new_text, edits, seen)
  local table = target.table
  if not table then
    return
  end
  add_edit(edits, seen, table.name_part_range or table.name_range, new_text)

  for _, reference in ipairs(refs.all(analysis.ast)) do
    for _, endpoint in ipairs({ reference.from, reference.to }) do
      if endpoint_uses_table_name(endpoint, table) then
        add_edit(
          edits,
          seen,
          endpoint.table_part_range or endpoint.table_range,
          new_text
        )
      end
    end
  end

  for _, group in ipairs(analysis.ast.groups) do
    for _, member in ipairs(group.members) do
      local resolved = symbols.find_table(analysis.symbols, member.name)
      if member.name ~= table.alias
        and (member.name == table.name
          or member.name == table.full_name
          or resolved == table) then
        add_edit(edits, seen, member.name_part_range or member.range, new_text)
      end
    end
  end

  if table.partial then
    for _, owner in ipairs(analysis.ast.tables) do
      for _, include in ipairs(owner.includes or {}) do
        if include.name ~= table.alias
          and symbols.find_table(analysis.symbols, include.name) == table then
          add_edit(
            edits,
            seen,
            include.name_part_range or include.range,
            new_text
          )
        end
      end
    end
  end
end

---@param analysis dbml.Analysis
---@param target dbml.RenameTarget
---@param new_text string
---@param edits dbml.RenameEdit[]
---@param seen table<string, boolean>
local function rename_alias(analysis, target, new_text, edits, seen)
  local table = target.table
  if not table then
    return
  end
  add_edit(edits, seen, table.alias_range, new_text)

  for _, reference in ipairs(refs.all(analysis.ast)) do
    for _, endpoint in ipairs({ reference.from, reference.to }) do
      if endpoint.table == table.alias and not endpoint.schema then
        add_edit(
          edits,
          seen,
          endpoint.table_part_range or endpoint.table_range,
          new_text
        )
      end
    end
  end

  for _, group in ipairs(analysis.ast.groups) do
    for _, member in ipairs(group.members) do
      if member.name == table.alias then
        add_edit(edits, seen, member.name_part_range or member.range, new_text)
      end
    end
  end

  if table.partial then
    for _, owner in ipairs(analysis.ast.tables) do
      for _, include in ipairs(owner.includes or {}) do
        if include.name == table.alias then
          add_edit(
            edits,
            seen,
            include.name_part_range or include.range,
            new_text
          )
        end
      end
    end
  end
end

---@param analysis dbml.Analysis
---@param target dbml.RenameTarget
---@param new_text string
---@param edits dbml.RenameEdit[]
---@param seen table<string, boolean>
local function rename_column(analysis, target, new_text, edits, seen)
  local table, column = target.table, target.column
  if not table or not column then
    return
  end
  add_edit(edits, seen, column.name_range, new_text)

  for _, reference in ipairs(refs.all(analysis.ast)) do
    for _, endpoint in ipairs({ reference.from, reference.to }) do
      if endpoint_uses_table(endpoint, table) then
        if endpoint.column == column.name then
          add_edit(edits, seen, endpoint.column_range, new_text)
        end
        for _, ref_column in ipairs(endpoint.columns or {}) do
          if ref_column.name == column.name then
            add_edit(edits, seen, ref_column.range, new_text)
          end
        end
      end
    end
  end

  for _, index in ipairs(table.indexes or {}) do
    for _, index_column in ipairs(index.columns or {}) do
      if index_column.name == column.name then
        add_edit(edits, seen, index_column.range, new_text)
      end
    end
  end
end

---@param analysis dbml.Analysis
---@param target dbml.RenameTarget
---@param new_text string
---@param edits dbml.RenameEdit[]
---@param seen table<string, boolean>
local function rename_enum(analysis, target, new_text, edits, seen)
  local enum = target.enum
  if not enum then
    return
  end
  add_edit(edits, seen, enum.name_part_range or enum.name_range, new_text)

  for _, table in ipairs(analysis.ast.tables) do
    for _, column in ipairs(table.columns) do
      local type_range = column.type_range
      if type_range and column.type then
        local resolved = symbols.find_enum(analysis.symbols, column.type)
        if resolved == enum then
          local prefix = enum.schema and (enum.schema .. ".") or ""
          local qualified = prefix ~= ""
            and column.type:sub(1, #prefix) == prefix
          local text = qualified and (prefix .. new_text) or new_text
          add_edit(edits, seen, type_range, text)
        end
      end
    end
  end
end

---@param analysis dbml.Analysis
---@param new_name string
---@param target dbml.RenameTarget
---@param new_text string
---@param edits dbml.RenameEdit[]
---@param seen table<string, boolean>
local function rename_enum_value(analysis, new_name, target, new_text, edits, seen)
  local enum, value = target.enum, target.value
  if not enum or not value then
    return
  end
  add_edit(edits, seen, value.name_range, new_text)

  local new_default = format_string(new_name)
  for _, table in ipairs(analysis.ast.tables) do
    for _, column in ipairs(table.columns) do
      if column.type
        and symbols.find_enum(analysis.symbols, column.type) == enum then
        for _, setting in ipairs(column.settings or {}) do
          if setting.key:lower() == "default"
            and setting.value == value.name
            and setting.value_range then
            add_edit(edits, seen, setting.value_range, new_default)
          end
        end
      end
    end
  end
end

---@param analysis dbml.Analysis
---@param document dbml.Document
---@param position dbml.Position
---@return dbml.PrepareRenameResult?
function M.prepare(analysis, document, position)
  local target, symbol = resolve_target(analysis, document, position)
  if not target or not symbol then
    return nil
  end
  local name = target_name(target)
  if not name then
    return nil
  end
  return {
    range = lsp_range(document, symbol.range),
    placeholder = name,
  }
end

---@param analysis dbml.Analysis
---@param document dbml.Document
---@param position dbml.Position
---@param new_name string?
---@return table?
function M.rename(analysis, document, position, new_name)
  local name = normalize_new_name(new_name)
  if not name then
    return nil
  end

  local target = resolve_target(analysis, document, position)
  if not target then
    return nil
  end
  if target_name(target) == name or target_collides(analysis, target, name) then
    return nil
  end

  local edits = {}
  local seen = {}
  local formatted = format_name(name)

  if target.kind == "table" then
    rename_table(analysis, target, formatted, edits, seen)
  elseif target.kind == "alias" then
    rename_alias(analysis, target, formatted, edits, seen)
  elseif target.kind == "column" then
    rename_column(analysis, target, formatted, edits, seen)
  elseif target.kind == "enum" then
    rename_enum(analysis, target, formatted, edits, seen)
  elseif target.kind == "enum_value" then
    rename_enum_value(analysis, name, target, formatted, edits, seen)
  elseif target.kind == "group" and target.group then
    add_edit(edits, seen, target.group.name_range, formatted)
  elseif target.kind == "project" and target.project then
    add_edit(edits, seen, target.project.name_range, formatted)
  end

  if #edits == 0 then
    return nil
  end

  return {
    changes = {
      [document.uri] = lsp_edits(document, edits),
    },
  }
end

return M
