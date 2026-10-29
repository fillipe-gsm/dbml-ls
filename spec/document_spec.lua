local Document = require("dbml.document")

describe("document", function()
  it("maps offsets to positions for ASCII text", function()
    local document = Document.new("file:///a.dbml", "abc\ndef", 1)
    assert.same({ line = 0, character = 0 }, document:position_at(0))
    assert.same({ line = 0, character = 3 }, document:position_at(3))
    assert.same({ line = 1, character = 0 }, document:position_at(4))
    assert.same({ line = 1, character = 3 }, document:position_at(7))
  end)

  it("maps positions to offsets and clamps them", function()
    local document = Document.new("file:///a.dbml", "abc\ndef", 1)
    assert.equal(6, document:offset_at({ line = 1, character = 2 }))
    assert.equal(3, document:offset_at({ line = 0, character = 99 }))
    assert.equal(7, document:offset_at({ line = 99, character = 0 }))
  end)

  it("returns line text without the newline", function()
    local document = Document.new("file:///a.dbml", "abc\ndef\n", 1)
    assert.equal("abc", document:line_text(0))
    assert.equal("def", document:line_text(1))
    assert.equal("", document:line_text(2))
    assert.equal(3, document:line_count())
  end)

  it("counts UTF-8 bytes when the negotiated encoding is utf-8", function()
    local document = Document.new("file:///a.dbml", "é x", 1)
    document.encoding = "utf-8"
    assert.same({ line = 0, character = 2 }, document:position_at(2))
    assert.equal(2, document:offset_at({ line = 0, character = 2 }))
  end)

  it("counts UTF-16 code units when the negotiated encoding is utf-16", function()
    local document = Document.new("file:///a.dbml", "é x", 1)
    document.encoding = "utf-16"
    assert.same({ line = 0, character = 1 }, document:position_at(2))
    assert.equal(2, document:offset_at({ line = 0, character = 1 }))
    assert.same({ line = 0, character = 2 }, document:position_at(3))
  end)

  it("treats astral characters as a surrogate pair in utf-16", function()
    local document = Document.new("file:///a.dbml", "😀x", 1)
    document.encoding = "utf-16"
    assert.same({ line = 0, character = 2 }, document:position_at(4))
    assert.equal(4, document:offset_at({ line = 0, character = 2 }))
  end)

  it("applies ranged changes", function()
    local document = Document.new("file:///a.dbml", "hello world", 1)
    document:apply_change({
      range = {
        start = { line = 0, character = 6 },
        ["end"] = { line = 0, character = 11 },
      },
      text = "there",
    }, 2)
    assert.equal("hello there", document.text)
    assert.equal(2, document.version)
  end)

  it("applies full-text changes", function()
    local document = Document.new("file:///a.dbml", "old", 1)
    document:apply_change({ text = "new" }, 2)
    assert.equal("new", document.text)
  end)
end)
