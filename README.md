# dbml-ls

A [Database Markup Language (DBML)](https://dbml.dbdiagram.io/home) language server written in Lua 5.4.

It is editor-agnostic and speaks the Language Server Protocol over stdin/stdout, so Neovim, VS Code, or any other LSP client can use it without an HTTP server or a socket.

> [!WARNING]
> This is still in open alpha and there is no user-friendly installation method other than cloning the repo and calling its `main.lua` file. Once it is better tested it will be published in something like LuaRocks.

## Requirements

- Lua 5.4+

## Running

After cloning the repo, from the project root, run:

```sh
lua src/main.lua
```

## Editors configuration

### Neovim

Neovim does not know the `dbml` filetype by default, so register it and start the server for that filetype:

```lua
vim.filetype.add({ extension = { dbml = "dbml" } })

vim.api.nvim_create_autocmd("FileType", {
  pattern = "dbml",
  callback = function(args)
    vim.lsp.start({
      name = "dbml-ls",
      cmd = { "lua", "/absolute/path/to/dbml-ls/src/main.lua" },
      root_dir = vim.fs.dirname(vim.api.nvim_buf_get_name(args.buf)),
    })
  end,
})
```

If you use a completion plugin such as `nvim-cmp` or the built-in `vim.lsp.completion`, it will consume the server's completion items.


## Status

Implemented:

- **Completion** for top-level keywords (`Table`, `Enum`, `Ref`,
  `TableGroup`, `Project`), common SQL/DBML types, user-defined enum
  types, column settings, table/enum names, columns after `table.` /
  alias member access, enum values, ref operators, and inline refs.
- **Hover** for tables, columns, types/enums, refs, indexes, table groups,
  and projects.
- **Document symbols** for tables, columns, enums, enum values, refs,
  table groups, and projects.
- **Go-to-definition** for tables, columns, aliases, enum types, enum
  values, ref endpoints, inline refs, composite ref columns, index
  columns, table group members, and table partial includes.
- **Rename** for tables, aliases, columns, enums, enum values, table
  partials, table groups, and projects, including refs, inline refs,
  composite refs, indexes, group members, partial includes, enum type
  usages, and enum defaults.
- **Diagnostics** for syntax errors, duplicate definitions, unknown index
  columns, unresolved refs, unknown table group members, and unknown
  table partial includes.
- Full-text document synchronization, with defensive support for
  incremental changes.
- UTF-8 and UTF-16 position encoding negotiation.
- Snippet completion when the client supports it.
- A structured `dbml.Endpoint` / `dbml.Reference` model shared by refs,
  diagnostics, hover, definition, and rename.

The parser also understands quoted multi-word and schema-qualified types,
schema-qualified enums, index expressions, `checks` and `records` blocks,
composite references, and optional `?` relationship markers, so valid
modern DBML does not produce false syntax errors.

Not implemented yet:

- Find-references
- Formatting
- Workspace/multi-file indexing (single-buffer only for now)
- Syntax highlighting (belongs in a Neovim syntax or tree-sitter
  plugin, not in the language server)
- Semantic tokens


## Notes and limitations

- **Single file only.** The server parses the buffer sent by the client;
  it does not scan the workspace for other `.dbml` files. Cross-file refs
  and workspace-wide completion are not supported, which is why
  unresolved refs are diagnostics warnings rather than errors.
- **Table partials are not merged.** `~base` includes are recorded and
  validated, but inherited columns are not added to the including table.
  Diagnostics therefore skip column-resolution checks for tables with
  partial includes.
- DBML column types are free-form. The type list in completion is a set
  of suggestions, not a validation list.
- Index expressions, `checks` contents, and `records` sample data are
  parsed/skipped but not semantically validated yet.
- The parser is deliberately error-tolerant so completion keeps working
  while a statement is half-typed.
- Logs go to stderr only; stdout is reserved for the protocol.

## Development Details

### Diagnostics

Diagnostics are pushed on `textDocument/didOpen` and `didChange`, and
cleared on `didClose`. They use `source = "dbml-ls"` with stable codes.

**Errors** (1):

- Syntax errors from the lexer/parser (unclosed blocks, missing types,
  malformed refs, unterminated strings/comments, …)
- Duplicate tables, table partials, enums, columns, enum values, aliases,
  and named refs
- Unknown columns in an `indexes` block

**Warnings** (2):

- Unresolved tables or columns in top-level and inline refs
- Unknown `TableGroup` members
- Unknown `TablePartial` includes

Warnings are intentional for unresolved refs: the server is single-file,
so the target may be defined in another file. Type names are not
validated because DBML column types are free-form.

Tables that include a `TablePartial` (`~base`) inherit columns that the
parser does not merge yet; unresolved-column checks are skipped for those
tables to avoid false positives. Explicit duplicate columns are still
reported.

### Go to definition

`textDocument/definition` resolves the symbol under the cursor within the
current buffer:

- table names, aliases, and `TablePartial` declarations
- column declarations and usages
- enum names and enum values
- column types that name an enum (including schema-qualified enums)
- top-level ref endpoints and inline `[ref: ...]` targets
- individual columns in composite refs like `a.(x, y) > b.(x, y)`
- index columns and table group members
- table partial includes (`~base`)

Definitions return the declaration's name range, so the jump highlights
the useful token rather than the whole block. Cross-file definitions are
not supported; unresolved targets return `null`, matching the single-file
scope.

Resolving an enum value used in a `default:` string (for example
`default: 'barbell'` on an `exercise_category` column) is not implemented
yet; it is a natural follow-up.

### Rename

`textDocument/prepareRename` and `textDocument/rename` are implemented
for the current buffer. Renaming a symbol updates its declaration and
the references the server knows about:

- table names, including refs, inline refs, composite refs, group
  members, and `TablePartial` includes
- table aliases and their refs/group members
- column names, including refs, inline refs, composite refs, and indexes
- enum names and schema-qualified/bare type usages
- enum values and matching `default: 'value'` strings
- table groups and projects (declaration only)

`prepareRename` refuses positions that are not actual symbol names, such
as table/column settings or a ref operator.

Names that need it are double-quoted automatically (spaces, reserved
words, special characters). Renames that would collide with an existing
symbol in the same scope are rejected. Records sample data and
expression indexes are not updated yet, and cross-file rename remains
out of scope.

In Neovim, the existing `grn` mapping (`vim.lsp.buf.rename`) already uses
this; no config change is needed.

### Requirements

- Lua 5.4
- [Lux](https://github.com/lumen-oss/lux) only if you want to use
  `lx test` / `lx run`. Running the server directly with `lua` needs no
  dependencies.

### Running

From the project root:

```sh
lua src/main.lua
```

The server reads LSP messages from stdin and writes them to stdout.
Nothing else is written to stdout. Set `DBML_LS_LOG=1` to log to stderr:

```sh
DBML_LS_LOG=1 lua src/main.lua
```

> **Do not use `lx run` as the LSP `cmd`.** Lux writes a newline to
> stdout before the process starts, which corrupts the protocol stream.
> `lx run` is fine for manual poking (the server tolerates leading blank
> lines), but clients should launch `lua src/main.lua` directly.


### Testing

```sh
lx test
```

Lux installs `busted` as a test dependency. If you already have `busted`
on your `PATH`, you can run it directly from the project root; `.busted`
sets up the `src/` module path.

The suite covers the JSON wrapper, lexer, parser, the `Endpoint` /
`Reference` model, document/position mapping, completion, hover,
go-to-definition, rename, document symbols, diagnostics, RPC framing,
server lifecycle, and a full stdio integration test of `src/main.lua`.

Source modules carry LuaCATS annotations for their public methods,
internal helpers, AST nodes, and LSP payloads. `src/dbml/types.lua` holds
the shared class definitions, so LuaLS provides parameter names, return
types, and field completion while reviewing the code.
