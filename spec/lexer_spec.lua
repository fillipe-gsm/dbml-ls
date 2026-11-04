local lexer = require("dbml.lexer")

local function values(tokens)
  local result = {}
  for _, token in ipairs(tokens) do
    if token.type ~= "eof" then
      result[#result + 1] = token.value
    end
  end
  return result
end

describe("lexer", function()
  it("tokenizes a simple table", function()
    local tokens = lexer.tokenize("Table users {\n  id integer [pk]\n}")
    assert.same({
      "Table", "users", "{",
      "id", "integer", "[", "pk", "]",
      "}",
    }, values(tokens))
  end)

  it("tracks 0-based byte offsets", function()
    local text = "Table users {\n  id integer [pk]\n}"
    local tokens = lexer.tokenize(text)
    local id = tokens[4]
    assert.equal("id", id.value)
    assert.equal(16, id.start)
    assert.equal(18, id.stop)
    assert.equal(1, id.line)
    assert.equal(2, id.col)
    assert.equal("id", text:sub(id.start + 1, id.stop))
  end)

  it("skips line and block comments", function()
    local tokens = lexer.tokenize("// comment\nTable /* inline */ users {}")
    assert.same({ "Table", "users", "{", "}" }, values(tokens))
  end)

  it("can retain comments for the formatter", function()
    local tokens = lexer.tokenize("// comment\nTable /* inline */ users {}", { comments = true })
    assert.same({ "// comment", "Table", "/* inline */", "users", "{", "}" }, values(tokens))
    assert.equal("line", tokens[1].kind)
    assert.equal("block", tokens[3].kind)
  end)

  it("decodes single-quoted escapes", function()
    local tokens = lexer.tokenize([[Note: 'hello\nworld']])
    local string = tokens[3]
    assert.equal("string", string.type)
    assert.equal("hello\nworld", string.value)
  end)

  it("tokenizes backtick expressions", function()
    local tokens = lexer.tokenize("default: `now() - interval '5 days'`")
    local expression = tokens[3]
    assert.equal("expression", expression.type)
    assert.equal("now() - interval '5 days'", expression.value)
  end)

  it("supports triple-quoted strings", function()
    local tokens = lexer.tokenize("Note: '''line one\nline two'''")
    assert.equal("line one\nline two", tokens[3].value)
  end)

  it("keeps multi-byte identifiers intact", function()
    local text = "Table usuários {}"
    local tokens = lexer.tokenize(text)
    assert.equal("usuários", tokens[2].value)
    assert.equal(text:sub(tokens[2].start + 1, tokens[2].stop), tokens[2].value)
  end)

  it("reports unterminated strings", function()
    local _, errors = lexer.tokenize("Note: 'oops")
    assert.equal(1, #errors)
    assert.matches("unterminated", errors[1].message)
  end)

  it("reports unterminated block comments", function()
    local _, errors = lexer.tokenize("/* oops")
    assert.equal(1, #errors)
    assert.matches("unterminated", errors[1].message)
  end)
end)
