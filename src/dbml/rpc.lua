-- LSP framing: base protocol messages are
--
--   Content-Length: <byte count>\r\n
--   [Content-Type: application/vscode-jsonrpc; charset=utf-8]\r\n
--   \r\n
--   <UTF-8 body>
--
-- Content-Length is a byte count, not a character count.  We never use
-- line-based reads for the body.

local json = require("dbml.json")

local M = {}

--- Read one framed message.
--
-- Returns `message` on success.  On failure returns `nil, kind, detail`
-- where kind is one of "eof", "parse", or "framing".  A parse error is
-- recoverable (the frame was consumed); a framing error is not.
---@param stream file*
---@return table? message
---@return string? kind
---@return string? detail
function M.read_message(stream)
  local headers = {}
  local saw_header = false

  while true do
    local line = stream:read("l")
    if not line then
      return nil, "eof"
    end
    line = line:gsub("\r$", "")
    if line == "" then
      if saw_header then
        break
      end
      -- Tolerate stray blank lines before the first header.  Some
      -- launchers (notably `lx run`) write one to stdout.
    else
      saw_header = true
      local name, value = line:match("^([^:]+):%s*(.*)$")
      if name then
        headers[name:lower()] = value
      end
    end
  end

  local length = tonumber(headers["content-length"])
  if not length or length < 0 or length ~= math.floor(length) then
    return nil, "framing", "missing or invalid Content-Length"
  end

  local body = stream:read(length)
  if not body or #body < length then
    return nil, "eof"
  end

  local message, err = json.decode(body)
  if not message then
    return nil, "parse", err
  end
  if type(message) ~= "table" then
    return nil, "parse", "message is not a JSON object"
  end

  return message
end

--- Write one framed message and flush immediately.  Forgetting the flush
--- is a classic cause of a language server that appears to hang.
---@param stream file*
---@param message table
function M.write_message(stream, message)
  local body = json.encode(message)
  stream:write(("Content-Length: %d\r\n\r\n"):format(#body) .. body)
  stream:flush()
end

return M
