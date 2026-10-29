-- Structured relationship model.
--
-- Top-level `Ref:` expressions and inline `[ref: > table.column]`
-- settings both produce a dbml.Reference.  Keeping a real object with
-- validated fields makes diagnostics, hover, and the future
-- go-to-definition implementation share one representation.

local M = {}

---@class dbml.Range
---@field start integer 0-based byte offset, inclusive
---@field stop integer 0-based byte offset, exclusive

local OPERATORS = {
  [">"] = true,
  ["<"] = true,
  ["-"] = true,
  ["<>"] = true,
}

M.OPERATORS = OPERATORS

--- Whether a raw operator is valid.  DBML allows `?` on either side to
--- mark one end of the relationship optional (`>?`, `?>`, ...).
function M.is_operator(value)
  if type(value) ~= "string" then
    return false
  end
  if not value:match("^%??[<>%-]+%??$") then
    return false
  end
  return OPERATORS[value:gsub("%?", "")] == true
end

---@class dbml.Endpoint
---@field schema string?
---@field table string
---@field column string
---@field parts string[]
---@field ranges dbml.Range[]
---@field name string
---@field range dbml.Range
---@field table_range dbml.Range
---@field column_range dbml.Range

local Endpoint = {}
Endpoint.__index = Endpoint

Endpoint.required = {
  "table",
  "range",
  "table_range",
}

function Endpoint.new(values)
  for _, key in ipairs(Endpoint.required) do
    if values[key] == nil then
      error("dbml.Endpoint: missing required field '" .. key .. "'", 2)
    end
  end
  if values.column == nil and (values.columns == nil or #values.columns == 0) then
    error("dbml.Endpoint: missing required field 'column' or 'columns'", 2)
  end

  local self = setmetatable({}, Endpoint)
  for key, value in pairs(values) do
    self[key] = value
  end

  self.parts = self.parts or { self.table, self.column }
  self.ranges = self.ranges or { self.table_range, self.column_range }
  local prefix = self.schema and (self.schema .. ".") or ""
  if self.column then
    self.name = self.name or (prefix .. self.table .. "." .. self.column)
  else
    local names = {}
    for _, column in ipairs(self.columns) do
      names[#names + 1] = type(column) == "table" and column.name or column
    end
    self.name = self.name or (prefix .. self.table .. ".(" .. table.concat(names, ", ") .. ")")
  end
  return self
end

--- Build an endpoint from an already parsed table and column.  This is
--- how inline refs describe their implicit left-hand side.
function Endpoint.from_table_column(table, column)
  local prefix = table.schema and (table.schema .. ".") or ""
  local full_name = prefix .. table.name
  local parts = {}
  if table.schema then
    for part in table.schema:gmatch("[^.]+") do
      parts[#parts + 1] = part
    end
  end
  parts[#parts + 1] = table.name
  parts[#parts + 1] = column.name

  return Endpoint.new({
    schema = table.schema,
    table = table.name,
    column = column.name,
    parts = parts,
    name = full_name .. "." .. column.name,
    range = { start = table.name_range.start, stop = column.name_range.stop },
    table_range = table.name_range,
    column_range = column.name_range,
  })
end

---@class dbml.Reference
---@field kind string
---@field from dbml.Endpoint
---@field to dbml.Endpoint
---@field operator string
---@field source "top_level"|"inline"
---@field parent dbml.Endpoint?
---@field name string?
---@field name_range dbml.Range?
---@field range dbml.Range
---@field settings table[]?
---@field settings_range dbml.Range?

local Reference = {}
Reference.__index = Reference

Reference.required = {
  "from",
  "to",
  "operator",
  "source",
  "range",
}

function Reference.new(values)
  for _, key in ipairs(Reference.required) do
    if values[key] == nil then
      error("dbml.Reference: missing required field '" .. key .. "'", 2)
    end
  end
  if getmetatable(values.from) ~= Endpoint or getmetatable(values.to) ~= Endpoint then
    error("dbml.Reference: from/to must be dbml.Endpoint instances", 2)
  end
  if not M.is_operator(values.operator) then
    error("dbml.Reference: invalid operator '" .. tostring(values.operator) .. "'", 2)
  end
  if values.source ~= "top_level" and values.source ~= "inline" then
    error("dbml.Reference: invalid source '" .. tostring(values.source) .. "'", 2)
  end

  local self = setmetatable({}, Reference)
  for key, value in pairs(values) do
    self[key] = value
  end
  self.kind = self.kind or "ref_expression"
  return self
end

M.Endpoint = Endpoint
M.Reference = Reference

--- All references in a document: top-level expressions and inline refs.
---@param ast table
---@return dbml.Reference[]
function M.all(ast)
  local result = {}

  for _, ref in ipairs(ast.refs or {}) do
    for _, expression in ipairs(ref.expressions or {}) do
      result[#result + 1] = expression
    end
  end

  for _, table in ipairs(ast.tables or {}) do
    for _, column in ipairs(table.columns or {}) do
      for _, setting in ipairs(column.settings or {}) do
        if setting.ref then
          result[#result + 1] = setting.ref
        end
      end
    end
  end

  return result
end

return M
