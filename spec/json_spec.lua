local json = require("dbml.json")

describe("json", function()
  it("encodes empty tables as arrays", function()
    assert.equal("[]", json.encode({}))
    assert.equal("[]", json.encode(json.array()))
  end)

  it("encodes empty tables marked as objects as objects", function()
    assert.equal("{}", json.encode(json.object()))
  end)

  it("preserves null in objects and arrays", function()
    local value = json.decode('{"a":null,"b":[null,1]}')
    assert.equal(json.null, value.a)
    assert.equal(json.null, value.b[1])
    assert.equal(1, value.b[2])
  end)

  it("round-trips nested values", function()
    local original = {
      jsonrpc = "2.0",
      id = 1,
      result = {
        items = {
          { label = "Table", kind = 14 },
        },
      },
    }
    local decoded = json.decode(json.encode(original))
    assert.equal("2.0", decoded.jsonrpc)
    assert.equal(1, decoded.id)
    assert.equal("Table", decoded.result.items[1].label)
  end)

  it("rejects trailing garbage", function()
    local value, err = json.decode('{"a":1} garbage')
    assert.is_nil(value)
    assert.is_truthy(err)
  end)
end)
