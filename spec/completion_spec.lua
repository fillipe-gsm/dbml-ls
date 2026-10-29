local support = dofile("spec/support.lua")

local function labels(text, options)
  return support.labels(support.complete_at(text, options))
end

describe("completion", function()
  it("offers top-level keywords and replaces the typed prefix", function()
    local items = support.complete_at("Ta|")
    assert.is_true(labels("Ta|").Table)

    local table_item = support.find(items, "Table")
    assert.equal(0, table_item.textEdit.range.start.line)
    assert.equal(0, table_item.textEdit.range.start.character)
    assert.equal(2, table_item.textEdit.range["end"].character)
    assert.equal("Table", table_item.textEdit.newText)
  end)

  it("does not offer keywords while a table name is being typed", function()
    assert.same({}, support.complete_at("Table |"))
    assert.same({}, support.complete_at("Enum |"))
  end)

  it("offers types after a column name", function()
    local result = labels("Table users {\n  id |")
    assert.is_true(result.integer)
    assert.is_true(result.varchar)
    assert.is_true(result.uuid)
  end)

  it("offers types while the type is being typed", function()
    local items = support.complete_at("Table users {\n  id int|")
    local integer = support.find(items, "integer")
    assert.is_not_nil(integer)
    assert.equal(5, integer.textEdit.range.start.character)
    assert.equal(8, integer.textEdit.range["end"].character)
  end)

  it("offers user-defined enums as column types", function()
    local result = labels("Enum status {\n  active\n}\nTable users {\n  state |")
    assert.is_true(result.integer)
    assert.is_true(result.status)
  end)

  it("offers column settings inside brackets", function()
    local result = labels("Table users {\n  id integer [p|")
    assert.is_true(result.pk)
    assert.is_true(result.unique)
    assert.is_true(result["not null"])
  end)

  it("offers columns after table/alias member access", function()
    local result = labels("Table users as U {\n  id integer\n  email varchar\n}\nRef: U.|")
    assert.is_true(result.id)
    assert.is_true(result.email)
    assert.is_nil(result.integer)
  end)

  it("offers enum values after enum member access", function()
    local result = labels("Enum status {\n  active\n  disabled\n}\nRef: status.|")
    assert.is_true(result.active)
    assert.is_true(result.disabled)
  end)

  it("offers tables while writing a ref", function()
    local result = labels("Table users {\n  id integer\n}\nRef: |")
    assert.is_true(result.users)
  end)

  it("offers relationship operators after an endpoint", function()
    local result = labels("Table users {\n  id integer\n}\nRef: users.id |")
    assert.is_true(result[">"])
    assert.is_true(result["<"])
    assert.is_true(result["<>"])
  end)

  it("offers table columns inside an indexes block", function()
    local result = labels("Table users {\n  id integer\n  indexes {\n    (|)\n  }\n}")
    assert.is_true(result.id)
  end)

  it("offers settings in a table header", function()
    local result = labels("Table users [|")
    assert.is_true(result.headercolor)
    assert.is_true(result.pk)
  end)

  it("offers tables in an inline column ref", function()
    local result = labels(
      "Table users {\n  id integer\n}\nTable orders {\n  user_id integer [ref: > |"
    )
    assert.is_true(result.users)
  end)

  it("offers columns in an inline column ref after the table name", function()
    local result = labels(
      "Table users {\n  id integer\n}\nTable orders {\n  user_id integer [ref: > users.|"
    )
    assert.is_true(result.id)
  end)

  it("offers project keys inside a Project block", function()
    local result = labels("Project demo {\n  |\n}")
    assert.is_true(result.database_type)
    assert.is_true(result.Note)
  end)

  it("offers Note inside an Enum block", function()
    local result = labels("Enum status {\n  |\n}")
    assert.is_true(result.Note)
  end)

  it("uses snippets only when the client supports them", function()
    local with_snippets = support.find(support.complete_at("Tab|", { snippets = true }), "Table")
    local without_snippets = support.find(support.complete_at("Tab|", { snippets = false }), "Table")

    assert.equal(2, with_snippets.insertTextFormat)
    assert.matches("Table ${1:name}", with_snippets.insertText)
    assert.is_nil(without_snippets.insertTextFormat)
    assert.equal("Table", without_snippets.insertText)
  end)
end)
