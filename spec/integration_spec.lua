local rpc = require("dbml.rpc")
local json = require("dbml.json")

local function write_frames(path, messages)
  local file = assert(io.open(path, "w"))
  for _, message in ipairs(messages) do
    rpc.write_message(file, message)
  end
  file:close()
end

local function read_frames(path)
  local file = assert(io.open(path, "r"))
  local messages = {}
  while true do
    local message = rpc.read_message(file)
    if not message then
      break
    end
    messages[#messages + 1] = message
  end
  file:close()
  return messages
end

local function response_for(messages, id)
  for _, message in ipairs(messages) do
    if message.id == id and message.result ~= nil then
      return message
    end
  end
  return nil
end

local function notifications_for(messages, method)
  local result = {}
  for _, message in ipairs(messages) do
    if message.method == method then
      result[#result + 1] = message
    end
  end
  return result
end

describe("integration", function()
  it("runs the real stdio entrypoint through a full session", function()
    local input_path = os.tmpname()
    local output_path = os.tmpname()

    write_frames(input_path, {
      {
        jsonrpc = "2.0",
        id = 1,
        method = "initialize",
        params = {
          capabilities = {
            general = { positionEncodings = { "utf-8" } },
          },
        },
      },
      {
        jsonrpc = "2.0",
        method = "textDocument/didOpen",
        params = {
          textDocument = {
            uri = "file:///integration.dbml",
            languageId = "dbml",
            version = 1,
            text = "Table users {\n  id integer\n}\n",
          },
        },
      },
      {
        jsonrpc = "2.0",
        id = 2,
        method = "textDocument/completion",
        params = {
          textDocument = { uri = "file:///integration.dbml" },
          position = { line = 1, character = 5 },
        },
      },
      { jsonrpc = "2.0", id = 3, method = "shutdown" },
      { jsonrpc = "2.0", method = "exit" },
    })

    local command = ("lua src/main.lua < %q > %q"):format(input_path, output_path)
    local ok, reason, code = os.execute(command)
    assert.is_true(ok, tostring(reason))
    assert.equal(0, code)

    local messages = read_frames(output_path)
    assert.equal(4, #messages)

    local initialized = response_for(messages, 1)
    assert.is_not_nil(initialized)
    assert.equal("utf-8", initialized.result.capabilities.positionEncoding)
    assert.equal("dbml-ls", initialized.result.serverInfo.name)

    local published = notifications_for(messages, "textDocument/publishDiagnostics")
    assert.equal(1, #published)
    assert.equal("file:///integration.dbml", published[1].params.uri)
    assert.same({}, published[1].params.diagnostics)

    local completion = response_for(messages, 2)
    assert.is_not_nil(completion)
    local labels = {}
    for _, item in ipairs(completion.result.items) do
      labels[item.label] = true
    end
    assert.is_true(labels.integer)

    local shutdown = response_for(messages, 3)
    assert.is_not_nil(shutdown)
    assert.equal(json.null, shutdown.result)

    os.remove(input_path)
    os.remove(output_path)
  end)
end)
