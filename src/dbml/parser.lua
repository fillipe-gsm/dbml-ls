-- Error-tolerant recursive-descent parser for DBML.
--
-- The parser is deliberately forgiving: a half-typed `Table users {`
-- should still produce a table node so completion can use it.  Every
-- node carries byte ranges; the LSP layer converts them to positions.

local M = {}

local Ref = require("dbml.ref")

local concat = table.concat

local Parser = {}
Parser.__index = Parser

function Parser.new(tokens, text)
  return setmetatable({
    tokens = tokens,
    text = text or "",
    pos = 1,
    errors = {},
  }, Parser)
end

function Parser:peek(n)
  return self.tokens[self.pos + (n or 0)]
end

function Parser:next()
  local token = self.tokens[self.pos]
  if token and token.type ~= "eof" then
    self.pos = self.pos + 1
  end
  return token
end

function Parser:last_stop()
  local previous = self.tokens[self.pos - 1]
  return previous and previous.stop or 0
end

function Parser:at_punct(value)
  local token = self:peek()
  return token ~= nil and token.type == "punct" and token.value == value
end

function Parser:at_word(value)
  local token = self:peek()
  return token ~= nil and token.type == "word" and token.value:lower() == value
end

function Parser:accept_punct(value)
  if self:at_punct(value) then
    return self:next()
  end
  return nil
end

function Parser:expect_punct(value)
  local token = self:accept_punct(value)
  if not token then
    self:error(self:peek(), "expected '" .. value .. "'")
  end
  return token
end

function Parser:error(token, message)
  token = token or self:peek()
  if not token then
    local offset = self:last_stop()
    token = { start = offset, stop = offset, line = 0, col = 0 }
  end
  self.errors[#self.errors + 1] = {
    message = message,
    start = token.start,
    stop = token.stop,
    line = token.line,
    col = token.col,
  }
end

function Parser:parse_name()
  local token = self:peek()
  if token and (token.type == "word" or token.type == "string") then
    self:next()
    return {
      name = token.value,
      range = { start = token.start, stop = token.stop },
      token = token,
    }
  end
  self:error(token, "expected a name")
  return nil
end

function Parser:parse_qualified_name()
  local first = self:parse_name()
  if not first then
    return nil
  end

  local parts = { first.name }
  local ranges = { first.range }
  local stop = first.range.stop

  while self:at_punct(".") do
    local following = self:peek(1)
    if not following or (following.type ~= "word" and following.type ~= "string") then
      break
    end
    self:next() -- .
    local part = self:parse_name()
    parts[#parts + 1] = part.name
    ranges[#ranges + 1] = part.range
    stop = part.range.stop
  end

  return {
    parts = parts,
    ranges = ranges,
    name = table.concat(parts, "."),
    range = { start = first.range.start, stop = stop },
  }
end

--- Skip a balanced `{ ... }` block.  Strings and backtick expressions are
--- single tokens, so brace counting is safe.
function Parser:skip_balanced_block()
  local open = self:accept_punct("{")
  if not open then
    return
  end
  local depth = 1
  while depth > 0 and self:peek() and self:peek().type ~= "eof" do
    local token = self:next()
    if token.type == "punct" and token.value == "{" then
      depth = depth + 1
    elseif token.type == "punct" and token.value == "}" then
      depth = depth - 1
    end
  end
  if depth > 0 then
    self:error(self:peek(), "unclosed block")
  end
end

function Parser:skip_balanced_parens()
  local open = self:accept_punct("(")
  if not open then
    return
  end
  local depth = 1
  while depth > 0 and self:peek() and self:peek().type ~= "eof" do
    local token = self:next()
    if token.type == "punct" and token.value == "(" then
      depth = depth + 1
    elseif token.type == "punct" and token.value == ")" then
      depth = depth - 1
    end
  end
  if depth > 0 then
    self:error(self:peek(), "unclosed parenthesis")
  end
end

--- Records blocks contain CSV-style sample data.  They are not part of
--- the schema model, so parse the header and skip the body.
function Parser:parse_records()
  local keyword = self:next()
  local name
  local next_token = self:peek()
  if next_token and next_token.type == "word" then
    local parsed = self:parse_qualified_name()
    name = parsed and parsed.name
  end

  if self:at_punct("(") then
    self:skip_balanced_parens()
  end

  local settings, settings_range
  if self:at_punct("[") then
    settings, settings_range = self:parse_settings({ kind = "records" })
  end

  if self:at_punct("{") then
    self:skip_balanced_block()
  else
    self:error(self:peek(), "expected a records block")
    return nil
  end

  return {
    kind = "records",
    name = name,
    settings = settings,
    settings_range = settings_range,
    range = { start = keyword.start, stop = self:last_stop() },
  }
end

--- Consume a setting value without interpreting it.  Used to recover
--- when an inline ref is malformed.
function Parser:skip_setting_value(start_line)
  local depth = 0
  while true do
    local token = self:peek()
    if not token or token.type == "eof" or token.line > start_line then
      break
    end
    if token.type == "punct" and depth == 0
      and (token.value == "," or token.value == "]" or token.value == "}") then
      break
    end
    if token.type == "punct" and (token.value == "(" or token.value == "[") then
      depth = depth + 1
    elseif token.type == "punct" and (token.value == ")" or token.value == "]") then
      depth = depth - 1
    end
    self:next()
  end
end

--- Parse the value of an inline `ref:` setting:
---   [ref: > users.id]
function Parser:parse_inline_ref(context, start_line)
  local first = self:peek()
  local operator = self:parse_operator()
  if not operator then
    self:skip_setting_value(start_line)
    return nil
  end

  local target = self:parse_endpoint()
  if not target then
    self:skip_setting_value(start_line)
    return nil
  end

  local parent = Ref.Endpoint.from_table_column(context.table, context.column)
  return Ref.Reference.new({
    from = parent,
    to = target,
    operator = operator,
    source = "inline",
    parent = parent,
    range = { start = first.start, stop = target.range.stop },
  })
end

-- Settings are the `[pk, not null, note: '...', ref: > users.id]` lists
-- attached to columns, indexes, and refs.  Values are kept as raw source
-- text for display; inline refs additionally get a structured
-- dbml.Reference.
function Parser:parse_settings(context)
  local open = self:expect_punct("[")
  if not open then
    return {}, nil
  end

  local settings = {}
  local start_line = open.line

  while true do
    local token = self:peek()
    if not token or token.type == "eof" then
      break
    end
    if token.type == "punct" and token.value == "]" then
      break
    end
    -- Settings do not wrap onto the next line in DBML.  Stopping at a
    -- newline lets an unterminated setting recover without swallowing
    -- the rest of the document.
    if token.line > start_line then
      break
    end

    if token.type == "punct" and token.value == "," then
      self:next()
    elseif token.type == "word" or token.type == "string" then
      self:next()
      local setting = {
        key = token.value,
        key_range = { start = token.start, stop = token.stop },
      }

      -- Some DBML settings are two words: `not null`, `primary key`.
      local first_word = token.value:lower()
      local second_word = first_word == "not" and "null"
        or first_word == "primary" and "key"
        or nil
      if second_word then
        local following = self:peek()
        if following and following.type == "word"
          and following.value:lower() == second_word
          and following.line == start_line then
          self:next()
          setting.key = first_word .. " " .. second_word
          setting.key_range.stop = following.stop
        end
      end

      if self:at_punct(":") then
        self:next()

        if context and context.kind == "column" and setting.key:lower() == "ref" then
          local first_value = self:peek()
          local reference = self:parse_inline_ref(context, start_line)
          local stop = self:last_stop()
          if reference then
            setting.ref = reference
            setting.value_range = {
              start = reference.range.start,
              stop = reference.range.stop,
            }
          elseif first_value and stop > first_value.start then
            -- Keep the raw range even when the endpoint is incomplete so
            -- completion can still recognize the ref value it is typing.
            setting.value_range = {
              start = first_value.start,
              stop = stop,
            }
          end
          if setting.value_range then
            setting.value = self.text:sub(
              setting.value_range.start + 1,
              setting.value_range.stop
            )
          end
        else
          local first_value = self:peek()
          local depth = 0
          local previous = nil

          while true do
            local value_token = self:peek()
            if not value_token or value_token.type == "eof" then
              break
            end
            if value_token.line > start_line then
              break
            end
            if value_token.type == "punct" and depth == 0
              and (value_token.value == "," or value_token.value == "]"
                or value_token.value == "}") then
              break
            end
            if value_token.type == "punct" and (value_token.value == "(" or value_token.value == "[") then
              depth = depth + 1
            elseif value_token.type == "punct" and (value_token.value == ")" or value_token.value == "]") then
              depth = depth - 1
            end
            self:next()
            previous = value_token
          end

          if first_value and previous then
            setting.value_range = { start = first_value.start, stop = previous.stop }
            if first_value.type == "string" and first_value == previous then
              setting.value = first_value.value
            else
              setting.value = self.text:sub(first_value.start + 1, previous.stop)
            end
          end
        end
      end

      settings[#settings + 1] = setting
    else
      self:error(token, "unexpected token in settings")
      self:next()
    end
  end

  local close = self:accept_punct("]")
  if not close then
    self:error(self:peek(), "unterminated settings")
  end

  return settings, {
    start = open.start,
    stop = close and close.stop or self:last_stop(),
  }
end

function Parser:parse_column(table)
  local name_token = self:next()
  local column = {
    name = name_token.value,
    name_range = { start = name_token.start, stop = name_token.stop },
    start = name_token.start,
    settings = {},
  }

  local type_token = self:peek()
  if type_token
    and (type_token.type == "word" or type_token.type == "string")
    and type_token.line == name_token.line then
    self:next()
    local type_stop = type_token.stop
    local qualified_type = false

    -- Schema-qualified types: v2.job_status
    while self:at_punct(".") do
      local following = self:peek(1)
      if not following or (following.type ~= "word" and following.type ~= "string")
        or following.line ~= name_token.line then
        break
      end
      self:next()
      type_stop = self:next().stop
      qualified_type = true
    end

    column.type = qualified_type and self.text:sub(type_token.start + 1, type_stop)
      or type_token.value
    column.type_range = { start = type_token.start, stop = type_stop }

    -- Type parameters: varchar(255), decimal(10,2), ...
    if self:at_punct("(") then
      local depth = 0
      local previous = nil
      repeat
        local token = self:next()
        if not token or token.type == "eof" then
          break
        end
        previous = token
        if token.type == "punct" and token.value == "(" then
          depth = depth + 1
        elseif token.type == "punct" and token.value == ")" then
          depth = depth - 1
        end
      until depth == 0
      if previous then
        column.type_range.stop = previous.stop
        column.type = self.text:sub(column.type_range.start + 1, column.type_range.stop)
      end
    end
  else
    self:error(type_token, "expected a column type")
  end

  if self:at_punct("[") and self:peek().line == name_token.line then
    local settings, range = self:parse_settings({
      kind = "column",
      table = table,
      column = column,
    })
    column.settings = settings
    column.settings_range = range
  end

  column.stop = (column.settings_range and column.settings_range.stop)
    or (column.type_range and column.type_range.stop)
    or column.name_range.stop
  column.range = { start = column.start, stop = column.stop }
  table.columns[#table.columns + 1] = column
  return column
end

function Parser:parse_note()
  local keyword = self:next()
  self:expect_punct(":")

  local token = self:peek()
  if token and token.type == "string" then
    self:next()
    return {
      text = token.value,
      range = { start = keyword.start, stop = token.stop },
    }
  end

  local parts = {}
  local previous = keyword
  while self:peek() and self:peek().type ~= "eof"
    and self:peek().line == keyword.line
    and not (self:peek().type == "punct" and self:peek().value == "}") do
    previous = self:next()
    parts[#parts + 1] = tostring(previous.value)
  end
  return {
    text = table.concat(parts, " "),
    range = { start = keyword.start, stop = previous.stop },
  }
end

function Parser:parse_parenthesized_index()
  local open = self:next() -- (
  local tokens = {}
  local depth = 0

  while self:peek() and self:peek().type ~= "eof" do
    local token = self:peek()
    if token.type == "punct" and token.value == ")" and depth == 0 then
      break
    end
    self:next()
    tokens[#tokens + 1] = token
    if token.type == "punct" and (token.value == "(" or token.value == "[") then
      depth = depth + 1
    elseif token.type == "punct" and (token.value == ")" or token.value == "]") then
      depth = depth - 1
    end
  end

  local close = self:accept_punct(")")
  if not close then
    self:error(self:peek(), "unclosed index expression")
  end
  if #tokens == 0 then
    self:error(close or self:peek(), "empty index expression")
  end

  local columns = {}
  local complex = false
  for _, token in ipairs(tokens) do
    if token.type == "word" or token.type == "string" then
      columns[#columns + 1] = {
        name = token.value,
        range = { start = token.start, stop = token.stop },
      }
    elseif not (token.type == "punct" and token.value == ",") then
      complex = true
    end
  end

  local stop = close and close.stop or self:last_stop()
  if complex or #columns == 0 then
    return {
      kind = "index",
      columns = {},
      expressions = {
        {
          text = self.text:sub(open.start + 2, close and close.start or #self.text),
          range = { start = open.start, stop = stop },
        },
      },
      has_expression = true,
      start = open.start,
      stop = stop,
    }
  end

  return {
    kind = "index",
    columns = columns,
    expressions = {},
    has_expression = false,
    start = open.start,
    stop = stop,
  }
end

function Parser:parse_index_entry()
  local token = self:peek()
  if not token then
    return nil
  end

  local entry
  if self:at_punct("(") then
    entry = self:parse_parenthesized_index()
  elseif token.type == "word" or token.type == "string" then
    self:next()
    entry = {
      kind = "index",
      columns = {
        { name = token.value, range = { start = token.start, stop = token.stop } },
      },
      expressions = {},
      has_expression = false,
      start = token.start,
      stop = token.stop,
    }
  elseif token.type == "expression" then
    self:next()
    entry = {
      kind = "index",
      columns = {},
      expressions = {
        { text = token.value, range = { start = token.start, stop = token.stop } },
      },
      has_expression = true,
      start = token.start,
      stop = token.stop,
    }
  else
    self:error(token, "expected an index column or expression")
    self:next()
    return nil
  end

  if self:at_punct("[") then
    entry.settings, entry.settings_range = self:parse_settings({ kind = "index" })
  end
  entry.settings = entry.settings or {}
  entry.stop = entry.settings_range and entry.settings_range.stop or entry.stop
  entry.range = { start = entry.start, stop = entry.stop }
  return entry
end

function Parser:parse_indexes(table)
  local keyword = self:next()
  local open = self:expect_punct("{")
  if not open then
    return
  end

  local indexes = {}
  while self:peek() and self:peek().type ~= "eof" and not self:at_punct("}") do
    local entry = self:parse_index_entry()
    if entry then
      indexes[#indexes + 1] = entry
    end
  end

  local close = self:accept_punct("}")
  if not close then
    self:error(self:peek(), "unclosed indexes block")
  end

  table.indexes = indexes
  table.indexes_range = {
    start = keyword.start,
    stop = close and close.stop or #self.text,
  }
  table.indexes_body_range = {
    start = open.stop,
    stop = close and close.start or #self.text,
  }
end

function Parser:parse_table(partial)
  local keyword = self:next()
  local qualified = self:parse_qualified_name()
  if not qualified then
    return nil
  end

  local table = {
    kind = "table",
    partial = partial or false,
    name = qualified.name,
    full_name = qualified.name,
    name_range = qualified.range,
    columns = {},
    indexes = {},
    includes = {},
    start = keyword.start,
  }

  if #qualified.parts > 1 then
    table.name = qualified.parts[#qualified.parts]
    table.schema = concat(qualified.parts, ".", 1, #qualified.parts - 1)
  end

  if self:at_word("as") then
    self:next()
    local alias = self:parse_name()
    if alias then
      table.alias = alias.name
      table.alias_range = alias.range
    end
  end

  -- Optional table settings: Table users [headercolor: #3498DB] { ... }
  if self:at_punct("[") then
    table.settings, table.settings_range = self:parse_settings({
      kind = "table",
      table = table,
    })
  end

  local open = self:expect_punct("{")
  if not open then
    table.stop = qualified.range.stop
    table.range = { start = keyword.start, stop = table.stop }
    return table
  end

  table.body_start = open.stop

  while self:peek() and self:peek().type ~= "eof" and not self:at_punct("}") do
    local token = self:peek()
    if token.type == "word" and token.value:lower() == "indexes"
      and self:peek(1) and self:peek(1).value == "{" then
      self:parse_indexes(table)
    elseif token.type == "word" and token.value:lower() == "note"
      and self:peek(1) and self:peek(1).value == ":" then
      table.note = self:parse_note()
    elseif token.type == "punct" and token.value == "~" then
      self:next()
      local include = self:parse_qualified_name()
      if include then
        table.includes[#table.includes + 1] = {
          name = include.name,
          range = include.range,
        }
      else
        self:error(token, "expected a table partial name")
      end
    elseif token.type == "word" and token.value:lower() == "checks"
      and self:peek(1) and self:peek(1).value == "{" then
      self:next()
      self:skip_balanced_block()
    elseif token.type == "word" and token.value:lower() == "records"
      and self:peek(1)
      and (self:peek(1).value == "(" or self:peek(1).value == "{"
        or self:peek(1).value == "[") then
      self:parse_records()
    elseif token.type == "word" or token.type == "string" then
      self:parse_column(table)
    else
      self:error(token, "unexpected token in table body")
      self:next()
    end
  end

  local close = self:accept_punct("}")
  if not close then
    self:error(self:peek(), "unclosed table '" .. table.name .. "'")
  end

  table.body_end = close and close.start or #self.text
  table.stop = close and close.stop or #self.text
  table.range = { start = keyword.start, stop = table.stop }
  return table
end

function Parser:parse_enum()
  local keyword = self:next()
  local qualified = self:parse_qualified_name()
  if not qualified then
    return nil
  end

  local enum = {
    kind = "enum",
    name = qualified.name,
    full_name = qualified.name,
    name_range = qualified.range,
    values = {},
    start = keyword.start,
  }

  if #qualified.parts > 1 then
    enum.name = qualified.parts[#qualified.parts]
    enum.schema = concat(qualified.parts, ".", 1, #qualified.parts - 1)
  end

  if self:at_punct("[") then
    enum.settings, enum.settings_range = self:parse_settings({
      kind = "enum",
      enum = enum,
    })
  end

  local open = self:expect_punct("{")
  if not open then
    enum.stop = qualified.range.stop
    enum.range = { start = keyword.start, stop = enum.stop }
    return enum
  end
  enum.body_start = open.stop

  while self:peek() and self:peek().type ~= "eof" and not self:at_punct("}") do
    local token = self:peek()
    if token.type == "word" and token.value:lower() == "note"
      and self:peek(1) and self:peek(1).value == ":" then
      enum.note = self:parse_note()
    elseif token.type == "word" or token.type == "string" then
      self:next()
      local value = {
        name = token.value,
        name_range = { start = token.start, stop = token.stop },
        start = token.start,
        settings = {},
      }
      if self:at_punct("[") and self:peek().line == token.line then
        value.settings, value.settings_range = self:parse_settings({
          kind = "enum_value",
          enum = enum,
          value = value,
        })
      end
      value.stop = (value.settings_range and value.settings_range.stop) or token.stop
      value.range = { start = value.start, stop = value.stop }
      enum.values[#enum.values + 1] = value
    else
      self:error(token, "unexpected token in enum body")
      self:next()
    end
  end

  local close = self:accept_punct("}")
  if not close then
    self:error(self:peek(), "unclosed enum '" .. enum.name .. "'")
  end
  enum.body_end = close and close.start or #self.text
  enum.stop = close and close.stop or #self.text
  enum.range = { start = keyword.start, stop = enum.stop }
  return enum
end

function Parser:parse_endpoint()
  local qualified = self:parse_qualified_name()
  if not qualified then
    return nil
  end

  local parts = qualified.parts
  local ranges = qualified.ranges

  -- Composite form: table.(column1, column2)
  if self:at_punct(".") and self:peek(1) and self:peek(1).value == "(" then
    self:next() -- .
    local open = self:next() -- (
    local columns = {}

    while self:peek() and self:peek().type ~= "eof" and not self:at_punct(")") do
      local token = self:peek()
      if token.type == "word" or token.type == "string" then
        self:next()
        columns[#columns + 1] = {
          name = token.value,
          range = { start = token.start, stop = token.stop },
        }
      elseif token.type == "punct" and token.value == "," then
        self:next()
      else
        self:error(token, "expected a column name in composite reference")
        self:next()
      end
    end

    local close = self:accept_punct(")")
    if not close then
      self:error(self:peek(), "unclosed composite reference")
    end
    if #columns == 0 then
      self:error(close or self:peek(), "expected at least one column in composite reference")
      return nil
    end

    return Ref.Endpoint.new({
      schema = #parts > 1 and concat(parts, ".", 1, #parts - 1) or nil,
      table = parts[#parts],
      columns = columns,
      parts = parts,
      ranges = ranges,
      range = {
        start = qualified.range.start,
        stop = close and close.stop or self:last_stop(),
      },
      table_range = qualified.range,
      column_range = {
        start = open.start,
        stop = close and close.stop or self:last_stop(),
      },
    })
  end

  if #parts < 2 then
    self:error(self:peek(), "expected 'table.column' reference")
    return nil
  end

  return Ref.Endpoint.new({
    schema = #parts > 2 and concat(parts, ".", 1, #parts - 2) or nil,
    table = parts[#parts - 1],
    column = parts[#parts],
    parts = parts,
    ranges = ranges,
    name = qualified.name,
    range = qualified.range,
    table_range = ranges[#ranges - 1],
    column_range = ranges[#ranges],
  })
end

function Parser:parse_operator()
  local first = self:peek()
  if not first or first.type ~= "punct" then
    self:error(first, "expected a relationship operator")
    return nil
  end

  local has_prefix = first.value == "?"
  if has_prefix then
    self:next()
  end

  local core = self:peek()
  if not core or core.type ~= "punct" or not Ref.OPERATORS[core.value] then
    self:error(core, "expected a relationship operator")
    return nil
  end
  self:next()

  local has_suffix = false
  local after = self:peek()
  if after and after.type == "punct" and after.value == "?" then
    self:next()
    has_suffix = true
  end

  return (has_prefix and "?" or "") .. core.value .. (has_suffix and "?" or "")
end

function Parser:parse_ref_expression(source)
  local left = self:parse_endpoint()
  if not left then
    return nil
  end

  local operator = self:parse_operator()
  if not operator then
    return nil
  end

  local right = self:parse_endpoint()
  if not right then
    return nil
  end

  return Ref.Reference.new({
    from = left,
    to = right,
    operator = operator,
    source = source or "top_level",
    range = { start = left.range.start, stop = right.range.stop },
  })
end

function Parser:parse_ref()
  local keyword = self:next()
  local ref = {
    kind = "ref",
    expressions = {},
    start = keyword.start,
  }

  if not self:at_punct(":") and not self:at_punct("{") then
    local name = self:parse_name()
    if name then
      ref.name = name.name
      ref.name_range = name.range
    end
  end

  if self:at_punct(":") then
    self:next()
    local expression = self:parse_ref_expression("top_level")
    if expression then
      if self:at_punct("[") then
        expression.settings, expression.settings_range = self:parse_settings({
          kind = "ref",
          ref = ref,
          expression = expression,
        })
      end
      ref.expressions[#ref.expressions + 1] = expression
    end
  elseif self:at_punct("{") then
    local open = self:next()
    ref.body_start = open.stop
    while self:peek() and self:peek().type ~= "eof" and not self:at_punct("}") do
      local expression = self:parse_ref_expression("top_level")
      if expression then
        if self:at_punct("[") then
          expression.settings, expression.settings_range = self:parse_settings({
            kind = "ref",
            ref = ref,
            expression = expression,
          })
        end
        ref.expressions[#ref.expressions + 1] = expression
      else
        self:error(self:peek(), "expected a ref expression")
        self:next()
      end
    end
    local close = self:accept_punct("}")
    if not close then
      self:error(self:peek(), "unclosed ref block")
    end
    ref.body_end = close and close.start or #self.text
    ref.stop = close and close.stop or #self.text
  else
    self:error(self:peek(), "expected ':' or '{' in ref")
    ref.stop = self:last_stop()
  end

  if not ref.stop then
    ref.stop = self:last_stop()
  end
  ref.range = { start = keyword.start, stop = ref.stop }
  return ref
end

function Parser:parse_table_group()
  local keyword = self:next()
  local name = self:parse_name()
  if not name then
    return nil
  end

  local group = {
    kind = "table_group",
    name = name.name,
    name_range = name.range,
    members = {},
    start = keyword.start,
  }

  if self:at_punct("[") then
    group.settings, group.settings_range = self:parse_settings({
      kind = "table_group",
      group = group,
    })
  end

  local open = self:expect_punct("{")
  if not open then
    group.stop = name.range.stop
    group.range = { start = keyword.start, stop = group.stop }
    return group
  end
  group.body_start = open.stop

  while self:peek() and self:peek().type ~= "eof" and not self:at_punct("}") do
    local token = self:peek()
    if token.type == "word" and token.value:lower() == "note"
      and self:peek(1) and self:peek(1).value == ":" then
      group.note = self:parse_note()
    elseif token.type == "word" or token.type == "string" then
      local member = self:parse_qualified_name()
      group.members[#group.members + 1] = {
        name = member.name,
        range = member.range,
      }
    else
      self:error(token, "unexpected token in table group")
      self:next()
    end
  end

  local close = self:accept_punct("}")
  if not close then
    self:error(self:peek(), "unclosed table group")
  end
  group.body_end = close and close.start or #self.text
  group.stop = close and close.stop or #self.text
  group.range = { start = keyword.start, stop = group.stop }
  return group
end

function Parser:parse_project()
  local keyword = self:next()
  local name = self:parse_name()
  if not name then
    return nil
  end

  local project = {
    kind = "project",
    name = name.name,
    name_range = name.range,
    settings = {},
    start = keyword.start,
  }

  local open = self:expect_punct("{")
  if not open then
    project.stop = name.range.stop
    project.range = { start = keyword.start, stop = project.stop }
    return project
  end
  project.body_start = open.stop

  while self:peek() and self:peek().type ~= "eof" and not self:at_punct("}") do
    local token = self:peek()
    if token.type == "word" or token.type == "string" then
      self:next()
      local setting = {
        key = token.value,
        key_range = { start = token.start, stop = token.stop },
      }
      if self:at_punct(":") then
        self:next()
        local first_value = self:peek()
        local previous = nil
        while self:peek() and self:peek().type ~= "eof"
          and self:peek().line == token.line
          and not (self:peek().type == "punct" and self:peek().value == "}") do
          previous = self:next()
        end
        if first_value and previous then
          setting.value_range = { start = first_value.start, stop = previous.stop }
          if first_value.type == "string" and first_value == previous then
            setting.value = first_value.value
          else
            setting.value = self.text:sub(first_value.start + 1, previous.stop)
          end
        end
      end
      project.settings[#project.settings + 1] = setting
    else
      self:error(token, "unexpected token in project")
      self:next()
    end
  end

  local close = self:accept_punct("}")
  if not close then
    self:error(self:peek(), "unclosed project")
  end
  project.body_end = close and close.start or #self.text
  project.stop = close and close.stop or #self.text
  project.range = { start = keyword.start, stop = project.stop }
  return project
end

function Parser:parse_statement()
  local token = self:peek()
  if not token or token.type == "eof" then
    return nil
  end
  if token.type == "punct" and (token.value == "}" or token.value == "]") then
    self:next()
    return nil
  end

  if token.type == "word" then
    local keyword = token.value:lower()
    if keyword == "table" then
      return self:parse_table(false)
    elseif keyword == "tablepartial" then
      return self:parse_table(true)
    elseif keyword == "enum" then
      return self:parse_enum()
    elseif keyword == "ref" then
      return self:parse_ref()
    elseif keyword == "tablegroup" then
      return self:parse_table_group()
    elseif keyword == "project" then
      return self:parse_project()
    elseif keyword == "records" then
      return self:parse_records()
    end
  end

  self:error(token, "unexpected token '" .. tostring(token.value) .. "'")
  self:next()
  return nil
end

--- Parse a token stream.  Returns `document, errors`.
function M.parse(tokens, text)
  local parser = Parser.new(tokens, text)
  local document = {
    kind = "document",
    statements = {},
    tables = {},
    enums = {},
    refs = {},
    groups = {},
    projects = {},
  }

  while parser:peek() and parser:peek().type ~= "eof" do
    local before = parser.pos
    local statement = parser:parse_statement()
    if statement then
      document.statements[#document.statements + 1] = statement
      if statement.kind == "table" then
        document.tables[#document.tables + 1] = statement
      elseif statement.kind == "enum" then
        document.enums[#document.enums + 1] = statement
      elseif statement.kind == "ref" then
        document.refs[#document.refs + 1] = statement
      elseif statement.kind == "table_group" then
        document.groups[#document.groups + 1] = statement
      elseif statement.kind == "project" then
        document.projects[#document.projects + 1] = statement
      end
    end
    -- Safety net against a parser path that consumes nothing.
    if parser.pos == before then
      parser.pos = parser.pos + 1
    end
  end

  return document, parser.errors
end

return M
