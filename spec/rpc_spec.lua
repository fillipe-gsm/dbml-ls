local rpc = require("dbml.rpc")
local json = require("dbml.json")

local function input_stream(data)
  local position = 1
  local stream = {}

  function stream.read(_, count)
    if position > #data then
      return nil
    end
    if count == "l" or count == "*l" then
      local newline = data:find("\n", position, true)
      if not newline then
        local line = data:sub(position)
        position = #data + 1
        return line
      end
      local line = data:sub(position, newline - 1)
      position = newline + 1
      return line
    end
    if type(count) == "number" then
      local chunk = data:sub(position, position + count - 1)
      position = position + #chunk
      return chunk
    end
    error("unsupported read: " .. tostring(count))
  end

  return stream
end

local function output_stream()
  local stream = { data = "", flushed = false }
  function stream:write(value)
    self.data = self.data .. value
  end
  function stream:flush()
    self.flushed = true
  end
  return stream
end

local function frame(message)
  local body = type(message) == "string" and message or json.encode(message)
  return ("Content-Length: %d\r\n\r\n%s"):format(#body, body)
end

describe("rpc", function()
  it("writes Content-Length as a byte count and flushes", function()
    local out = output_stream()
    rpc.write_message(out, {
      jsonrpc = "2.0",
      method = "test",
      params = { text = "é" },
    })

    assert.is_true(out.flushed)
    local length, body = out.data:match("^Content%-Length: (%d+)\r\n\r\n(.*)$")
    assert.is_not_nil(length)
    assert.equal(#body, tonumber(length))
    assert.matches("é", body)
  end)

  it("reads one framed message", function()
    local message = rpc.read_message(input_stream(frame({
      jsonrpc = "2.0",
      id = 1,
      method = "initialize",
    })))
    assert.equal("initialize", message.method)
    assert.equal(1, message.id)
  end)

  it("tolerates leading blank lines before headers", function()
    local message = rpc.read_message(input_stream("\n" .. frame({ id = 4 })))
    assert.equal(4, message.id)
  end)

  it("reads consecutive messages from one stream", function()
    local stream = input_stream(frame({ id = 1 }) .. frame({ id = 2 }))
    assert.equal(1, rpc.read_message(stream).id)
    assert.equal(2, rpc.read_message(stream).id)
    assert.is_nil(rpc.read_message(stream))
  end)

  it("reports EOF", function()
    local message, kind = rpc.read_message(input_stream(""))
    assert.is_nil(message)
    assert.equal("eof", kind)
  end)

  it("reports parse errors without losing the stream", function()
    local stream = input_stream(frame("not json") .. frame({ id = 7 }))
    local message, kind, detail = rpc.read_message(stream)
    assert.is_nil(message)
    assert.equal("parse", kind)
    assert.is_truthy(detail)

    local next_message = rpc.read_message(stream)
    assert.equal(7, next_message.id)
  end)

  it("reports framing errors", function()
    local message, kind = rpc.read_message(input_stream("X-Test: 1\r\n\r\n{}"))
    assert.is_nil(message)
    assert.equal("framing", kind)
  end)
end)
