-- Collect all occurrences of a symbol in the current document.
--
-- Rename and find-references share this traversal so they always agree
-- about what counts as a reference.

local refs = require("dbml.ref")
local symbols = require("dbml.symbols")

local M = {}

---@param entries dbml.Occurrence[]
---@param seen table<string, dbml.Occurrence>
---@param range dbml.Range?
---@param declaration boolean
---@param kind "name"|"type"|"string"?
---@param prefix string?
local function add(entries, seen, range, declaration, kind, prefix)
  if not range then
    return
  end

  local key = range.start .. ":" .. range.stop
  local existing = seen[key]
  if existing then
    existing.declaration = existing.declaration or declaration
    return
  end

  local entry = {
    range = range,
    declaration = declaration,
    kind = kind or "name",
    prefix = prefix,
  }
  seen[key] = entry
  entries[#entries + 1] = entry
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
---@param match fun(endpoint: dbml.Endpoint)
local function add_ref_endpoints(analysis, match)
  for _, reference in ipairs(refs.all(analysis.ast)) do
    for _, endpoint in ipairs({ reference.from, reference.to }) do
      match(endpoint)
    end
  end
end

---@param analysis dbml.Analysis
---@param target dbml.RenameTarget
---@return dbml.Occurrence[]
function M.for_target(analysis, target)
  local entries = {}
  local seen = {}

  if target.kind == "table" then
    local table = target.table
    if not table then
      return {}
    end

    add(entries, seen, table.name_part_range or table.name_range, true, "name")

    add_ref_endpoints(analysis, function(endpoint)
      if endpoint_uses_table_name(endpoint, table) then
        add(
          entries,
          seen,
          endpoint.table_part_range or endpoint.table_range,
          false,
          "name"
        )
      end
    end)

    for _, group in ipairs(analysis.ast.groups) do
      for _, member in ipairs(group.members) do
        local resolved = symbols.find_table(analysis.symbols, member.name)
        if member.name ~= table.alias
          and (member.name == table.name
            or member.name == table.full_name
            or resolved == table) then
          add(entries, seen, member.name_part_range or member.range, false, "name")
        end
      end
    end

    if table.partial then
      for _, owner in ipairs(analysis.ast.tables) do
        for _, include in ipairs(owner.includes or {}) do
          if include.name ~= table.alias
            and symbols.find_table(analysis.symbols, include.name) == table then
            add(
              entries,
              seen,
              include.name_part_range or include.range,
              false,
              "name"
            )
          end
        end
      end
    end

  elseif target.kind == "alias" then
    local table = target.table
    if not table then
      return {}
    end

    add(entries, seen, table.alias_range, true, "name")

    add_ref_endpoints(analysis, function(endpoint)
      if endpoint.table == table.alias and not endpoint.schema then
        add(
          entries,
          seen,
          endpoint.table_part_range or endpoint.table_range,
          false,
          "name"
        )
      end
    end)

    for _, group in ipairs(analysis.ast.groups) do
      for _, member in ipairs(group.members) do
        if member.name == table.alias then
          add(entries, seen, member.name_part_range or member.range, false, "name")
        end
      end
    end

    if table.partial then
      for _, owner in ipairs(analysis.ast.tables) do
        for _, include in ipairs(owner.includes or {}) do
          if include.name == table.alias then
            add(
              entries,
              seen,
              include.name_part_range or include.range,
              false,
              "name"
            )
          end
        end
      end
    end

  elseif target.kind == "column" then
    local table, column = target.table, target.column
    if not table or not column then
      return {}
    end

    add(entries, seen, column.name_range, true, "name")

    add_ref_endpoints(analysis, function(endpoint)
      if endpoint_uses_table(endpoint, table) then
        if endpoint.column == column.name then
          add(entries, seen, endpoint.column_range, false, "name")
        end
        for _, ref_column in ipairs(endpoint.columns or {}) do
          if ref_column.name == column.name then
            add(entries, seen, ref_column.range, false, "name")
          end
        end
      end
    end)

    for _, index in ipairs(table.indexes or {}) do
      for _, index_column in ipairs(index.columns or {}) do
        if index_column.name == column.name then
          add(entries, seen, index_column.range, false, "name")
        end
      end
    end

  elseif target.kind == "enum" then
    local enum = target.enum
    if not enum then
      return {}
    end

    add(entries, seen, enum.name_part_range or enum.name_range, true, "name")

    for _, table in ipairs(analysis.ast.tables) do
      for _, column in ipairs(table.columns) do
        local type_range = column.type_range
        if type_range and column.type then
          local resolved = symbols.find_enum(analysis.symbols, column.type)
          if resolved == enum then
            local prefix = enum.schema and (enum.schema .. ".") or ""
            local qualified = prefix ~= ""
              and column.type:sub(1, #prefix) == prefix
            add(
              entries,
              seen,
              type_range,
              false,
              "type",
              qualified and prefix or ""
            )
          end
        end
      end
    end

  elseif target.kind == "enum_value" then
    local enum, value = target.enum, target.value
    if not enum or not value then
      return {}
    end

    add(entries, seen, value.name_range, true, "name")

    for _, table in ipairs(analysis.ast.tables) do
      for _, column in ipairs(table.columns) do
        if column.type
          and symbols.find_enum(analysis.symbols, column.type) == enum then
          for _, setting in ipairs(column.settings or {}) do
            if setting.key:lower() == "default"
              and setting.value == value.name
              and setting.value_range then
              add(entries, seen, setting.value_range, false, "string")
            end
          end
        end
      end
    end

  elseif target.kind == "group" then
    local group = target.group
    if not group then
      return {}
    end
    add(entries, seen, group.name_range, true, "name")

  elseif target.kind == "project" then
    local project = target.project
    if not project then
      return {}
    end
    add(entries, seen, project.name_range, true, "name")
  end

  table.sort(entries, function(a, b)
    if a.range.start ~= b.range.start then
      return a.range.start < b.range.start
    end
    return a.range.stop < b.range.stop
  end)

  return entries
end

return M
