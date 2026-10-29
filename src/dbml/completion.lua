-- Completion for DBML.
--
-- Context detection is token-based rather than regex-only, so it keeps
-- working while a statement is still half-typed (the parser is
-- deliberately tolerant).

local symbols = require("dbml.symbols")

local M = {}

local KEYWORDS = {
  {
    label = "Table",
    detail = "table definition",
    snippet = "Table ${1:name} {\n  ${2:id} ${3:integer} [pk]\n}",
    documentation = "Define a table and its columns.",
  },
  {
    label = "Enum",
    detail = "enum definition",
    snippet = "Enum ${1:name} {\n  ${2:value}\n}",
    documentation = "Define an enum type.",
  },
  {
    label = "Ref",
    detail = "relationship",
    snippet = "Ref: ${1:table}.${2:column} > ${3:table}.${4:column}",
    documentation = "Define a relationship between two columns.",
  },
  {
    label = "TableGroup",
    detail = "table group",
    snippet = "TableGroup ${1:name} {\n  ${2:table}\n}",
    documentation = "Group related tables together.",
  },
  {
    label = "Project",
    detail = "project metadata",
    snippet = "Project ${1:name} {\n  database_type: '${2:PostgreSQL}'\n  Note: '${3:note}'\n}",
    documentation = "Project-level metadata for the schema.",
  },
}

local TYPES = {
  "integer", "int", "bigint", "smallint", "serial", "bigserial",
  "varchar", "char", "text", "boolean", "bool",
  "date", "datetime", "time", "timestamp",
  "decimal", "numeric", "float", "double", "real",
  "json", "jsonb", "uuid", "blob", "binary", "varbinary",
}

local SETTINGS = {
  { label = "pk", detail = "primary key" },
  { label = "unique", detail = "unique constraint" },
  { label = "not null", detail = "not null constraint" },
  { label = "null", detail = "nullable column" },
  { label = "increment", detail = "auto-increment" },
  { label = "default", detail = "default value" },
  { label = "note", detail = "column note" },
  { label = "ref", detail = "inline relationship" },
  { label = "name", detail = "index / constraint name" },
  { label = "type", detail = "index type" },
  { label = "delete", detail = "on delete action" },
  { label = "update", detail = "on update action" },
  { label = "color", detail = "display color" },
  { label = "headercolor", detail = "header color" },
}

local OPERATORS = {
  { label = ">", detail = "many-to-one" },
  { label = "<", detail = "one-to-many" },
  { label = "-", detail = "one-to-one" },
  { label = "<>", detail = "many-to-many" },
}

local function is_identifier_byte(byte)
  if not byte then
    return false
  end
  return (byte >= 48 and byte <= 57)
    or (byte >= 65 and byte <= 90)
    or (byte >= 97 and byte <= 122)
    or byte == 95
    or byte >= 128
end

local function prefix_at(text, offset)
  local i = offset
  while i > 0 and is_identifier_byte(text:byte(i)) do
    i = i - 1
  end
  return i, text:sub(i + 1, offset)
end

local function previous_token(tokens, offset)
  local previous, previous_index
  for i = 1, #tokens do
    local token = tokens[i]
    if token.type == "eof" then
      break
    end
    if token.stop <= offset then
      previous = token
      previous_index = i
    elseif token.start < offset then
      -- Cursor is inside this token; the token before it is the
      -- last complete one.
      break
    else
      break
    end
  end
  return previous, previous_index
end

local function tokens_on_line(tokens, line, offset)
  local result = {}
  for i = 1, #tokens do
    local token = tokens[i]
    if token.type == "eof" then
      break
    end
    if token.line == line then
      if token.start < offset then
        result[#result + 1] = token
      end
    elseif token.line > line then
      break
    end
  end
  return result
end

local function contains(range, offset)
  return range ~= nil and range.start <= offset and offset <= range.stop
end

local function find_table_at(ast, offset)
  local best
  for _, table in ipairs(ast.tables) do
    if table.body_start and contains({
      start = table.body_start,
      stop = table.body_end or table.stop,
    }, offset) then
      local size = (table.body_end or table.stop) - table.body_start
      local best_size = best and ((best.body_end or best.stop) - best.body_start) or nil
      if not best or size <= best_size then
        best = table
      end
    end
  end
  return best
end

local function find_enum_at(ast, offset)
  for _, enum in ipairs(ast.enums) do
    if enum.body_start and contains({
      start = enum.body_start,
      stop = enum.body_end or enum.stop,
    }, offset) then
      return enum
    end
  end
  return nil
end

local function find_ref_setting_at(ast, offset)
  for _, table in ipairs(ast.tables) do
    for _, column in ipairs(table.columns) do
      for _, setting in ipairs(column.settings or {}) do
        if setting.key and setting.key:lower() == "ref"
          and contains(setting.value_range, offset) then
          return setting
        end
      end
    end
  end
  return nil
end

local function find_indexes_at(ast, offset)
  for _, table in ipairs(ast.tables) do
    if contains(table.indexes_body_range, offset) then
      return table
    end
  end
  return nil
end

local function find_settings_at(ast, offset)
  local function check(range)
    if contains(range, offset) then
      return true
    end
  end

  for _, table in ipairs(ast.tables) do
    if check(table.settings_range) then
      return true
    end
    for _, column in ipairs(table.columns) do
      if check(column.settings_range) then
        return true
      end
    end
    for _, index in ipairs(table.indexes or {}) do
      if check(index.settings_range) then
        return true
      end
    end
  end

  for _, enum in ipairs(ast.enums) do
    if check(enum.settings_range) then
      return true
    end
    for _, value in ipairs(enum.values) do
      if check(value.settings_range) then
        return true
      end
    end
  end

  for _, group in ipairs(ast.groups) do
    if check(group.settings_range) then
      return true
    end
  end

  for _, ref in ipairs(ast.refs) do
    for _, expression in ipairs(ref.expressions) do
      if check(expression.settings_range) then
        return true
      end
    end
  end

  return false
end

local function find_ref_at(ast, offset)
  for _, ref in ipairs(ast.refs) do
    if contains(ref.range, offset) then
      return ref
    end
  end
  return nil
end

local function find_project_at(ast, offset)
  for _, project in ipairs(ast.projects) do
    if project.body_start and contains({
      start = project.body_start,
      stop = project.body_end or project.stop,
    }, offset) then
      return project
    end
  end
  return nil
end

local function find_group_at(ast, offset)
  for _, group in ipairs(ast.groups) do
    if group.body_start and contains({
      start = group.body_start,
      stop = group.body_end or group.stop,
    }, offset) then
      return group
    end
  end
  return nil
end

local function line_has_open_bracket(line_tokens)
  local depth = 0
  for _, token in ipairs(line_tokens) do
    if token.type == "punct" and token.value == "[" then
      depth = depth + 1
    elseif token.type == "punct" and token.value == "]" then
      depth = math.max(0, depth - 1)
    end
  end
  return depth > 0
end

local function line_is_ref(document, offset)
  local line = document:position_at(offset).line
  local start = document:line_start_offset(line)
  local before = document.text:sub(start + 1, offset)
  return before:match("^%s*[Rr]ef%s*$") ~= nil
    or before:match("^%s*[Rr]ef%s*[:{]") ~= nil
    or before:match("^%s*[Rr]ef%s+[^%s:]+%s*:") ~= nil
    or before:match("^%s*[Rr]ef%s+[^%s:]+%s*$") ~= nil
end

local function make_item(document, prefix_start, offset, spec, snippets)
  local new_text = spec.label
  local insert_text_format
  if spec.snippet and snippets then
    new_text = spec.snippet
    insert_text_format = 2 -- InsertTextFormat.Snippet
  end

  local item = {
    label = spec.label,
    kind = spec.kind or 14, -- Keyword
    detail = spec.detail,
    sortText = spec.sort_text or spec.label,
    filterText = spec.filter_text or spec.label,
    insertText = new_text,
    textEdit = {
      range = {
        start = document:position_at(prefix_start),
        ["end"] = document:position_at(offset),
      },
      newText = new_text,
    },
  }
  if insert_text_format then
    item.insertTextFormat = insert_text_format
  end
  if spec.documentation then
    item.documentation = spec.documentation
  end
  return item
end

local function push(items, seen, item)
  local key = tostring(item.kind) .. "\0" .. item.label
  if not seen[key] then
    seen[key] = true
    items[#items + 1] = item
  end
end

local function keyword_items(document, prefix_start, offset, snippets)
  local items = {}
  for _, keyword in ipairs(KEYWORDS) do
    items[#items + 1] = make_item(document, prefix_start, offset, {
      label = keyword.label,
      kind = 14,
      detail = keyword.detail,
      snippet = keyword.snippet,
      documentation = keyword.documentation,
      sort_text = "0_" .. keyword.label,
    }, snippets)
  end
  return items
end

local function type_items(document, prefix_start, offset, analysis)
  local items, seen = {}, {}
  for _, name in ipairs(TYPES) do
    push(items, seen, make_item(document, prefix_start, offset, {
      label = name,
      kind = 26, -- TypeParameter
      detail = "type",
      sort_text = "1_" .. name,
    }, false))
  end
  for _, enum in ipairs(analysis.symbols.enum_list) do
    push(items, seen, make_item(document, prefix_start, offset, {
      label = enum.name,
      kind = 10, -- Enum
      detail = "enum type",
      sort_text = "1_" .. enum.name,
    }, false))
  end
  return items
end

local function setting_items(document, prefix_start, offset)
  local items = {}
  for _, setting in ipairs(SETTINGS) do
    items[#items + 1] = make_item(document, prefix_start, offset, {
      label = setting.label,
      kind = 14,
      detail = setting.detail,
      sort_text = "0_" .. setting.label,
    }, false)
  end
  return items
end

local function table_items(document, prefix_start, offset, analysis, include_enums)
  local items, seen = {}, {}
  for _, table in ipairs(analysis.symbols.table_list) do
    push(items, seen, make_item(document, prefix_start, offset, {
      label = table.full_name,
      kind = 5, -- Class
      detail = table.alias and ("table (alias " .. table.alias .. ")") or "table",
      sort_text = "2_" .. table.full_name,
    }, false))
  end
  if include_enums ~= false then
    for _, enum in ipairs(analysis.symbols.enum_list) do
      push(items, seen, make_item(document, prefix_start, offset, {
        label = enum.name,
        kind = 10, -- Enum
        detail = "enum",
        sort_text = "2_" .. enum.name,
      }, false))
    end
  end
  return items
end

local function column_items(table, document, prefix_start, offset)
  local items, seen = {}, {}
  for _, column in ipairs(table.columns) do
    push(items, seen, make_item(document, prefix_start, offset, {
      label = column.name,
      kind = 8, -- Field
      detail = column.type and ("column of " .. table.full_name .. " — " .. column.type)
        or ("column of " .. table.full_name),
      sort_text = "3_" .. column.name,
    }, false))
  end
  return items
end

local function enum_value_items(enum, document, prefix_start, offset)
  local items, seen = {}, {}
  for _, value in ipairs(enum.values) do
    push(items, seen, make_item(document, prefix_start, offset, {
      label = value.name,
      kind = 22, -- EnumMember
      detail = "value of " .. enum.name,
      sort_text = "3_" .. value.name,
    }, false))
  end
  return items
end

local function operator_items(document, prefix_start, offset)
  local items = {}
  for _, operator in ipairs(OPERATORS) do
    items[#items + 1] = make_item(document, prefix_start, offset, {
      label = operator.label,
      kind = 25, -- Operator
      detail = operator.detail,
      sort_text = "0_" .. operator.label,
    }, false)
  end
  return items
end

local function index_items(table, document, prefix_start, offset)
  local items, seen = {}, {}
  for _, column in ipairs(table.columns) do
    push(items, seen, make_item(document, prefix_start, offset, {
      label = column.name,
      kind = 8,
      detail = "column of " .. table.full_name,
      sort_text = "3_" .. column.name,
    }, false))
  end
  for _, label in ipairs({ "unique", "pk", "name", "type" }) do
    push(items, seen, make_item(document, prefix_start, offset, {
      label = label,
      kind = 14,
      detail = "index setting",
      sort_text = "0_" .. label,
    }, false))
  end
  return items
end

local function body_items(document, prefix_start, offset, snippets)
  local items = {}
  items[#items + 1] = make_item(document, prefix_start, offset, {
    label = "indexes",
    kind = 14,
    detail = "index block",
    snippet = "indexes {\n  (${1:column})\n}",
    sort_text = "0_indexes",
  }, snippets)
  items[#items + 1] = make_item(document, prefix_start, offset, {
    label = "Note",
    kind = 14,
    detail = "table note",
    snippet = "Note: '${1:note}'",
    sort_text = "0_Note",
  }, snippets)
  return items
end

local function project_key_items(document, prefix_start, offset, snippets)
  return {
    make_item(document, prefix_start, offset, {
      label = "database_type",
      kind = 20, -- Key
      detail = "project database type",
      snippet = "database_type: '${1:PostgreSQL}'",
      sort_text = "0_database_type",
    }, snippets),
    make_item(document, prefix_start, offset, {
      label = "Note",
      kind = 20,
      detail = "project note",
      snippet = "Note: '${1:note}'",
      sort_text = "0_Note",
    }, snippets),
  }
end

-- Ref, project, group, and top-level keyword contexts.
local function structural_or_keyword(analysis, document, offset, prefix_start, line_tokens, previous, snippets)
  if find_ref_at(analysis.ast, offset) or line_is_ref(document, offset) then
    if previous and previous.type == "word" and offset > previous.stop then
      return operator_items(document, prefix_start, offset)
    end
    return table_items(document, prefix_start, offset, analysis, false)
  end

  if find_project_at(analysis.ast, offset) then
    return project_key_items(document, prefix_start, offset, snippets)
  end

  local group = find_group_at(analysis.ast, offset)
  if group then
    return table_items(document, prefix_start, offset, analysis, false)
  end

  local first = line_tokens[1]
  if first and first.type == "word" then
    local keyword = first.value:lower()
    if keyword == "table" or keyword == "enum" or keyword == "tablegroup"
      or keyword == "project" or keyword == "tablepartial" then
      return {}
    end
  end

  return keyword_items(document, prefix_start, offset, snippets)
end

function M.complete(analysis, document, position, options)
  options = options or {}
  local snippets = options.snippets == true
  local offset = document:offset_at(position)
  local text = document.text
  local prefix_start = prefix_at(text, offset)
  local tokens = analysis.tokens
  local previous, previous_index = previous_token(tokens, offset)
  local line_tokens = tokens_on_line(tokens, position.line, offset)

  -- Member access (`table.` / `alias.`) wins over everything else.
  if previous and previous.type == "punct" and previous.value == "." then
    local receiver = previous_index and tokens[previous_index - 1] or nil
    if receiver and (receiver.type == "word" or receiver.type == "string") then
      local table = symbols.find_table(analysis.symbols, receiver.value)
      if table then
        return column_items(table, document, prefix_start, offset)
      end
      local enum = symbols.find_enum(analysis.symbols, receiver.value)
      if enum then
        return enum_value_items(enum, document, prefix_start, offset)
      end
    end
    return {}
  end

  -- Inline refs: `[ref: > table.column]`.  The parser may not have
  -- closed the settings list yet, so look at the operator token itself.
  if previous and previous.type == "punct"
    and (previous.value == ">" or previous.value == "<"
      or previous.value == "-" or previous.value == "<>") then
    return table_items(document, prefix_start, offset, analysis, false)
  end

  if find_ref_setting_at(analysis.ast, offset) then
    return table_items(document, prefix_start, offset, analysis, false)
  end

  if find_settings_at(analysis.ast, offset) then
    return setting_items(document, prefix_start, offset)
  end

  local indexes_table = find_indexes_at(analysis.ast, offset)
  if indexes_table then
    return index_items(indexes_table, document, prefix_start, offset)
  end

  local table = find_table_at(analysis.ast, offset)
  if table then
    local relevant = {}
    for _, token in ipairs(line_tokens) do
      if token.start >= (table.body_start or 0) then
        relevant[#relevant + 1] = token
      end
    end

    if line_has_open_bracket(relevant) then
      return setting_items(document, prefix_start, offset)
    end

    local first = relevant[1]
    if not first then
      return body_items(document, prefix_start, offset, snippets)
    end
    if first.type == "word" and first.value:lower() == "indexes" then
      return body_items(document, prefix_start, offset, snippets)
    end
    if first.type == "word" and first.value:lower() == "note" then
      return {}
    end

    -- Type position: `id ` or `id int`.
    if #relevant == 1 then
      if previous and offset > previous.stop then
        return type_items(document, prefix_start, offset, analysis)
      end
    elseif #relevant == 2 and relevant[2].type == "word" then
      return type_items(document, prefix_start, offset, analysis)
    end
    return {}
  end

  local enum = find_enum_at(analysis.ast, offset)
  if enum then
    local relevant = {}
    for _, token in ipairs(line_tokens) do
      if token.start >= (enum.body_start or 0) then
        relevant[#relevant + 1] = token
      end
    end
    if #relevant == 0 then
      return {
        make_item(document, prefix_start, offset, {
          label = "Note",
          kind = 14,
          detail = "enum note",
          snippet = "Note: '${1:note}'",
          sort_text = "0_Note",
        }, snippets),
      }
    end
    return {}
  end

  return structural_or_keyword(analysis, document, offset, prefix_start, line_tokens, previous, snippets)
end

return M
