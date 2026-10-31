local support = dofile("spec/support.lua")

local function apply_edit(text, document, workspace_edit)
  assert.is_not_nil(workspace_edit)
  local edits = workspace_edit.changes[document.uri]
  assert.is_not_nil(edits)

  table.sort(edits, function(a, b)
    return document:offset_at(a.range.start) > document:offset_at(b.range.start)
  end)

  for _, edit in ipairs(edits) do
    local start_offset = document:offset_at(edit.range.start)
    local end_offset = document:offset_at(edit.range["end"])
    text = text:sub(1, start_offset) .. edit.newText .. text:sub(end_offset + 1)
  end
  return text
end

local function renamed(text_with_cursor, new_name)
  local workspace_edit, document, text = support.rename_at(text_with_cursor, new_name)
  return apply_edit(text, document, workspace_edit)
end

describe("rename", function()
  it("renames a table declaration, refs, inline refs, and group members", function()
    local input = [[
Table users {
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

    local result = renamed(
      "Table us|ers {\n  id integer\n}\n\n"
        .. "Table orders {\n  user_id integer [ref: > users.id]\n}\n\n"
        .. "TableGroup core {\n  users\n}\n\n"
        .. "Ref: users.id < orders.user_id\n",
      "accounts"
    )
    assert.equal(input:gsub("users", "accounts"), result)
  end)

  it("does not rewrite alias references when renaming the table name", function()
    local result = renamed([[
Table us|ers as U {
  id integer
}
Table orders {
  user_id integer
}
Ref: U.id < orders.user_id
]], "accounts")

    assert.equal([[
Table accounts as U {
  id integer
}
Table orders {
  user_id integer
}
Ref: U.id < orders.user_id
]], result)
  end)

  it("renames a column declaration, refs, inline refs, and indexes", function()
    local result = renamed([[
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
]], "uid")

    assert.equal([[
Table users {
  uid integer
  indexes {
    (uid)
  }
}
Table orders {
  user_id integer [ref: > users.uid]
}
Ref: users.uid < orders.user_id
]], result)
  end)

  it("renames an alias without touching the real table name", function()
    local result = renamed([[
Table users as U| {
  id integer
}
Table orders {
  user_id integer [ref: > U.id]
}
TableGroup core {
  U
}
Ref: U.id < orders.user_id
]], "usr")

    assert.equal([[
Table users as usr {
  id integer
}
Table orders {
  user_id integer [ref: > usr.id]
}
TableGroup core {
  usr
}
Ref: usr.id < orders.user_id
]], result)
  end)

  it("renames an alias from a ref usage", function()
    local result = renamed([[
Table users as U {
  id integer
}
Table orders {
  user_id integer
}
Ref: U|.id < orders.user_id
]], "usr")

    assert.equal([[
Table users as usr {
  id integer
}
Table orders {
  user_id integer
}
Ref: usr.id < orders.user_id
]], result)
  end)

  it("renames an enum and updates both schema-qualified and bare type usages", function()
    local result = renamed([[
Enum v2.stat|us {
  active
}
Table users {
  s v2.status
}
Table audits {
  s status
}
]], "job_status")

    assert.equal([[
Enum v2.job_status {
  active
}
Table users {
  s v2.job_status
}
Table audits {
  s job_status
}
]], result)
  end)

  it("renames an enum value and updates matching defaults", function()
    local result = renamed([[
Enum category {
  bar|bell
  dumbbell
}
Table exercise {
  category category [default: 'barbell']
}
]], "free_weight")

    assert.equal([[
Enum category {
  free_weight
  dumbbell
}
Table exercise {
  category category [default: 'free_weight']
}
]], result)
  end)

  it("quotes names that need quoting", function()
    local result = renamed([[
Table users {
  "full na|me" varchar
}
]], "display name")

    assert.equal([[
Table users {
  "display name" varchar
}
]], result)
  end)

  it("preserves schemas when renaming a table", function()
    local result = renamed([[
Table public.us|ers {
  id integer
}
Table orders {
  id integer
}
Ref: public.users.id < orders.id
]], "accounts")

    assert.equal([[
Table public.accounts {
  id integer
}
Table orders {
  id integer
}
Ref: public.accounts.id < orders.id
]], result)
  end)

  it("renames a column in a composite ref without touching the other table", function()
    local result = renamed([[
Table a {
  x integer
  y| integer
}
Table b {
  x integer
  y integer
}
Ref: a.(x, y) > b.(x, y)
]], "z")

    assert.equal([[
Table a {
  x integer
  z integer
}
Table b {
  x integer
  y integer
}
Ref: a.(x, z) > b.(x, y)
]], result)
  end)

  it("renames a table partial and its includes", function()
    local result = renamed([[
TablePartial base {
  id integer
}
Table users {
  ~ba|se
}
]], "common")

    assert.equal([[
TablePartial common {
  id integer
}
Table users {
  ~common
}
]], result)
  end)

  it("prepares rename on a symbol and rejects non-symbol positions", function()
    local prepared = support.prepare_rename_at("Table us|ers {\n  id integer\n}")
    assert.is_not_nil(prepared)
    assert.equal("users", prepared.placeholder)
    assert.equal(0, prepared.range.start.line)
    assert.equal(6, prepared.range.start.character)

    assert.is_nil(support.prepare_rename_at("Table users [head|ercolor: #fff] {\n  id integer\n}"))
    assert.is_nil(
      support.prepare_rename_at("Table users {\n  id integer\n}\nRef: users.id <| orders.id")
    )
  end)

  it("refuses collisions and invalid names", function()
    assert.is_nil(support.rename_at("Table us|ers {\n  id integer\n}\nTable orders {\n  id integer\n}", "orders"))
    assert.is_nil(support.rename_at("Table users {\n  i|d integer\n  name varchar\n}", "name"))
    assert.is_nil(support.rename_at("Table us|ers {\n  id integer\n}", ""))
    assert.is_nil(support.rename_at("Table us|ers {\n  id integer\n}", "   "))
    assert.is_nil(support.rename_at("Table us|ers {\n  id integer\n}", "bad\nname"))
    assert.is_nil(support.rename_at("Table us|ers {\n  id integer\n}", "users"))
  end)
end)
