-- Token-preserving DBML formatter.
--
-- The formatter only changes whitespace: indentation, blank lines, and
-- intra-line spacing.  Comments, strings, backtick expressions, quoting,
-- casing, ordering, and every other source character are preserved.

local lexer = require("dbml.lexer")
local refs = require("dbml.ref")

local M = {}

local OPERATOR_VALUES = {
  ["<"] = true,
  [">"] = true,
  ["-"] = true,
  ["<>"] = true,
  ["?"] = true,
}

local DELIMITERS = {
  [","] = true,
  ["]"] = true,
  ["}"] = true,
  [")"] = true,
  [";"] = true,
}

---@param value string
---@return integer
local function count_newlines(value)
  local _, count = value:gsub("\n", "")
  return count
end

---@param token dbml.Token
---@return boolean
local function is_atom(token)
  return token.type == "word"
    or token.type == "number"
    or token.type == "string"
    or token.type == "expression"
    or token.type == "raw"
end

---@param analysis dbml.Analysis
---@return dbml.Range[]
local function build_raw_spans(analysis)
  local spans = {}

  for _, table in ipairs(analysis.ast.tables) do
    for _, index in ipairs(table.indexes or {}) do
      for _, expression in ipairs(index.expressions or {}) do
        spans[#spans + 1] = expression.range
      end
    end
  end

  table.sort(spans, function(a, b)
    return a.start < b.start
  end)
  return spans
end

---@param tokens dbml.Token[]
---@param text string
---@param spans dbml.Range[]
---@return dbml.Token[]
local function preprocess_tokens(tokens, text, spans)
  ---@type table<integer, dbml.Range?>
  local span_by_start = {}
  for _, span in ipairs(spans) do
    span_by_start[span.start] = span
  end

  local result = {}
  local i = 1
  while i <= #tokens do
    local token = tokens[i]
    local span = span_by_start[token.start]

    if span then
      local last = i
      while last + 1 <= #tokens and tokens[last + 1].stop <= span.stop do
        last = last + 1
      end
      result[#result + 1] = {
        type = "raw",
        value = text:sub(span.start + 1, span.stop),
        start = span.start,
        stop = span.stop,
        line = token.line,
        col = token.col,
      }
      i = last + 1
    elseif token.type == "punct" and token.value == "#" then
      local last = i
      while last + 1 <= #tokens do
        local following = tokens[last + 1]
        if following.type == "eof"
          or following.type == "comment"
          or following.line ~= token.line
          or (following.type == "punct" and DELIMITERS[following.value]) then
          break
        end
        last = last + 1
      end
      result[#result + 1] = {
        type = "raw",
        value = text:sub(token.start + 1, tokens[last].stop),
        start = token.start,
        stop = tokens[last].stop,
        line = token.line,
        col = token.col,
      }
      i = last + 1
    else
      result[#result + 1] = token
      i = i + 1
    end
  end

  return result
end

---@param analysis dbml.Analysis
---@param text string
---@return table<integer, boolean?>
local function build_entry_starts(analysis, text)
  ---@type table<integer, boolean?>
  local starts = {}
  local function add(offset)
    if offset then
      starts[offset] = true
    end
  end

  for _, table in ipairs(analysis.ast.tables) do
    for _, column in ipairs(table.columns) do
      add(column.start)
    end
    add(table.indexes_range and table.indexes_range.start)
    for _, index in ipairs(table.indexes or {}) do
      add(index.start)
    end
    for _, include in ipairs(table.includes or {}) do
      if text:sub(include.range.start, include.range.start) == "~" then
        add(include.range.start - 1)
      else
        add(include.range.start)
      end
    end
    if table.note then
      add(table.note.range.start)
    end
  end

  for _, enum in ipairs(analysis.ast.enums) do
    for _, value in ipairs(enum.values) do
      add(value.start)
    end
    if enum.note then
      add(enum.note.range.start)
    end
  end

  for _, group in ipairs(analysis.ast.groups) do
    for _, member in ipairs(group.members) do
      add(member.range.start)
    end
    if group.note then
      add(group.note.range.start)
    end
  end

  for _, project in ipairs(analysis.ast.projects) do
    for _, setting in ipairs(project.settings) do
      add(setting.key_range.start)
    end
  end

  for _, ref in ipairs(analysis.ast.refs) do
    if ref.body_start then
      for _, expression in ipairs(ref.expressions) do
        add(expression.range.start)
      end
    end
  end

  return starts
end

---@param analysis dbml.Analysis
---@return table<integer, string?>
local function build_statement_info(analysis)
  ---@type table<integer, string?>
  local starts = {}
  for _, statement in ipairs(analysis.ast.statements) do
    starts[statement.range.start] = statement.kind
  end
  return starts
end

---@param tokens dbml.Token[]
---@param analysis dbml.Analysis
---@return table<integer, integer?>
local function build_operator_groups(tokens, analysis)
  ---@type table<integer, integer?>
  local groups = {}
  local next_id = 0

  for _, reference in ipairs(refs.all(analysis.ast)) do
    next_id = next_id + 1
    local start_offset
    if reference.source == "inline" then
      start_offset = reference.range.start
    else
      start_offset = reference.from.range.stop
    end
    local stop_offset = reference.to.range.start

    for _, token in ipairs(tokens) do
      if token.start >= start_offset and token.stop <= stop_offset
        and token.type == "punct" and OPERATOR_VALUES[token.value] then
        groups[token.start] = next_id
      end
    end
  end

  return groups
end

---@param tokens dbml.Token[]
---@param operator_groups table<integer, integer?>
---@return table<integer, boolean?>
local function build_unary_minus(tokens, operator_groups)
  ---@type table<integer, boolean?>
  local unary = {}
  for i, token in ipairs(tokens) do
    if token.type == "punct" and token.value == "-" and not operator_groups[token.start] then
      local previous = tokens[i - 1]
      if not previous
        or previous.value == ":"
        or previous.value == ","
        or previous.value == "["
        or previous.value == "("
        or previous.value == "=" then
        unary[token.start] = true
      end
    end
  end
  return unary
end

---@param previous dbml.Token?
---@param current dbml.Token
---@param operator_groups table<integer, integer?>
---@param unary_minus table<integer, boolean?>
---@return boolean
local function needs_space(previous, current, operator_groups, unary_minus)
  if not previous then
    return false
  end
  if previous.type == "comment" or current.type == "comment" then
    return true
  end

  local pv, cv = previous.value, current.value
  local pg = operator_groups[previous.start]
  local cg = operator_groups[current.start]

  if pg and cg and pg == cg then
    return false
  end
  if cg or pg then
    return true
  end
  if unary_minus[previous.start] then
    return false
  end

  if cv == "," or cv == ")" or cv == "]" or cv == "}" or cv == ":"
    or cv == ";" or cv == "." then
    return false
  end
  if pv == "," or pv == ":" then
    return true
  end
  if pv == "(" or pv == "[" or pv == "." or pv == "~" or pv == "#" then
    return false
  end
  if cv == "(" then
    return pv:lower() == "records"
  end
  if cv == "[" or cv == "{" then
    return true
  end
  if pv == "{" or pv == "}" then
    return true
  end
  if pv == "]" or pv == ")" then
    return true
  end
  if is_atom(previous) and is_atom(current) then
    return true
  end

  return false
end

---@param token dbml.Token
---@param text string
---@return string
local function raw_text(token, text)
  if token.type == "string"
    or token.type == "expression"
    or token.type == "comment"
    or token.type == "raw" then
    return text:sub(token.start + 1, token.stop)
  end
  return token.value
end

---@param analysis dbml.Analysis
---@param document dbml.Document
---@param options dbml.FormattingOptions?
---@return string?
function M.format(analysis, document, options)
  if #analysis.errors > 0 then
    return nil
  end

  local text = document.text
  if text == "" then
    return nil
  end

  options = options or {}
  local tab_size = math.max(1, options.tabSize or 2)
  local indent_unit = options.insertSpaces == false
      and "\t"
    or string.rep(" ", tab_size)

  local tokens = lexer.tokenize(text, { comments = true })
  tokens = preprocess_tokens(tokens, text, build_raw_spans(analysis))

  local entry_starts = build_entry_starts(analysis, text)
  local statement_starts = build_statement_info(analysis)
  local operator_groups = build_operator_groups(tokens, analysis)
  local unary_minus = build_unary_minus(tokens, operator_groups)

  ---@type string[]
  local output = {}
  local depth = 0
  local at_line_start = true
  ---@type dbml.Token?
  local previous = nil
  ---@type dbml.Token?
  local previous_non_comment = nil
  ---@type string?
  local last_statement_kind = nil

  ---@param value string
  local function append(value)
    output[#output + 1] = value
    at_line_start = value:sub(-1) == "\n"
  end

  ---@param count integer
  local function append_newlines(count)
    if count > 0 then
      append(string.rep("\n", count))
    end
  end

  ---@param level integer
  local function append_indent(level)
    if at_line_start then
      append(string.rep(indent_unit, level))
      at_line_start = false
    end
  end

  for i, token in ipairs(tokens) do
    if token.type == "eof" then
      break
    end

    local gap = previous and count_newlines(text:sub(previous.stop + 1, token.start)) or 0
    if token.value == "}" then
      depth = math.max(depth - 1, 0)
    end

    local newlines = gap > 0 and math.min(gap, 2) or 0
    local inline_comment = previous ~= nil
      and previous.type == "comment"
      and gap == 0
    local statement_kind = statement_starts[token.start]

    if previous then
      if token.value == "}" and previous.value ~= "{" then
        newlines = math.max(newlines, 1)
      end
      if previous.value == "{" and token.value ~= "}"
        and not (token.type == "comment" and gap == 0) then
        newlines = math.max(newlines, 1)
      end
      if entry_starts[token.start] and previous.value ~= "{"
        and not inline_comment then
        newlines = math.max(newlines, 1)
      end

      if token.type == "word" and depth > 0 and previous.value ~= "{"
        and not inline_comment then
        local lower = token.value:lower()
        local following = tokens[i + 1]
        local block_entry = false
        if lower == "checks" then
          block_entry = following ~= nil and following.value == "{"
        elseif lower == "records" then
          block_entry = following ~= nil
            and (following.value == "(" or following.value == "{" or following.value == "[")
        end
        if block_entry then
          newlines = math.max(newlines, 1)
        end
      end

      if depth == 0 and token.type == "comment" and previous.type ~= "comment"
        and gap > 0 then
        newlines = math.max(newlines, 2)
      end

      if statement_kind then
        local required
        if statement_kind == "ref" and last_statement_kind == "ref" then
          required = 1
        else
          required = 2
        end

        if previous.type == "comment" then
          local trailing = previous_non_comment
            and previous.line == previous_non_comment.line
          if not trailing then
            required = 1
          end
        end

        newlines = math.max(newlines, required)
      end
    end

    if statement_kind then
      last_statement_kind = statement_kind
    end

    local need_space = newlines == 0 and not at_line_start
    append_newlines(newlines)
    append_indent(depth)

    if need_space and previous
      and needs_space(previous, token, operator_groups, unary_minus) then
      append(" ")
    end

    append(raw_text(token, text))

    if token.value == "{" then
      depth = depth + 1
    end

    previous = token
    if token.type ~= "comment" then
      previous_non_comment = token
    end
  end

  local result = table.concat(output)
  result = result:gsub("\n+$", "")

  if result ~= "" then
    result = result .. "\n"
  end

  if result == text then
    return nil
  end
  return result
end

return M
