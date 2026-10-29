local diagnostics = require("dbml.diagnostics")
local support = dofile("spec/support.lua")

local function diagnose(text)
  local analyzed, document = support.analyze(text)
  return diagnostics.diagnose(analyzed, document), document
end

local function find(items, code)
  for _, item in ipairs(items) do
    if item.code == code then
      return item
    end
  end
  return nil
end

local VALID = [[
Table users {
  id integer [pk]
  email varchar(255)
}

Table orders {
  id integer [pk]
  user_id integer [ref: > users.id]
}

Enum status {
  active
  disabled
}

TableGroup core {
  users
  orders
}

Ref: users.id < orders.user_id
]]

describe("diagnostics", function()
  it("reports nothing for a valid document", function()
    local result = diagnose(VALID)
    assert.same({}, result)
  end)

  it("does not flag modern DBML constructs as syntax errors", function()
    local result = diagnose([[
Table users {
  id integer [pk]
  score "double precision"
  checks {
    `id > 0` [name: 'chk_positive']
  }
  records (id) {
    1
  }
}

Enum v2.job_status {
  active
}

Table jobs {
  id integer
  status v2.job_status
  indexes {
    (id, status) [unique]
    (`id*2`)
    (lower(status))
  }
  records (id, status) {
    1, 'active'
  }
}

Ref: jobs.(id, status) > users.(id, id)
Ref: jobs.id ?> users.id

records users(id) [example] {
  1
}
]])
    assert.same({}, result)
  end)

  it("reports syntax errors as errors", function()
    local result = diagnose("Table users {\n  id\n}\n")
    local syntax = find(result, "syntax")
    assert.is_not_nil(syntax)
    assert.equal(1, syntax.severity)
    assert.equal("dbml-ls", syntax.source)
    assert.is_not_nil(syntax.range.start)
    assert.is_not_nil(syntax.range["end"])
  end)

  it("reports duplicate tables with related information", function()
    local result, document = diagnose("Table users {\n  id integer\n}\nTable users {\n  id integer\n}\n")
    local duplicate = find(result, "duplicate-table")
    assert.is_not_nil(duplicate)
    assert.equal(1, duplicate.severity)
    assert.is_not_nil(duplicate.relatedInformation)
    assert.equal(document.uri, duplicate.relatedInformation[1].location.uri)
  end)

  it("reports duplicate columns", function()
    local result = diagnose("Table users {\n  id integer\n  id varchar\n}\n")
    assert.is_not_nil(find(result, "duplicate-column"))
  end)

  it("reports duplicate enums and enum values", function()
    local enums = diagnose("Enum status {\n  active\n}\nEnum status {\n  disabled\n}\n")
    assert.is_not_nil(find(enums, "duplicate-enum"))

    local values = diagnose("Enum status {\n  active\n  active\n}\n")
    assert.is_not_nil(find(values, "duplicate-enum-value"))
  end)

  it("treats schema-qualified enums as distinct", function()
    local result = diagnose("Enum v1.status {\n  active\n}\nEnum v2.status {\n  inactive\n}\n")
    assert.same({}, result)
  end)

  it("reports duplicate aliases and ref names", function()
    local aliases = diagnose("Table users as U {\n  id integer\n}\nTable orders as U {\n  id integer\n}\n")
    assert.is_not_nil(find(aliases, "duplicate-alias"))

    local refs = diagnose([[
Table a {
  id integer
}
Table b {
  id integer
}
Ref pair: a.id < b.id
Ref pair: a.id < b.id
]])
    assert.is_not_nil(find(refs, "duplicate-ref-name"))
  end)

  it("reports unknown index columns", function()
    local result = diagnose([[
Table users {
  id integer
  indexes {
    (missing) [unique]
  }
}
]])
    local unknown = find(result, "unknown-index-column")
    assert.is_not_nil(unknown)
    assert.equal(1, unknown.severity)
  end)

  it("warns about unknown table group members", function()
    local result = diagnose("TableGroup core {\n  missing\n}\n")
    local unknown = find(result, "unresolved-table-group-member")
    assert.is_not_nil(unknown)
    assert.equal(2, unknown.severity)
  end)

  it("warns about unknown tables in refs", function()
    local result = diagnose([[
Table users {
  id integer
}
Ref: users.id < missing.id
]])
    local unknown = find(result, "unresolved-ref-table")
    assert.is_not_nil(unknown)
    assert.equal(2, unknown.severity)
  end)

  it("warns about unknown columns in refs", function()
    local result = diagnose([[
Table users {
  id integer
}
Table orders {
  id integer
}
Ref: users.missing < orders.id
]])
    local unknown = find(result, "unresolved-ref-column")
    assert.is_not_nil(unknown)
    assert.equal(2, unknown.severity)
  end)

  it("checks inline refs too", function()
    local result = diagnose([[
Table users {
  id integer
}
Table orders {
  user_id integer [ref: > users.missing]
}
]])
    assert.is_not_nil(find(result, "unresolved-ref-column"))
  end)

  it("skips inherited-column checks for TablePartial users", function()
    local result = diagnose([[
TablePartial base {
  id integer
}
Table users {
  ~base
}
Table orders {
  id integer
}
Ref: users.id > orders.id
]])
    assert.same({}, result)
  end)

  it("warns about unknown table partial includes", function()
    local result = diagnose("Table users {\n  ~missing\n}\n")
    local unknown = find(result, "unresolved-partial")
    assert.is_not_nil(unknown)
    assert.equal(2, unknown.severity)
  end)

  it("still catches explicit duplicate columns in tables with includes", function()
    local result = diagnose([[
TablePartial base {
  id integer
}
Table users {
  ~base
  id integer
  id varchar
}
]])
    assert.is_not_nil(find(result, "duplicate-column"))
  end)
end)
