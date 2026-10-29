-- Hand-written lexer for DBML.
--
-- Tokens carry 0-based byte offsets (start inclusive, stop exclusive)
-- plus the 0-based line/column of their first byte.  The parser works
-- entirely with these offsets.

local M = {}

local function is_digit(byte)
  return byte and byte >= 48 and byte <= 57
end

local function is_word_start(byte)
  if not byte then
    return false
  end
  return (byte >= 65 and byte <= 90) -- A-Z
    or (byte >= 97 and byte <= 122) -- a-z
    or byte == 95 -- _
    or byte >= 128 -- UTF-8 identifier bytes
end

local function is_word_byte(byte)
  return is_word_start(byte) or is_digit(byte)
end

--- Tokenize `text`.
--
-- Returns `tokens, errors`.  A trailing EOF token is always present.
function M.tokenize(text)
  local tokens = {}
  local errors = {}
  local i = 1
  local n = #text
  local line = 0
  local col = 0

  local function bump()
    local byte = text:byte(i)
    if not byte then
      return
    end
    if byte == 10 then -- \n
      line = line + 1
      col = 0
    else
      col = col + 1
    end
    i = i + 1
  end

  local function add(kind, value, start_offset, start_line, start_col)
    tokens[#tokens + 1] = {
      type = kind,
      value = value,
      start = start_offset,
      stop = i - 1,
      line = start_line,
      col = start_col,
    }
  end

  local function record_error(message, start_offset, start_line, start_col)
    errors[#errors + 1] = {
      message = message,
      start = start_offset,
      stop = i - 1,
      line = start_line,
      col = start_col,
    }
  end

  while i <= n do
    local byte = text:byte(i)
    local char = text:sub(i, i)

    if char == "\n" or char == "\r" or char == " " or char == "\t" or char == "\v" or char == "\f" then
      bump()

    elseif char == "/" and text:sub(i, i + 1) == "//" then
      while i <= n and text:byte(i) ~= 10 do
        bump()
      end

    elseif char == "/" and text:sub(i, i + 1) == "/*" then
      local start_offset, start_line, start_col = i - 1, line, col
      bump()
      bump()
      local closed = false
      while i <= n do
        if text:sub(i, i + 1) == "*/" then
          bump()
          bump()
          closed = true
          break
        end
        bump()
      end
      if not closed then
        record_error("unterminated block comment", start_offset, start_line, start_col)
      end

    elseif char == "'" or char == '"' then
      local start_offset, start_line, start_col = i - 1, line, col
      local triple = text:sub(i, i + 2) == char:rep(3)
      local quote = triple and char:rep(3) or char
      bump()
      if triple then
        bump()
        bump()
      end
      local buffer = {}
      local closed = false
      while i <= n do
        if triple then
          if text:sub(i, i + 2) == quote then
            bump()
            bump()
            bump()
            closed = true
            break
          end
          buffer[#buffer + 1] = text:sub(i, i)
          bump()
        elseif text:sub(i, i) == "\\" then
          local escaped = text:sub(i + 1, i + 1)
          if escaped == "" then
            bump()
            break
          end
          local map = { n = "\n", t = "\t", r = "\r" }
          buffer[#buffer + 1] = map[escaped] or escaped
          bump()
          bump()
        elseif text:sub(i, i) == char then
          bump()
          closed = true
          break
        else
          buffer[#buffer + 1] = text:sub(i, i)
          bump()
        end
      end
      if not closed then
        record_error("unterminated string", start_offset, start_line, start_col)
      end
      tokens[#tokens + 1] = {
        type = "string",
        value = table.concat(buffer),
        start = start_offset,
        stop = i - 1,
        line = start_line,
        col = start_col,
      }

    elseif is_digit(byte) then
      local start_offset, start_line, start_col = i - 1, line, col
      while i <= n and is_digit(text:byte(i)) do
        bump()
      end
      if text:sub(i, i) == "." and is_digit(text:byte(i + 1)) then
        bump()
        while i <= n and is_digit(text:byte(i)) do
          bump()
        end
      end
      if text:sub(i, i):lower() == "e" then
        local sign = text:sub(i + 1, i + 1)
        local digit_index = (sign == "+" or sign == "-") and i + 2 or i + 1
        if is_digit(text:byte(digit_index)) then
          if sign == "+" or sign == "-" then
            bump()
          end
          bump()
          while i <= n and is_digit(text:byte(i)) do
            bump()
          end
        end
      end
      add("number", text:sub(start_offset + 1, i - 1), start_offset, start_line, start_col)

    elseif is_word_start(byte) then
      local start_offset, start_line, start_col = i - 1, line, col
      while i <= n and is_word_byte(text:byte(i)) do
        bump()
      end
      add("word", text:sub(start_offset + 1, i - 1), start_offset, start_line, start_col)

    else
      local start_offset, start_line, start_col = i - 1, line, col
      local two = text:sub(i, i + 1)
      if two == "<>" then
        bump()
        bump()
        add("punct", "<>", start_offset, start_line, start_col)
      else
        bump()
        add("punct", char, start_offset, start_line, start_col)
      end
    end
  end

  tokens[#tokens + 1] = {
    type = "eof",
    value = "",
    start = #text,
    stop = #text,
    line = line,
    col = col,
  }

  return tokens, errors
end

return M
