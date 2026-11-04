-- Same-file rename for DBML symbols.

local occurrences = require("dbml.occurrences")
local symbols = require("dbml.symbols")
local targets = require("dbml.targets")

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

---@param document dbml.Document
---@param range dbml.Range
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
  if not range then
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
---@return dbml.PrepareRenameResult?
function M.prepare(analysis, document, position)
  local target, symbol = targets.at(analysis, document, position)
  if not target or not symbol then
    return nil
  end
  local name = targets.name(target)
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

  local target = targets.at(analysis, document, position)
  if not target then
    return nil
  end
  if targets.name(target) == name or target_collides(analysis, target, name) then
    return nil
  end

  local edits = {}
  local seen = {}
  local formatted = format_name(name)

  for _, occurrence in ipairs(occurrences.for_target(analysis, target)) do
    local text
    if occurrence.kind == "string" then
      text = format_string(name)
    elseif occurrence.kind == "type" then
      text = (occurrence.prefix or "") .. formatted
    else
      text = formatted
    end
    add_edit(edits, seen, occurrence.range, text)
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
