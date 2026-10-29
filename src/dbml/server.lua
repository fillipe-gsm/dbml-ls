-- LSP lifecycle, document synchronization, and request handlers.

local json = require("dbml.json")
local log = require("dbml.log")
local Document = require("dbml.document")
local analysis = require("dbml.analysis")
local completion = require("dbml.completion")
local hover = require("dbml.hover")
local symbols = require("dbml.symbols")
local diagnostics_engine = require("dbml.diagnostics")

local Server = {}
Server.__index = Server

local SERVER_NAME = "dbml-ls"
local SERVER_VERSION = "0.1.0"

local ERROR = {
  InvalidRequest = -32600,
  MethodNotFound = -32601,
  InternalError = -32603,
  ServerNotInitialized = -32002,
}

function Server.new(options)
  options = options or {}
  local self = setmetatable({
    send = options.send or function() end,
    documents = {},
    initialized = false,
    shutdown_requested = false,
    exit_code = nil,
    position_encoding = "utf-16",
    supports_snippets = false,
    root_uri = nil,
    client_info = nil,
    handlers = {},
  }, Server)

  self.handlers = {
    ["initialize"] = Server.handle_initialize,
    ["initialized"] = Server.handle_initialized,
    ["shutdown"] = Server.handle_shutdown,
    ["exit"] = Server.handle_exit,

    ["textDocument/didOpen"] = Server.handle_did_open,
    ["textDocument/didChange"] = Server.handle_did_change,
    ["textDocument/didClose"] = Server.handle_did_close,

    ["textDocument/completion"] = Server.handle_completion,
    ["textDocument/hover"] = Server.handle_hover,
    ["textDocument/documentSymbol"] = Server.handle_document_symbol,

    ["workspace/didChangeConfiguration"] = Server.handle_noop,
    ["workspace/didChangeWatchedFiles"] = Server.handle_noop,
    ["$/cancelRequest"] = Server.handle_noop,
    ["$/setTrace"] = Server.handle_noop,
  }

  return self
end

function Server:respond(id, result)
  self.send({
    jsonrpc = "2.0",
    id = id,
    result = result,
  })
end

function Server:respond_error(id, code, message, data)
  local error_object = {
    code = code,
    message = message,
  }
  if data ~= nil then
    error_object.data = data
  end
  self.send({
    jsonrpc = "2.0",
    id = id == nil and json.null or id,
    error = error_object,
  })
end

function Server:notify(method, params)
  self.send({
    jsonrpc = "2.0",
    method = method,
    params = params or json.object(),
  })
end

function Server:document_for(params)
  local text_document = params and params.textDocument
  local uri = text_document and text_document.uri
  if not uri then
    return nil
  end
  return self.documents[uri]
end

function Server:handle_initialize(params, message)
  if self.initialized then
    self:respond_error(message.id, ERROR.InvalidRequest, "Server is already initialized")
    return
  end

  local capabilities = params.capabilities
  if type(capabilities) ~= "table" then
    capabilities = {}
  end
  self.client_info = params.clientInfo
  self.root_uri = params.rootUri

  -- Position encoding negotiation (LSP 3.17).  Default is UTF-16.
  self.position_encoding = "utf-16"
  local general = capabilities.general
  local encodings = type(general) == "table" and general.positionEncodings or nil
  if type(encodings) == "table" then
    for _, encoding in ipairs(encodings) do
      if encoding == "utf-8" then
        self.position_encoding = "utf-8"
        break
      end
    end
  end

  local text_document = capabilities.textDocument
  local completion_capabilities = type(text_document) == "table"
    and text_document.completion or nil
  local completion_item = type(completion_capabilities) == "table"
    and completion_capabilities.completionItem or nil
  self.supports_snippets = type(completion_item) == "table"
    and completion_item.snippetSupport == true

  self.initialized = true

  self:respond(message.id, {
    capabilities = {
      positionEncoding = self.position_encoding,
      textDocumentSync = {
        openClose = true,
        change = 1, -- TextDocumentSyncKind.Full
      },
      completionProvider = {
        triggerCharacters = { ".", "[", ",", " " },
        resolveProvider = false,
      },
      hoverProvider = true,
      documentSymbolProvider = true,
    },
    serverInfo = {
      name = SERVER_NAME,
      version = SERVER_VERSION,
    },
  })
end

function Server.handle_initialized()
  -- No work to do yet.
end

function Server:handle_shutdown(_, message)
  self.shutdown_requested = true
  self:respond(message.id, json.null)
end

function Server:handle_exit()
  self.exit_code = self.shutdown_requested and 0 or 1
end

function Server.handle_noop()
end

function Server:publish_diagnostics(document)
  local ok, result = pcall(function()
    local analyzed = analysis.get(document)
    return diagnostics_engine.diagnose(analyzed, document)
  end)
  if not ok then
    log.error("diagnostics failed: %s", tostring(result))
    return
  end

  self:notify("textDocument/publishDiagnostics", {
    uri = document.uri,
    version = document.version,
    diagnostics = result,
  })
end

function Server:clear_diagnostics(uri)
  self:notify("textDocument/publishDiagnostics", {
    uri = uri,
    diagnostics = json.array({}),
  })
end

function Server:handle_did_open(params)
  local text_document = params.textDocument
  if not text_document or not text_document.uri then
    return
  end
  local document = Document.new(text_document.uri, text_document.text, text_document.version)
  document.encoding = self.position_encoding
  self.documents[text_document.uri] = document
  self:publish_diagnostics(document)
end

function Server:handle_did_change(params)
  local document = self:document_for(params)
  if not document then
    return
  end
  local text_document = params.textDocument or {}
  local version = text_document.version or (document.version + 1)
  local changes = params.contentChanges or {}
  if #changes == 0 then
    return
  end
  for _, change in ipairs(changes) do
    document:apply_change(change, version)
  end
  self:publish_diagnostics(document)
end

function Server:handle_did_close(params)
  local document = self:document_for(params)
  if document then
    self:clear_diagnostics(document.uri)
    self.documents[document.uri] = nil
  end
end

function Server:handle_completion(params, message)
  local document = self:document_for(params)
  if not document then
    self:respond(message.id, { isIncomplete = false, items = json.array({}) })
    return
  end

  local analyzed = analysis.get(document)
  local items = completion.complete(analyzed, document, params.position or { line = 0, character = 0 }, {
    snippets = self.supports_snippets,
  })

  self:respond(message.id, {
    isIncomplete = false,
    items = items,
  })
end

function Server:handle_hover(params, message)
  local document = self:document_for(params)
  if not document then
    self:respond(message.id, json.null)
    return
  end
  local analyzed = analysis.get(document)
  local result = hover.hover(analyzed, document, params.position or { line = 0, character = 0 })
  self:respond(message.id, result or json.null)
end

function Server:handle_document_symbol(params, message)
  local document = self:document_for(params)
  if not document then
    self:respond(message.id, json.array({}))
    return
  end
  local analyzed = analysis.get(document)
  self:respond(message.id, symbols.document_symbols(analyzed.ast, document))
end

function Server:dispatch(message)
  if type(message) ~= "table" then
    self:respond_error(json.null, ERROR.InvalidRequest, "Invalid Request")
    return
  end

  local method = message.method
  if type(method) ~= "string" then
    -- This is a response to a server-initiated request.  We do not send
    -- requests in round 1, so there is nothing to match it to.
    return
  end

  local id = message.id
  local is_request = id ~= nil
  local handler = self.handlers[method]

  if not handler then
    if is_request then
      self:respond_error(id, ERROR.MethodNotFound, "Method not found: " .. method)
    end
    return
  end

  if not self.initialized and method ~= "initialize" and method ~= "exit" then
    if is_request then
      self:respond_error(id, ERROR.ServerNotInitialized, "Server not initialized")
    end
    return
  end

  if self.shutdown_requested and method ~= "exit" then
    if is_request then
      self:respond_error(id, ERROR.InvalidRequest, "Server is shutting down")
    end
    return
  end

  local ok, err = pcall(handler, self, message.params or {}, message)
  if not ok then
    log.error("handler %s failed: %s", method, tostring(err))
    if is_request then
      self:respond_error(id, ERROR.InternalError, "Internal error")
    end
  end
end

return Server
