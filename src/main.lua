-- dbml-ls entrypoint: JSON-RPC over stdin/stdout.
--
-- Nothing except protocol messages may be written to stdout; all logging
-- goes to stderr.

local info = debug.getinfo(1, "S")
local script = (info and info.source or "@src/main.lua"):sub(2)
local script_dir = script:match("^(.*)[/\\]") or "."
package.path = script_dir .. "/?.lua;" .. script_dir .. "/?/init.lua;" .. package.path

local rpc = require("dbml.rpc")
local json = require("dbml.json")
local log = require("dbml.log")
local Server = require("dbml.server")

io.stdout:setvbuf("no")

---@type dbml.Server
local server = Server.new({
  ---@param message table
  send = function(message)
    rpc.write_message(io.stdout, message)
  end,
})

---@type integer?
local exit_code = nil

while not exit_code do
  local message, kind, detail = rpc.read_message(io.stdin)

  if message then
    server:dispatch(message)
    if server.exit_code ~= nil then
      exit_code = server.exit_code
    end
  elseif kind == "eof" then
    exit_code = 0
  elseif kind == "parse" then
    log.warn("could not parse message: %s", tostring(detail))
    rpc.write_message(io.stdout, {
      jsonrpc = "2.0",
      id = json.null,
      error = {
        code = -32700,
        message = "Parse error: " .. tostring(detail),
      },
    })
  else
    log.error("framing error: %s", tostring(detail or kind))
    exit_code = 1
  end
end

io.stdout:flush()
os.exit(exit_code)
