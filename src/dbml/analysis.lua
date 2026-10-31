-- Parse cache and semantic analysis for a document.

local lexer = require("dbml.lexer")
local parser = require("dbml.parser")
local symbols = require("dbml.symbols")

local M = {}

---@param document dbml.Document
---@return dbml.Analysis
function M.get(document)
  if document._analysis and document._analysis_version == document.version then
    return document._analysis
  end

  local tokens, lexer_errors = lexer.tokenize(document.text)
  local ast, parser_errors = parser.parse(tokens, document.text)

  local errors = {}
  for _, error in ipairs(lexer_errors) do
    errors[#errors + 1] = error
  end
  for _, error in ipairs(parser_errors) do
    errors[#errors + 1] = error
  end

  local analysis = {
    tokens = tokens,
    ast = ast,
    errors = errors,
    symbols = symbols.build(ast),
  }

  document._analysis = analysis
  document._analysis_version = document.version
  return analysis
end

return M
