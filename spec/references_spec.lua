local support = dofile("spec/support.lua")

local function starts(locations)
  local result = {}
  for _, location in ipairs(locations) do
    result[#result + 1] = location.range.start.line .. ":" .. location.range.start.character
  end
  return result
end

describe("references", function()
  it("finds table references with and without the declaration", function()
    local text = [[
Table us|ers {
  id integer
}
Table orders {
  user_id integer [ref: > users.id]
}
TableGroup core {
  users
}
Ref: users.id < orders.user_id
]]

    local with_declaration = support.references_at(text, true)
    assert.same({ "0:6", "4:26", "7:2", "9:5" }, starts(with_declaration))

    local without_declaration = support.references_at(text, false)
    assert.same({ "4:26", "7:2", "9:5" }, starts(without_declaration))
  end)

  it("finds column references with and without the declaration", function()
    local text = [[
Table users {
  i|d integer
  indexes {
    (id)
  }
}
Table orders {
  user_id integer [ref: > users.id]
}
Ref: users.id < orders.user_id
]]

    assert.same(
      { "1:2", "3:5", "7:32", "9:11" },
      starts(support.references_at(text, true))
    )
    assert.same(
      { "3:5", "7:32", "9:11" },
      starts(support.references_at(text, false))
    )
  end)

  it("finds alias references", function()
    local text = [[
Table users as U| {
  id integer
}
Table orders {
  user_id integer
}
TableGroup core {
  U
}
Ref: U.id < orders.user_id
]]

    assert.same(
      { "0:15", "7:2", "9:5" },
      starts(support.references_at(text, true))
    )
  end)

  it("finds enum references in schema-qualified and bare type usages", function()
    local text = [[
Enum v2.stat|us {
  active
}
Table users {
  s v2.status
}
Table audits {
  s status
}
]]

    local locations = support.references_at(text, true)
    assert.equal(3, #locations)
    assert.same({ 0, 4, 7 }, {
      locations[1].range.start.line,
      locations[2].range.start.line,
      locations[3].range.start.line,
    })
  end)

  it("finds enum value references in defaults", function()
    local text = [[
Enum category {
  bar|bell
  dumbbell
}
Table exercise {
  category category [default: 'barbell']
}
]]

    assert.same({ "1:2", "5:30" }, starts(support.references_at(text, true)))
    assert.same({ "5:30" }, starts(support.references_at(text, false)))
  end)

  it("finds table partial includes", function()
    local text = [[
TablePartial ba|se {
  id integer
}
Table users {
  ~base
}
]]

    assert.same({ "0:13", "4:3" }, starts(support.references_at(text, true)))
  end)

  it("returns no references from settings or operators", function()
    assert.same(
      {},
      support.references_at("Table users [head|ercolor: #fff] {\n  id integer\n}", true)
    )
    assert.same(
      {},
      support.references_at("Table users {\n  id integer\n}\nRef: users.id <| orders.id", true)
    )
  end)

  it("returns declaration-only results for groups and projects", function()
    local group = support.references_at("TableGroup co|re {\n  users\n}", true)
    assert.equal(1, #group)

    local group_without = support.references_at("TableGroup co|re {\n  users\n}", false)
    assert.same({}, group_without)

    local project = support.references_at("Project wo|rkout {\n  database_type: 'SQLite'\n}", true)
    assert.equal(1, #project)
  end)
end)
