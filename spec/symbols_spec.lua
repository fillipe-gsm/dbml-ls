local support = dofile("spec/support.lua")
local symbols_module = require("dbml.symbols")

local SAMPLE = [[
Table public.users as U {
  id integer [pk]
  email varchar(255)
}

Enum status {
  active
  disabled
}

Ref: users.id < orders.user_id
]]

local function within(inner, outer)
  local function before(a, b)
    return a.line < b.line or (a.line == b.line and a.character <= b.character)
  end
  return before(outer.start, inner.start) and before(inner["end"], outer["end"])
end

describe("symbols", function()
  it("builds lookup tables for names, aliases, and columns", function()
    local analyzed = support.analyze(SAMPLE)
    local symbols = analyzed.symbols
    local table = symbols_module.find_table(symbols, "users")
    local alias = symbols_module.find_table(symbols, "U")
    local public = symbols_module.find_table(symbols, "public.users")

    assert.is_not_nil(table)
    assert.equal(table, alias)
    assert.equal(table, public)
    assert.equal("id", symbols_module.find_column(symbols, "users", "id").name)
    assert.equal("email", symbols_module.find_column(symbols, "U", "email").name)
  end)

  it("returns document symbols for tables, columns, enums, and refs", function()
    local result = support.symbols(SAMPLE)
    assert.equal(3, #result)

    local table = result[1]
    assert.equal("public.users", table.name)
    assert.equal(5, table.kind)
    assert.equal(2, #table.children)
    assert.equal("id", table.children[1].name)
    assert.equal(8, table.children[1].kind)
    assert.equal("integer", table.children[1].detail)
    assert.is_true(within(table.children[1].range, table.range))
    assert.is_true(within(table.children[1].selectionRange, table.range))

    local enum = result[2]
    assert.equal("status", enum.name)
    assert.equal(10, enum.kind)
    assert.equal(2, #enum.children)
    assert.equal(22, enum.children[1].kind)

    local ref = result[3]
    assert.equal(25, ref.kind)
    assert.matches("users.id < orders.user_id", ref.name)
    assert.is_true(within(ref.selectionRange, ref.range))
  end)

  it("handles an empty document", function()
    assert.same({}, support.symbols(""))
  end)
end)
