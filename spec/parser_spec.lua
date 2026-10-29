local lexer = require("dbml.lexer")
local parser = require("dbml.parser")

local function parse(text)
  return parser.parse(lexer.tokenize(text), text)
end

local SAMPLE = [[
Project my_project {
  database_type: 'PostgreSQL'
  Note: 'demo'
}

Table public.users as U {
  id integer [pk, increment]
  email varchar(255) [unique, not null, note: 'login']
  status status_enum [default: 'active']
  indexes {
    (email) [unique, name: 'idx_email']
    (id, email)
  }
  Note: 'users table'
}

Enum status_enum {
  active
  disabled [note: 'no login']
}

TableGroup core {
  users
  orders
}

Ref: users.id < orders.user_id
Ref named_ref: orders.id - users.id
Ref {
  users.id > orders.id
  users.email > orders.email
}
]]

describe("parser", function()
  it("parses projects", function()
    local ast = parse(SAMPLE)
    assert.equal(1, #ast.projects)
    assert.equal("my_project", ast.projects[1].name)
    assert.equal("PostgreSQL", ast.projects[1].settings[1].value)
  end)

  it("parses tables, schemas, aliases, and columns", function()
    local ast = parse(SAMPLE)
    local table = ast.tables[1]
    assert.equal("public.users", table.full_name)
    assert.equal("public", table.schema)
    assert.equal("users", table.name)
    assert.equal("U", table.alias)
    assert.equal(3, #table.columns)

    local id = table.columns[1]
    assert.equal("id", id.name)
    assert.equal("integer", id.type)
    assert.equal("pk", id.settings[1].key)
    assert.equal("increment", id.settings[2].key)
    assert.equal("integer", SAMPLE:sub(id.type_range.start + 1, id.type_range.stop))

    local email = table.columns[2]
    assert.equal("varchar(255)", email.type)
    assert.equal("unique", email.settings[1].key)
    assert.equal("not null", email.settings[2].key)
    assert.equal("note", email.settings[3].key)
    assert.equal("login", email.settings[3].value)
  end)

  it("parses indexes and notes", function()
    local ast = parse(SAMPLE)
    local table = ast.tables[1]
    assert.equal(2, #table.indexes)
    assert.equal("email", table.indexes[1].columns[1].name)
    assert.equal("unique", table.indexes[1].settings[1].key)
    assert.equal("idx_email", table.indexes[1].settings[2].value)
    assert.equal("id", table.indexes[2].columns[1].name)
    assert.equal("email", table.indexes[2].columns[2].name)
    assert.equal("users table", table.note.text)
  end)

  it("parses enums", function()
    local ast = parse(SAMPLE)
    local enum = ast.enums[1]
    assert.equal("status_enum", enum.name)
    assert.equal(2, #enum.values)
    assert.equal("active", enum.values[1].name)
    assert.equal("note", enum.values[2].settings[1].key)
  end)

  it("parses table groups", function()
    local ast = parse(SAMPLE)
    local group = ast.groups[1]
    assert.equal("core", group.name)
    assert.equal("users", group.members[1].name)
    assert.equal("orders", group.members[2].name)
  end)

  it("parses refs in all three forms", function()
    local ast = parse(SAMPLE)
    assert.equal(3, #ast.refs)

    local simple = ast.refs[1].expressions[1]
    assert.equal("users", simple.from.table)
    assert.equal("id", simple.from.column)
    assert.equal("<", simple.operator)
    assert.equal("orders", simple.to.table)
    assert.equal("user_id", simple.to.column)

    assert.equal("named_ref", ast.refs[2].name)
    assert.equal(2, #ast.refs[3].expressions)
    assert.equal(">", ast.refs[3].expressions[2].operator)
  end)

  it("accepts TablePartial and partial includes", function()
    local ast = parse("TablePartial base {\n  id integer\n}\nTable users {\n  ~base\n  name varchar\n}")
    assert.is_true(ast.tables[1].partial)
    assert.equal("base", ast.tables[1].name)
    assert.equal("name", ast.tables[2].columns[1].name)
  end)

  it("combines two-word settings", function()
    local ast = parse("Table users {\n  id integer [primary key, not null]\n}")
    local settings = ast.tables[1].columns[1].settings
    assert.equal("primary key", settings[1].key)
    assert.equal("not null", settings[2].key)
  end)

  it("parses settings on tables, enums, and groups", function()
    local ast = parse([[
Table users [headercolor: #3498DB] {
  id integer
}
Enum status [headercolor: #FFFFFF] {
  active
}
TableGroup core [note: 'core tables'] {
  public.users
}
]])

    assert.equal("headercolor", ast.tables[1].settings[1].key)
    assert.equal("#3498DB", ast.tables[1].settings[1].value)
    assert.equal("headercolor", ast.enums[1].settings[1].key)
    assert.equal("note", ast.groups[1].settings[1].key)
    assert.equal("public.users", ast.groups[1].members[1].name)
  end)

  it("records inline refs as structured references", function()
    local ast = parse([[
Table users {
  id integer
}
Table orders {
  user_id integer [ref: > users.id]
}
]])
    local setting = ast.tables[2].columns[1].settings[1]

    assert.equal("ref", setting.key)
    assert.equal("> users.id", setting.value)
    assert.is_not_nil(setting.ref)
    assert.equal("inline", setting.ref.source)
    assert.equal("orders.user_id", setting.ref.from.name)
    assert.equal("users.id", setting.ref.to.name)
  end)

  it("handles a single-line partial include without swallowing the brace", function()
    local ast, errors = parse("TablePartial base { id integer }\nTable users { ~base }\n")
    assert.equal(0, #errors)
    assert.equal("base", ast.tables[2].includes[1].name)
    assert.equal(0, #ast.tables[2].columns)
  end)

  it("records table partial includes", function()
    local ast = parse([[
TablePartial base {
  id integer
}
Table users {
  ~base
  name varchar
}
]])
    assert.equal("base", ast.tables[2].includes[1].name)
    assert.equal("name", ast.tables[2].columns[1].name)
  end)

  it("supports quoted multi-word types", function()
    local ast = parse('Table users {\n  score "double precision"\n}')
    assert.equal("double precision", ast.tables[1].columns[1].type)
  end)

  it("supports schema-qualified enums", function()
    local ast = parse("Enum v2.job_status {\n  active\n}\nTable jobs {\n  status v2.job_status\n}")
    assert.equal("v2.job_status", ast.enums[1].full_name)
    assert.equal("job_status", ast.enums[1].name)
    assert.equal("v2", ast.enums[1].schema)
    assert.equal("v2.job_status", ast.tables[1].columns[1].type)
  end)

  it("parses optional relationship markers", function()
    local ast = parse([[
Table a {
  id integer
}
Table b {
  id integer
}
Ref: a.id ?> b.id
Ref: a.id >? b.id
]])
    assert.equal("?>", ast.refs[1].expressions[1].operator)
    assert.equal(">?", ast.refs[2].expressions[1].operator)
  end)

  it("parses composite references", function()
    local ast = parse([[
Table merchant_periods {
  merchant_id integer
  country_code varchar
}
Table merchants {
  id integer
  country_code varchar
}
Ref: merchant_periods.(merchant_id, country_code) > merchants.(id, country_code)
]])
    local expression = ast.refs[1].expressions[1]
    assert.equal("merchant_periods", expression.from.table)
    assert.is_nil(expression.from.column)
    assert.equal(2, #expression.from.columns)
    assert.equal("merchant_id", expression.from.columns[1].name)
    assert.equal("country_code", expression.from.columns[2].name)
    assert.equal(2, #expression.to.columns)
  end)

  it("parses all index forms", function()
    local ast, errors = parse([[
Table bookings {
  id integer
  country varchar
  booking_date date
  created_at timestamp
  indexes {
    created_at [name: 'created_at_index']
    booking_date
    (id, country) [pk]
    (`id*2`)
    (id*3, id)
    (country, booking_date) [unique]
  }
}
]])
    assert.equal(0, #errors)
    local indexes = ast.tables[1].indexes
    assert.equal(6, #indexes)
    assert.equal("created_at", indexes[1].columns[1].name)
    assert.equal("created_at_index", indexes[1].settings[1].value)
    assert.equal(1, #indexes[2].columns)
    assert.equal(2, #indexes[3].columns)
    assert.is_true(indexes[4].has_expression)
    assert.equal(0, #indexes[4].columns)
    assert.is_true(indexes[5].has_expression)
    assert.equal(2, #indexes[6].columns)
  end)

  it("parses checks and records blocks", function()
    local ast, errors = parse([[
Table users {
  id integer
  checks {
    `id > 0` [name: 'chk_positive']
  }
  records (id) {
    1
    2
  }
}
records users(id) [example] {
  1
}
]])
    assert.equal(0, #errors)
    assert.equal(1, #ast.tables)
    assert.equal(1, #ast.tables[1].columns)
  end)

  it("supports quoted identifiers", function()
    local ast = parse('Table "my table" {\n  "my col" integer\n}')
    assert.equal("my table", ast.tables[1].name)
    assert.equal("my col", ast.tables[1].columns[1].name)
  end)

  it("recovers from an unclosed table", function()
    local text = "Table users {\n  id integer"
    local ast, errors = parse(text)
    assert.equal(1, #ast.tables)
    assert.equal("users", ast.tables[1].name)
    assert.equal("id", ast.tables[1].columns[1].name)
    assert.equal(#text, ast.tables[1].body_end)
    assert.is_true(#errors > 0)
    assert.matches("unclosed table", errors[#errors].message)
  end)

  it("does not consume the next line as a missing type", function()
    local text = "Table users {\n  id\n  name varchar\n}"
    local ast, errors = parse(text)
    assert.equal(2, #ast.tables[1].columns)
    assert.equal("name", ast.tables[1].columns[2].name)
    assert.equal("varchar", ast.tables[1].columns[2].type)
    assert.is_true(#errors > 0)
  end)

  it("records ranges that point back into the source", function()
    local ast = parse(SAMPLE)
    local table = ast.tables[1]
    assert.equal("public.users", SAMPLE:sub(table.name_range.start + 1, table.name_range.stop))
    assert.equal("id", SAMPLE:sub(table.columns[1].name_range.start + 1, table.columns[1].name_range.stop))
  end)
end)
