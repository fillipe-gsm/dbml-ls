-- In-memory document plus offset <-> LSP position conversion.
--
-- Internal offsets are 0-based byte offsets into the document text.
-- LSP positions use UTF-16 code units by default; modern clients can
-- negotiate UTF-8, where one byte is one character.  Parser and lexer
-- always work with byte offsets; only the conversion functions care.

---@class dbml.Document
---@field uri string
---@field text string
---@field version integer
---@field encoding dbml.PositionEncoding
---@field line_starts integer[]
---@field _analysis? dbml.Analysis
---@field _analysis_version? integer
---@field _compute_lines fun(self: dbml.Document)
---@field set_text fun(self: dbml.Document, text: string, version: integer?)
---@field apply_change fun(self: dbml.Document, change: dbml.TextDocumentContentChangeEvent, version: integer?)
---@field line_start_offset fun(self: dbml.Document, line: integer): integer
---@field line_count fun(self: dbml.Document): integer
---@field line_text fun(self: dbml.Document, line: integer): string
---@field position_at fun(self: dbml.Document, offset: integer): dbml.Position
---@field offset_at fun(self: dbml.Document, position: dbml.Position): integer

local Document = {}
Document.__index = Document

---@param byte integer
---@return integer
local function utf8_size(byte)
  if byte < 0x80 then
    return 1
  elseif byte < 0xE0 then
    return 2
  elseif byte < 0xF0 then
    return 3
  end
  return 4
end

--- Number of UTF-16 code units in a UTF-8 string.
---@param str string
---@return integer
local function utf16_length(str)
  local length = 0
  local i = 1
  while i <= #str do
    local size = utf8_size(str:byte(i))
    -- Four-byte code points become a surrogate pair.
    length = length + (size == 4 and 2 or 1)
    i = i + size
  end
  return length
end

---@param uri string
---@param text string?
---@param version integer?
---@return dbml.Document
function Document.new(uri, text, version)
  ---@type dbml.Document
  local self = setmetatable({
    uri = uri,
    text = text or "",
    version = version or 0,
    encoding = "utf-8",
    _analysis = nil,
    _analysis_version = nil,
  }, Document)
  self:_compute_lines()
  return self
end

---@return nil
function Document:_compute_lines()
  local starts = { 1 }
  local text = self.text
  local i = 1
  while true do
    local newline = text:find("\n", i, true)
    if not newline then
      break
    end
    starts[#starts + 1] = newline + 1
    i = newline + 1
  end
  self.line_starts = starts
end

--- Replace the whole document text.
---@param text string
---@param version integer?
function Document:set_text(text, version)
  self.text = text or ""
  self.version = version or (self.version + 1)
  self._analysis = nil
  self._analysis_version = nil
  self:_compute_lines()
end

--- Apply a single LSP TextDocumentContentChangeEvent.
---@param change dbml.TextDocumentContentChangeEvent
---@param version integer?
function Document:apply_change(change, version)
  if change.range then
    local start_offset = self:offset_at(change.range.start)
    local end_offset = self:offset_at(change.range["end"])
    if end_offset < start_offset then
      start_offset, end_offset = end_offset, start_offset
    end
    local new_text = self.text:sub(1, start_offset) .. (change.text or "") .. self.text:sub(end_offset + 1)
    self:set_text(new_text, version)
  else
    self:set_text(change.text or "", version)
  end
end

--- 0-based offset of the first byte of a line.
---@param line integer
---@return integer
function Document:line_start_offset(line)
  local start = self.line_starts[line + 1]
  if not start then
    return #self.text
  end
  return start - 1
end

---@return integer
function Document:line_count()
  return #self.line_starts
end

--- Text of a line, without the trailing newline.
---@param line integer
---@return string
function Document:line_text(line)
  local start = self.line_starts[line + 1]
  if not start then
    return ""
  end
  local next_start = self.line_starts[line + 2]
  local stop
  if next_start then
    -- next_start is 1-based; the newline is one byte before it.
    stop = next_start - 2
  else
    stop = #self.text
  end
  return self.text:sub(start, stop)
end

--- Convert a 0-based byte offset to an LSP Position.
---@param offset integer
---@return dbml.Position
function Document:position_at(offset)
  ---@cast self dbml.Document
  if offset < 0 then
    offset = 0
  elseif offset > #self.text then
    offset = #self.text
  end

  local starts = self.line_starts
  local lo, hi = 1, #starts
  while lo < hi do
    local mid = (lo + hi + 1) // 2
    local mid_start = starts[mid] or 0
    if mid_start - 1 <= offset then
      lo = mid
    else
      hi = mid - 1
    end
  end

  local line_start = (starts[lo] or 1) - 1
  local character
  if self.encoding == "utf-16" then
    character = utf16_length(self.text:sub(line_start + 1, offset))
  else
    character = offset - line_start
  end

  return { line = lo - 1, character = character }
end

--- Convert an LSP Position to a 0-based byte offset.  Positions past the
--- end of a line are clamped, which is what clients expect.
---@param position dbml.Position
---@return integer
function Document:offset_at(position)
  ---@cast self dbml.Document
  local line = (position and position.line) or 0
  local character = (position and position.character) or 0
  local start = self.line_starts[line + 1]
  if not start then
    return #self.text
  end
  local line_start = start - 1
  local next_start = self.line_starts[line + 2]
  local max_character
  if next_start then
    -- newline offset minus line start = length of the line contents
    max_character = (next_start - 2) - line_start
  else
    max_character = #self.text - line_start
  end
  if character < 0 then
    character = 0
  elseif character > max_character then
    character = max_character
  end

  if self.encoding ~= "utf-16" then
    return line_start + character
  end

  -- Walk UTF-8 characters, counting UTF-16 code units.
  local i = line_start
  local units = 0
  local limit = line_start + max_character
  while i < limit and units < character do
    local size = utf8_size(self.text:byte(i + 1))
    local width = (size == 4) and 2 or 1
    if units + width > character then
      break
    end
    units = units + width
    i = i + size
  end
  return i
end

return Document
