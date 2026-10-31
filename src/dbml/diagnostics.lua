-- Conservative diagnostics for DBML.
--
-- Errors are reserved for things that are definitely wrong in the
-- current file: syntax errors, duplicate definitions, and unknown
-- columns in indexes.  Unresolved references are warnings because this
-- server is intentionally single-file; the target may live elsewhere.
--
-- Tables that include a TablePartial (`~base`) inherit columns that the
-- parser does not merge yet, so column-resolution checks are skipped for
-- those tables to avoid false positives.

local refs = require("dbml.ref")
local symbols = require("dbml.symbols")

local M = {}

M.severity = {
  ERROR = 1,
  WARNING = 2,
  INFO = 3,
  HINT = 4,
}

local ERROR = M.severity.ERROR
local WARNING = M.severity.WARNING

---@param document dbml.Document
---@param range dbml.Range
---@return dbml.Range
local function normalize_range(document, range)
  local length = #document.text
  local start = math.max(0, math.min(length, range.start or 0))
  local stop = math.max(start, math.min(length, range.stop or start))

  -- Zero-width ranges (typically an error at EOF) are awkward in
  -- clients.  Widen them to cover the previous byte.
  if stop == start and start > 0 then
    start = start - 1
    stop = math.min(length, start + 1)
  end

  return { start = start, stop = stop }
end

---@param document dbml.Document
---@param range dbml.Range
---@return dbml.LspRange
local function lsp_range(document, range)
  local normalized = normalize_range(document, range)
  return {
    start = document:position_at(normalized.start),
    ["end"] = document:position_at(normalized.stop),
  }
end

---@param document dbml.Document
---@param offset integer
---@return integer
local function line_number(document, offset)
  return document:position_at(offset).line + 1
end

---@param items dbml.DiagnosticEntry[]
---@param document dbml.Document
---@param range dbml.Range?
---@param severity integer
---@param code string
---@param message string
---@param related_entries dbml.RelatedEntry[]?
local function add(items, document, range, severity, code, message, related_entries)
  if not range then
    return
  end

  local normalized = normalize_range(document, range)
  local diagnostic = {
    range = lsp_range(document, normalized),
    severity = severity,
    code = code,
    source = "dbml-ls",
    message = message,
  }

  if related_entries and #related_entries > 0 then
    diagnostic.relatedInformation = {}
    for _, entry in ipairs(related_entries) do
      diagnostic.relatedInformation[#diagnostic.relatedInformation + 1] = {
        location = {
          uri = document.uri,
          range = lsp_range(document, entry.range),
        },
        message = entry.message or "First definition",
      }
    end
  end

  items[#items + 1] = {
    start = normalized.start,
    stop = normalized.stop,
    key = code .. ":" .. normalized.start .. ":" .. normalized.stop .. ":" .. message,
    diagnostic = diagnostic,
  }
end

---@param items dbml.DiagnosticEntry[]
---@return dbml.Diagnostic[]
local function finish(items)
  table.sort(items, function(a, b)
    if a.start ~= b.start then
      return a.start < b.start
    end
    if a.stop ~= b.stop then
      return a.stop < b.stop
    end
    return tostring(a.diagnostic.code) < tostring(b.diagnostic.code)
  end)

  local result = {}
  local seen = {}
  for _, item in ipairs(items) do
    if not seen[item.key] then
      seen[item.key] = true
      result[#result + 1] = item.diagnostic
    end
  end
  return result
end

---@param table dbml.Table
---@return boolean
local function has_includes(table)
  return table.includes ~= nil and #table.includes > 0
end

---@param endpoint dbml.Endpoint
---@return string
local function endpoint_table_name(endpoint)
  if endpoint.schema and endpoint.schema ~= "" then
    return endpoint.schema .. "." .. endpoint.table
  end
  return endpoint.table
end

---@param symbol_table dbml.SymbolTable
---@param endpoint dbml.Endpoint
---@return dbml.Table?
local function find_endpoint_table(symbol_table, endpoint)
  return symbols.find_table(symbol_table, endpoint_table_name(endpoint))
    or symbols.find_table(symbol_table, endpoint.table)
end

---@param node { name_range: dbml.Range }
---@param document dbml.Document
---@param message string?
---@return dbml.RelatedEntry[]
local function first_definition(node, document, message)
  local range = node.name_range
  return {
    {
      range = range,
      message = message or ("First definition on line " .. line_number(document, range.start)),
    },
  }
end

---@param items dbml.DiagnosticEntry[]
---@param analysis dbml.Analysis
---@param document dbml.Document
local function add_syntax(items, analysis, document)
  for _, error in ipairs(analysis.errors or {}) do
    add(
      items,
      document,
      { start = error.start, stop = error.stop },
      ERROR,
      "syntax",
      error.message or "Syntax error"
    )
  end
end

---@param items dbml.DiagnosticEntry[]
---@param analysis dbml.Analysis
---@param document dbml.Document
local function add_duplicate_tables(items, analysis, document)
  ---@type table<string, dbml.Table?>
  local seen = {}
  for _, table in ipairs(analysis.ast.tables) do
    local key = (table.partial and "partial:" or "table:") .. table.full_name
    local first = seen[key]
    if first then
      local kind = table.partial and "table partial" or "table"
      add(
        items,
        document,
        table.name_range,
        ERROR,
        "duplicate-table",
        string.format(
          "Duplicate %s '%s' (first defined on line %d)",
          kind,
          table.full_name,
          line_number(document, first.name_range.start)
        ),
        first_definition(first, document)
      )
    else
      seen[key] = table
    end
  end
end

---@param items dbml.DiagnosticEntry[]
---@param analysis dbml.Analysis
---@param document dbml.Document
local function add_duplicate_enums(items, analysis, document)
  ---@type table<string, dbml.Enum?>
  local seen = {}
  for _, enum in ipairs(analysis.ast.enums) do
    local key = enum.full_name or enum.name
    local first = seen[key]
    if first then
      add(
        items,
        document,
        enum.name_range,
        ERROR,
        "duplicate-enum",
        string.format(
          "Duplicate enum '%s' (first defined on line %d)",
          key,
          line_number(document, first.name_range.start)
        ),
        first_definition(first, document)
      )
    else
      seen[key] = enum
    end
  end
end

---@param items dbml.DiagnosticEntry[]
---@param analysis dbml.Analysis
---@param document dbml.Document
local function add_duplicate_columns(items, analysis, document)
  for _, table in ipairs(analysis.ast.tables) do
    ---@type table<string, dbml.Column?>
    local seen = {}
    for _, column in ipairs(table.columns) do
      local first = seen[column.name]
      if first then
        add(
          items,
          document,
          column.name_range,
          ERROR,
          "duplicate-column",
          string.format(
            "Duplicate column '%s' in table '%s' (first defined on line %d)",
            column.name,
            table.full_name,
            line_number(document, first.name_range.start)
          ),
          {
            {
              range = first.name_range,
              message = "First definition on line " .. line_number(document, first.name_range.start),
            },
          }
        )
      else
        seen[column.name] = column
      end
    end
  end
end

---@param items dbml.DiagnosticEntry[]
---@param analysis dbml.Analysis
---@param document dbml.Document
local function add_duplicate_enum_values(items, analysis, document)
  for _, enum in ipairs(analysis.ast.enums) do
    ---@type table<string, dbml.EnumValue?>
    local seen = {}
    for _, value in ipairs(enum.values) do
      local first = seen[value.name]
      if first then
        add(
          items,
          document,
          value.name_range,
          ERROR,
          "duplicate-enum-value",
          string.format(
            "Duplicate value '%s' in enum '%s' (first defined on line %d)",
            value.name,
            enum.name,
            line_number(document, first.name_range.start)
          ),
          {
            {
              range = first.name_range,
              message = "First definition on line " .. line_number(document, first.name_range.start),
            },
          }
        )
      else
        seen[value.name] = value
      end
    end
  end
end

---@param items dbml.DiagnosticEntry[]
---@param analysis dbml.Analysis
---@param document dbml.Document
local function add_duplicate_aliases(items, analysis, document)
  ---@type table<string, dbml.Table?>
  local seen = {}
  for _, table in ipairs(analysis.ast.tables) do
    if table.alias then
      local first = seen[table.alias]
      local current_range = table.alias_range
      local first_range = first and first.alias_range or nil
      if first and current_range and first_range then
        add(
          items,
          document,
          current_range,
          ERROR,
          "duplicate-alias",
          string.format(
            "Duplicate alias '%s' (first used on line %d)",
            table.alias,
            line_number(document, first_range.start)
          ),
          {
            {
              range = first_range,
              message = "First use on line " .. line_number(document, first_range.start),
            },
          }
        )
      else
        seen[table.alias] = table
      end
    end
  end
end

---@param items dbml.DiagnosticEntry[]
---@param analysis dbml.Analysis
---@param document dbml.Document
local function add_duplicate_ref_names(items, analysis, document)
  ---@type table<string, dbml.RefStatement?>
  local seen = {}
  for _, ref in ipairs(analysis.ast.refs) do
    if ref.name then
      local first = seen[ref.name]
      local current_range = ref.name_range
      local first_range = first and first.name_range or nil
      if first and current_range and first_range then
        add(
          items,
          document,
          current_range,
          ERROR,
          "duplicate-ref-name",
          string.format(
            "Duplicate ref name '%s' (first defined on line %d)",
            ref.name,
            line_number(document, first_range.start)
          ),
          {
            {
              range = first_range,
              message = "First definition on line " .. line_number(document, first_range.start),
            },
          }
        )
      else
        seen[ref.name] = ref
      end
    end
  end
end

---@param items dbml.DiagnosticEntry[]
---@param analysis dbml.Analysis
---@param document dbml.Document
local function add_index_diagnostics(items, analysis, document)
  for _, table in ipairs(analysis.ast.tables) do
    -- Inherited columns are unknown to us, so an index may legitimately
    -- reference one.  Skip the whole check for such tables.
    if not has_includes(table) then
      for _, index in ipairs(table.indexes or {}) do
        for _, index_column in ipairs(index.columns or {}) do
          if not symbols.find_column(analysis.symbols, table.full_name, index_column.name) then
            add(
              items,
              document,
              index_column.range,
              ERROR,
              "unknown-index-column",
              string.format(
                "Unknown column '%s' in index on table '%s'",
                index_column.name,
                table.full_name
              )
            )
          end
        end
      end
    end
  end
end

---@param items dbml.DiagnosticEntry[]
---@param analysis dbml.Analysis
---@param document dbml.Document
local function add_group_diagnostics(items, analysis, document)
  for _, group in ipairs(analysis.ast.groups) do
    for _, member in ipairs(group.members) do
      if not symbols.find_table(analysis.symbols, member.name) then
        add(
          items,
          document,
          member.range,
          WARNING,
          "unresolved-table-group-member",
          string.format(
            "Unknown table '%s' in table group '%s'",
            member.name,
            group.name
          )
        )
      end
    end
  end
end

---@param items dbml.DiagnosticEntry[]
---@param analysis dbml.Analysis
---@param document dbml.Document
local function add_partial_diagnostics(items, analysis, document)
  for _, table in ipairs(analysis.ast.tables) do
    for _, include in ipairs(table.includes or {}) do
      local partial = symbols.find_table(analysis.symbols, include.name)
      if not partial or not partial.partial then
        add(
          items,
          document,
          include.range,
          WARNING,
          "unresolved-partial",
          string.format("Unknown table partial '%s'", include.name)
        )
      end
    end
  end
end

---@param items dbml.DiagnosticEntry[]
---@param analysis dbml.Analysis
---@param document dbml.Document
---@param endpoint dbml.Endpoint
local function check_endpoint(items, analysis, document, endpoint)
  local table = find_endpoint_table(analysis.symbols, endpoint)
  if not table then
    add(
      items,
      document,
      endpoint.table_range or endpoint.range,
      WARNING,
      "unresolved-ref-table",
      string.format("Unknown table '%s' in ref", endpoint_table_name(endpoint))
    )
    return
  end

  if has_includes(table) then
    return
  end

  if endpoint.columns then
    for _, column in ipairs(endpoint.columns) do
      if not symbols.find_column(analysis.symbols, table.full_name, column.name) then
        add(
          items,
          document,
          column.range,
          WARNING,
          "unresolved-ref-column",
          string.format(
            "Unknown column '%s' in table '%s'",
            column.name,
            table.full_name
          )
        )
      end
    end
    return
  end

  if not symbols.find_column(analysis.symbols, table.full_name, endpoint.column) then
    add(
      items,
      document,
      endpoint.column_range or endpoint.range,
      WARNING,
      "unresolved-ref-column",
      string.format(
        "Unknown column '%s' in table '%s'",
        endpoint.column,
        table.full_name
      )
    )
  end
end

---@param items dbml.DiagnosticEntry[]
---@param analysis dbml.Analysis
---@param document dbml.Document
local function add_ref_diagnostics(items, analysis, document)
  for _, reference in ipairs(refs.all(analysis.ast)) do
    check_endpoint(items, analysis, document, reference.from)
    check_endpoint(items, analysis, document, reference.to)
  end
end

---@param analysis dbml.Analysis
---@param document dbml.Document
---@return dbml.Diagnostic[]
function M.diagnose(analysis, document)
  local items = {}

  add_syntax(items, analysis, document)
  add_duplicate_tables(items, analysis, document)
  add_duplicate_enums(items, analysis, document)
  add_duplicate_columns(items, analysis, document)
  add_duplicate_enum_values(items, analysis, document)
  add_duplicate_aliases(items, analysis, document)
  add_duplicate_ref_names(items, analysis, document)
  add_index_diagnostics(items, analysis, document)
  add_group_diagnostics(items, analysis, document)
  add_partial_diagnostics(items, analysis, document)
  add_ref_diagnostics(items, analysis, document)

  return finish(items)
end

return M
