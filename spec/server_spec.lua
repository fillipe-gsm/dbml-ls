local Server = require("dbml.server")
local json = require("dbml.json")

local URI = "file:///test.dbml"

local function new_server()
  local sent = {}
  local server = Server.new({
    send = function(message)
      sent[#sent + 1] = message
    end,
  })
  return server, sent
end

local function last(sent)
  return sent[#sent]
end

local function initialize(server, capabilities)
  server:dispatch({
    jsonrpc = "2.0",
    id = 1,
    method = "initialize",
    params = { capabilities = capabilities or {} },
  })
end

local function open(server, text)
  server:dispatch({
    jsonrpc = "2.0",
    method = "textDocument/didOpen",
    params = {
      textDocument = {
        uri = URI,
        languageId = "dbml",
        version = 1,
        text = text,
      },
    },
  })
end

describe("server", function()
  it("answers initialize with capabilities and server info", function()
    local server, sent = new_server()
    initialize(server, {
      general = { positionEncodings = { "utf-16", "utf-8" } },
      textDocument = {
        completion = { completionItem = { snippetSupport = true } },
      },
    })

    local response = last(sent)
    assert.equal(1, response.id)
    assert.equal("utf-8", response.result.capabilities.positionEncoding)
    assert.equal(1, response.result.capabilities.textDocumentSync.change)
    assert.is_true(response.result.capabilities.hoverProvider)
    assert.is_true(response.result.capabilities.documentSymbolProvider)
    assert.equal("dbml-ls", response.result.serverInfo.name)
    assert.is_true(server.initialized)
    assert.is_true(server.supports_snippets)
  end)

  it("defaults to utf-16 when the client does not advertise encodings", function()
    local server, sent = new_server()
    initialize(server)
    assert.equal("utf-16", last(sent).result.capabilities.positionEncoding)
  end)

  it("rejects requests before initialize", function()
    local server, sent = new_server()
    server:dispatch({
      jsonrpc = "2.0",
      id = 2,
      method = "textDocument/hover",
      params = {},
    })
    assert.equal(-32002, last(sent).error.code)
  end)

  it("returns MethodNotFound for unknown requests", function()
    local server, sent = new_server()
    initialize(server)
    server:dispatch({
      jsonrpc = "2.0",
      id = 3,
      method = "textDocument/unknown",
      params = {},
    })
    assert.equal(-32601, last(sent).error.code)
  end)

  it("ignores unknown notifications", function()
    local server, sent = new_server()
    initialize(server)
    local before = #sent
    server:dispatch({ jsonrpc = "2.0", method = "some/notification", params = {} })
    assert.equal(before, #sent)
  end)

  it("keeps opened documents and completes against them", function()
    local server, sent = new_server()
    initialize(server)
    open(server, "Table users {\n  id integer\n}\n")

    server:dispatch({
      jsonrpc = "2.0",
      id = 4,
      method = "textDocument/completion",
      params = {
        textDocument = { uri = URI },
        position = { line = 1, character = 5 },
      },
    })

    local response = last(sent)
    assert.is_false(response.result.isIncomplete)
    local labels = {}
    for _, item in ipairs(response.result.items) do
      labels[item.label] = true
    end
    assert.is_true(labels.integer)
    assert.is_true(labels.varchar)
  end)

  it("applies full-text changes", function()
    local server = new_server()
    initialize(server)
    open(server, "Table users {\n  id integer\n}\n")

    server:dispatch({
      jsonrpc = "2.0",
      method = "textDocument/didChange",
      params = {
        textDocument = { uri = URI, version = 2 },
        contentChanges = { { text = "Table places {\n  id integer\n}\n" } },
      },
    })

    assert.matches("Table places", server.documents[URI].text)
    assert.equal(2, server.documents[URI].version)
  end)

  it("applies incremental changes even though full sync is advertised", function()
    local server = new_server()
    initialize(server)
    open(server, "Table users {\n  id integer\n}\n")

    server:dispatch({
      jsonrpc = "2.0",
      method = "textDocument/didChange",
      params = {
        textDocument = { uri = URI, version = 2 },
        contentChanges = {
          {
            range = {
              start = { line = 1, character = 2 },
              ["end"] = { line = 1, character = 4 },
            },
            text = "uid",
          },
        },
      },
    })

    assert.matches("uid integer", server.documents[URI].text)
  end)

  it("returns hover contents and null for misses", function()
    local server, sent = new_server()
    initialize(server)
    open(server, "Table users {\n  id integer\n}\n")

    server:dispatch({
      jsonrpc = "2.0",
      id = 5,
      method = "textDocument/hover",
      params = {
        textDocument = { uri = URI },
        position = { line = 1, character = 3 },
      },
    })
    assert.matches("Column", last(sent).result.contents.value)

    server:dispatch({
      jsonrpc = "2.0",
      id = 6,
      method = "textDocument/hover",
      params = {
        textDocument = { uri = URI },
        position = { line = 3, character = 0 },
      },
    })
    assert.equal(json.null, last(sent).result)
  end)

  it("returns document symbols", function()
    local server, sent = new_server()
    initialize(server)
    open(server, "Table users {\n  id integer\n}\n")

    server:dispatch({
      jsonrpc = "2.0",
      id = 7,
      method = "textDocument/documentSymbol",
      params = { textDocument = { uri = URI } },
    })

    local result = last(sent).result
    assert.equal(1, #result)
    assert.equal("users", result[1].name)
    assert.equal("id", result[1].children[1].name)
  end)

  it("returns an empty array for completion without a document", function()
    local server, sent = new_server()
    initialize(server)
    server:dispatch({
      jsonrpc = "2.0",
      id = 8,
      method = "textDocument/completion",
      params = { textDocument = { uri = "file:///missing.dbml" } },
    })
    assert.equal("[]", json.encode(last(sent).result.items))
  end)

  it("shuts down and exits cleanly", function()
    local server, sent = new_server()
    initialize(server)

    server:dispatch({ jsonrpc = "2.0", id = 9, method = "shutdown" })
    assert.equal(json.null, last(sent).result)
    assert.is_true(server.shutdown_requested)

    server:dispatch({ jsonrpc = "2.0", method = "exit" })
    assert.equal(0, server.exit_code)
  end)

  it("rejects requests after shutdown", function()
    local server, sent = new_server()
    initialize(server)
    server:dispatch({ jsonrpc = "2.0", id = 11, method = "shutdown" })

    server:dispatch({
      jsonrpc = "2.0",
      id = 12,
      method = "textDocument/hover",
      params = {},
    })
    assert.equal(-32600, last(sent).error.code)
  end)

  it("exits with 1 when exit arrives before shutdown", function()
    local server = new_server()
    initialize(server)
    server:dispatch({ jsonrpc = "2.0", method = "exit" })
    assert.equal(1, server.exit_code)
  end)

  it("rejects a second initialize", function()
    local server, sent = new_server()
    initialize(server)
    server:dispatch({
      jsonrpc = "2.0",
      id = 10,
      method = "initialize",
      params = { capabilities = {} },
    })
    assert.equal(-32600, last(sent).error.code)
  end)
end)
