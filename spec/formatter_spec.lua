local support = dofile("spec/support.lua")
local lexer = require("dbml.lexer")

local function token_values(text)
  local result = {}
  local tokens = lexer.tokenize(text, { comments = true })
  for _, token in ipairs(tokens) do
    if token.type ~= "eof" then
      result[#result + 1] = token.type .. ":" .. token.value
    end
  end
  return result
end

describe("formatter", function()
  it("normalizes indentation, spacing, and top-level blank lines", function()
    local input = [[
Project workout {database_type:'SQLite'
Note:'x'}
Table users{id int[pk,unique]
name varchar(255)[not null]
indexes{(id, name)[unique]}}
Enum status{active
disabled[note:'x']}
Ref:users.id<orders.user_id
]]

    local expected = [=[Project workout {
  database_type: 'SQLite'
  Note: 'x'
}

Table users {
  id int [pk, unique]
  name varchar(255) [not null]
  indexes {
    (id, name) [unique]
  }
}

Enum status {
  active
  disabled [note: 'x']
}

Ref: users.id < orders.user_id
]=]

    assert.equal(expected, support.format(input))
  end)

  it("preserves comments and keeps trailing comments in place", function()
    local input = [=[Table users{ // trailing
id int// x
/* block */ name varchar /* y */
} // end
]=]

    local expected = [=[Table users { // trailing
  id int // x
  /* block */ name varchar /* y */
} // end
]=]

    assert.equal(expected, support.format(input))
  end)

  it("preserves strings, backticks, and color values exactly", function()
    local input = [=[Table users [headercolor:#3498DB]{id int[note:'a  b'] created timestamp[default:`now()  - 1`]}
]=]

    local expected = [=[Table users [headercolor: #3498DB] {
  id int [note: 'a  b']
  created timestamp [default: `now()  - 1`]
}
]=]

    assert.equal(expected, support.format(input))
  end)

  it("preserves index expressions as written", function()
    local input = [=[Table users{indexes{`id*2`
(id*3,id)
}}
]=]

    local expected = [=[Table users {
  indexes {
    `id*2`
    (id*3,id)
  }
}
]=]

    assert.equal(expected, support.format(input))
  end)

  it("formats checks and records blocks without altering values", function()
    local input = [=[Table users{id integer
checks{`id >= 0`[name:'chk']}
records(id){1,2}
}
records users(id)[example]{1}
]=]

    local expected = [=[Table users {
  id integer
  checks {
    `id >= 0` [name: 'chk']
  }
  records (id) {
    1, 2
  }
}

records users(id) [example] {
  1
}
]=]

    assert.equal(expected, support.format(input))
  end)

  it("normalizes optional ref markers without changing their direction", function()
    local input = [=[Ref:users.id?<orders.id
Ref:users.id<?orders.id
Ref:users.id>?orders.id
Ref:users.id?>orders.id
]=]

    local expected = [=[Ref: users.id ?< orders.id
Ref: users.id <? orders.id
Ref: users.id >? orders.id
Ref: users.id ?> orders.id
]=]

    assert.equal(expected, support.format(input))
  end)

  it("groups consecutive refs and separates other top-level statements", function()
    local input = [=[Table a{}
Table b{}
Ref:a.id<b.id
Ref:a.id>b.id
Table c{}
]=]

    local expected = [=[Table a {}

Table b {}

Ref: a.id < b.id
Ref: a.id > b.id

Table c {}
]=]

    assert.equal(expected, support.format(input))
  end)

  it("honors tab indentation options", function()
    local input = "Table users{\nid int\n}\n"
    local expected = "Table users {\n\tid int\n}\n"
    assert.equal(expected, support.format(input, { insertSpaces = false, tabSize = 2 }))
  end)

  it("is idempotent and preserves the token stream", function()
    local input = [=[// table definition
Table users{id int[pk] // primary key
name varchar
}
]=]

    local formatted = support.format(input)
    assert.is_not_nil(formatted)
    assert.same(token_values(input), token_values(formatted))
    assert.is_nil(support.format(formatted))
  end)

  it("refuses to format files with syntax errors", function()
    assert.is_nil(support.format("Table users {\n  id\n"))
    assert.is_nil(support.format("Table users {"))
  end)

  it("returns nil for an already-formatted file", function()
    local input = "Table users {\n  id int\n}\n"
    assert.is_nil(support.format(input))
  end)
end)
