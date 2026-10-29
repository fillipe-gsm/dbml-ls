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
    assert.equal(3, #messages)

    assert.equal("utf-8", messages[1].result.capabilities.positionEncoding)
    assert.equal("dbml-ls", messages[1].result.serverInfo.name)

    local labels = {}
    for _, item in ipairs(messages[2].result.items) do
      labels[item.label] = true
    end
    assert.is_true(labels.integer)

    assert.equal(json.null, messages[3].result)

    os.remove(input_path)
    os.remove(output_path)
  end)
end)
