local Document = require("dbml.document")
local analysis = require("dbml.analysis")

local M = {}

function M.document(text, encoding)
  local document = Document.new("file:///test.dbml", text, 1)
  document.encoding = encoding or "utf-8"
  return document
end

function M.analyze(text, encoding)
  local document = M.document(text, encoding)
  return analysis.get(document), document
end

function M.complete(text, line, character, options)
  local analyzed, document = M.analyze(text)
  return require("dbml.completion").complete(
    analyzed,
    document,
    { line = line, character = character },
    options or { snippets = false }
  )
end

function M.hover(text, line, character)
  local analyzed, document = M.analyze(text)
  return require("dbml.hover").hover(analyzed, document, {
    line = line,
    character = character,
  })
end

function M.hover_at(text_with_cursor)
  local text, line, character = M.cursor(text_with_cursor)
  return M.hover(text, line, character)
end

function M.definition_at(text_with_cursor)
  local text, line, character = M.cursor(text_with_cursor)
  local analyzed, document = M.analyze(text)
  return require("dbml.definition").definition(analyzed, document, {
    line = line,
    character = character,
  })
end

function M.symbols(text)
  local analyzed, document = M.analyze(text)
  return require("dbml.symbols").document_symbols(analyzed.ast, document)
end

--- Split a fixture containing a `|` cursor marker into text/position.
function M.cursor(text_with_cursor)
  local marker = text_with_cursor:find("|", 1, true)
  assert(marker, "fixture must contain a | cursor marker")
  local before = text_with_cursor:sub(1, marker - 1)
  local text = before .. text_with_cursor:sub(marker + 1)
  local line = select(2, before:gsub("\n", ""))
  local last_newline = before:match(".*()\n") or 0
  return text, line, #before - last_newline
end

function M.complete_at(text_with_cursor, options)
  local text, line, character = M.cursor(text_with_cursor)
  return M.complete(text, line, character, options)
end

function M.labels(items)
  local labels = {}
  for _, item in ipairs(items) do
    labels[item.label] = true
  end
  return labels
end

function M.find(items, label)
  for _, item in ipairs(items) do
    if item.label == label then
      return item
    end
  end
  return nil
end

return M
