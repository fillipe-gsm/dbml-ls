local support = dofile("spec/support.lua")

local function assert_location(location, line, start_character, end_character)
  assert.is_not_nil(location)
  assert.equal(line, location.range.start.line)
  assert.equal(start_character, location.range.start.character)
  assert.equal(line, location.range["end"].line)
  assert.equal(end_character, location.range["end"].character)
end

describe("definition", function()
  it("resolves a table declaration to itself", function()
    assert_location(support.definition_at("Table us|ers {\n  id integer\n}"), 0, 6, 11)
  end)

  it("resolves a column declaration to itself", function()
    assert_location(support.definition_at("Table users {\n  i|d integer\n}"), 1, 2, 4)
  end)

  it("resolves a ref column to its column declaration", function()
    assert_location(
      support.definition_at("Table users {\n  id integer\n}\nRef: users.i|d < orders.user_id"),
      1,
      2,
      4
    )
  end)

  it("resolves a ref table to its table declaration", function()
    assert_location(
      support.definition_at("Table users {\n  id integer\n}\nRef: us|ers.id < orders.user_id"),
      0,
      6,
      11
    )
  end)

  it("resolves an alias member to the real column", function()
    assert_location(
      support.definition_at("Table users as U {\n  id integer\n}\nRef: U.i|d > orders.user_id"),
      1,
      2,
      4
    )
  end)

  it("resolves a column's enum type to the enum declaration", function()
    assert_location(
      support.definition_at("Enum status {\n  active\n}\nTable users {\n  s stat|us\n}"),
      0,
      5,
      11
    )
  end)

  it("resolves a schema-qualified enum type", function()
    assert_location(
      support.definition_at("Enum v2.status {\n  active\n}\nTable users {\n  s v2.stat|us\n}"),
      0,
      5,
      14
    )
  end)

  it("resolves an enum value declaration to itself", function()
    assert_location(support.definition_at("Enum status {\n  act|ive\n}"), 1, 2, 8)
  end)

  it("resolves a composite ref column to its declaration", function()
    local location = support.definition_at([[
Table a {
  x integer
  y integer
}
Table b {
  x integer
  y integer
}
Ref: a.(x, y|) > b.(x, y)
]])
    assert_location(location, 2, 2, 3)
  end)

  it("resolves an index column to its declaration", function()
    assert_location(
      support.definition_at("Table users {\n  id integer\n  indexes {\n    (i|d)\n  }\n}"),
      1,
      2,
      4
    )
  end)

  it("resolves a table group member to its table", function()
    assert_location(
      support.definition_at("Table users {\n  id integer\n}\nTableGroup core {\n  us|ers\n}"),
      0,
      6,
      11
    )
  end)

  it("resolves a table partial include to the partial", function()
    local location = support.definition_at([[
TablePartial base {
  id integer
}
Table users {
  ~ba|se
}
]])
    assert_location(location, 0, 13, 17)
  end)

  it("resolves an inline ref target column", function()
    assert_location(
      support.definition_at([[
Table users {
  id integer
}
Table orders {
  user_id integer [ref: > users.i|d]
}
]]),
      1,
      2,
      4
    )
  end)

  it("resolves an inline ref target table", function()
    assert_location(
      support.definition_at([[
Table users {
  id integer
}
Table orders {
  user_id integer [ref: > us|ers.id]
}
]]),
      0,
      6,
      11
    )
  end)

  it("returns nothing on whitespace", function()
    assert.is_nil(support.definition_at("Table users {\n  id integer\n}\n  |\n"))
  end)

  it("returns nothing for a non-enum type", function()
    assert.is_nil(support.definition_at("Table users {\n  id int|eger\n}"))
  end)

  it("returns nothing for an unresolved ref", function()
    assert.is_nil(
      support.definition_at("Table users {\n  id integer\n}\nRef: users.id < miss|ing.id\n")
    )
  end)
end)
