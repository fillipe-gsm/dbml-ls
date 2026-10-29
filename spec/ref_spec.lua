local ref = require("dbml.ref")
local support = dofile("spec/support.lua")

local function endpoint(table_name, column_name, start)
  start = start or 0
  return ref.Endpoint.new({
    table = table_name,
    column = column_name,
    range = { start = start, stop = start + 1 },
    table_range = { start = start, stop = start + 1 },
    column_range = { start = start + 1, stop = start + 2 },
    name = table_name .. "." .. column_name,
  })
end

describe("ref", function()
  it("requires endpoint fields", function()
    local ok = pcall(ref.Endpoint.new, { table = "users" })
    assert.is_false(ok)
  end)

  it("accepts optional relationship markers", function()
    assert.is_true(ref.is_operator(">"))
    assert.is_true(ref.is_operator("?>"))
    assert.is_true(ref.is_operator(">?"))
    assert.is_true(ref.is_operator("?<>"))
    assert.is_false(ref.is_operator("??>"))
    assert.is_false(ref.is_operator("?"))
  end)

  it("requires a valid reference operator", function()
    local ok = pcall(ref.Reference.new, {
      from = endpoint("a", "id"),
      to = endpoint("b", "id"),
      operator = "?",
      source = "top_level",
      range = { start = 0, stop = 1 },
    })
    assert.is_false(ok)
  end)

  it("requires valid reference sources", function()
    local ok = pcall(ref.Reference.new, {
      from = endpoint("a", "id"),
      to = endpoint("b", "id"),
      operator = ">",
      source = "elsewhere",
      range = { start = 0, stop = 1 },
    })
    assert.is_false(ok)
  end)

  it("builds endpoints from parsed table columns", function()
    local analyzed = support.analyze("Table public.users {\n  id integer\n}")
    local table = analyzed.ast.tables[1]
    local built = ref.Endpoint.from_table_column(table, table.columns[1])

    assert.equal("public", built.schema)
    assert.equal("users", built.table)
    assert.equal("id", built.column)
    assert.equal("public.users.id", built.name)
    assert.same({ "public", "users", "id" }, built.parts)
  end)

  it("collects top-level and inline refs", function()
    local analyzed = support.analyze([[
Table users {
  id integer
}
Table orders {
  user_id integer [ref: > users.id]
}
Ref: users.id < orders.user_id
]])

    local all = ref.all(analyzed.ast)
    assert.equal(2, #all)

    local inline, top_level
    for _, reference in ipairs(all) do
      if reference.source == "inline" then
        inline = reference
      else
        top_level = reference
      end
    end

    assert.is_not_nil(inline)
    assert.equal("orders.user_id", inline.from.name)
    assert.equal("users.id", inline.to.name)

    assert.is_not_nil(top_level)
    assert.equal("users.id", top_level.from.name)
    assert.equal("orders.user_id", top_level.to.name)
  end)
end)
