-- Error-tolerant recursive-descent parser for DBML.
--
-- The parser is deliberately forgiving: a half-typed `Table users {`
-- should still produce a table node so completion can use it.  Every
-- node carries byte ranges; the LSP layer converts them to positions.

local M = {}

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

function Parser:skip_line()
  local line = self:peek() and self:peek().line
  while self:peek() and self:peek().type ~= "eof" and self:peek().line == line do
    self:next()
  end
end

-- Settings are the `[pk, not null, note: '...']` lists attached to
-- columns, indexes, and refs.  Values are kept as raw source text so
-- that hover can display them without re-implementing DBML formatting.
function Parser:parse_settings()
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
  if type_token and type_token.type == "word" and type_token.line == name_token.line then
    self:next()
    column.type = type_token.value
    column.type_range = { start = type_token.start, stop = type_token.stop }

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
    local settings, range = self:parse_settings()
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

function Parser:parse_indexes(table)
  local keyword = self:next()
  local open = self:expect_punct("{")
  if not open then
    return
  end

  local indexes = {}
  while self:peek() and self:peek().type ~= "eof" and not self:at_punct("}") do
    if self:at_punct("(") then
      local paren = self:next()
      local columns = {}
      while self:peek() and self:peek().type ~= "eof" and not self:at_punct(")") do
        local token = self:peek()
        if token.type == "word" or token.type == "string" then
          self:next()
          columns[#columns + 1] = {
            name = token.value,
            range = { start = token.start, stop = token.stop },
          }
        else
          self:error(token, "expected a column name in index")
          self:next()
        end
        self:accept_punct(",")
      end
      local close_paren = self:accept_punct(")")
      local settings, settings_range
      if self:at_punct("[") then
        settings, settings_range = self:parse_settings()
      end
      indexes[#indexes + 1] = {
        kind = "index",
        columns = columns,
        settings = settings or {},
        settings_range = settings_range,
        range = {
          start = paren.start,
          stop = (settings_range and settings_range.stop)
            or (close_paren and close_paren.stop)
            or paren.stop,
        },
      }
    else
      self:error(self:peek(), "expected '(' in indexes block")
      self:next()
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
    table.settings, table.settings_range = self:parse_settings()
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
      self:skip_line()
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
  local name = self:parse_name()
  if not name then
    return nil
  end

  local enum = {
    kind = "enum",
    name = name.name,
    name_range = name.range,
    values = {},
    start = keyword.start,
  }

  if self:at_punct("[") then
    enum.settings, enum.settings_range = self:parse_settings()
  end

  local open = self:expect_punct("{")
  if not open then
    enum.stop = name.range.stop
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
        value.settings, value.settings_range = self:parse_settings()
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

  local endpoint = {
    parts = qualified.parts,
    ranges = qualified.ranges,
    name = qualified.name,
    range = qualified.range,
    table = qualified.parts[#qualified.parts - 1],
    column = qualified.parts[#qualified.parts],
  }

  if #qualified.parts >= 2 then
    endpoint.table = qualified.parts[#qualified.parts - 1]
    endpoint.column = qualified.parts[#qualified.parts]
    endpoint.table_range = qualified.ranges[#qualified.ranges - 1]
    endpoint.column_range = qualified.ranges[#qualified.ranges]
    if #qualified.parts > 2 then
      endpoint.schema = table.concat(qualified.parts, ".", 1, #qualified.parts - 2)
    end
  else
    endpoint.table = qualified.parts[1]
    endpoint.column = nil
    endpoint.table_range = qualified.ranges[1]
    self:error(self:peek(), "expected 'table.column' reference")
  end

  return endpoint
end

function Parser:parse_ref_expression()
  local left = self:parse_endpoint()
  if not left then
    return nil
  end

  local operator = self:peek()
  if not operator or operator.type ~= "punct"
    or (operator.value ~= ">" and operator.value ~= "<"
      and operator.value ~= "-" and operator.value ~= "<>") then
    self:error(operator, "expected a relationship operator")
    return nil
  end
  self:next()

  local right = self:parse_endpoint()
  if not right then
    return nil
  end

  return {
    kind = "ref_expression",
    from = left,
    to = right,
    operator = operator.value,
    range = { start = left.range.start, stop = right.range.stop },
  }
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
    local expression = self:parse_ref_expression()
    if expression then
      if self:at_punct("[") then
        expression.settings, expression.settings_range = self:parse_settings()
      end
      ref.expressions[#ref.expressions + 1] = expression
    end
  elseif self:at_punct("{") then
    local open = self:next()
    ref.body_start = open.stop
    while self:peek() and self:peek().type ~= "eof" and not self:at_punct("}") do
      local expression = self:parse_ref_expression()
      if expression then
        if self:at_punct("[") then
          expression.settings, expression.settings_range = self:parse_settings()
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
    group.settings, group.settings_range = self:parse_settings()
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
    if token.type == "word" or token.type == "string" then
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
