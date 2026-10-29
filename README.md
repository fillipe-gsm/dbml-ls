# dbml-ls

A DBML language server written in Lua 5.4.

It is editor-agnostic and speaks the Language Server Protocol over
stdin/stdout, so Neovim, VS Code, or any other LSP client can use it
without an HTTP server or a socket.

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
- **Diagnostics** for syntax errors, duplicate definitions, unknown index
  columns, unresolved refs, unknown table group members, and unknown
  table partial includes.
- Full-text document synchronization, with defensive support for
  incremental changes.
- UTF-8 and UTF-16 position encoding negotiation.
- Snippet completion when the client supports it.
- A structured `dbml.Endpoint` / `dbml.Reference` model shared by refs,
  diagnostics, and future go-to-definition support.

The parser also understands quoted multi-word and schema-qualified types,
schema-qualified enums, index expressions, `checks` and `records` blocks,
composite references, and optional `?` relationship markers, so valid
modern DBML does not produce false syntax errors.

Not implemented yet:

- Go-to-definition and find-references
- Rename and formatting
- Workspace/multi-file indexing (single-buffer only for now)
- Syntax highlighting (belongs in a Neovim syntax or tree-sitter
  plugin, not in the language server)
- Semantic tokens

## Diagnostics

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

## Requirements

- Lua 5.4
- [Lux](https://github.com/lumen-oss/lux) only if you want to use
  `lx test` / `lx run`. Running the server directly with `lua` needs no
  dependencies.

## Running

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

## Neovim

Neovim does not know the `dbml` filetype by default, so register it and
start the server for that filetype:

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

If you use a completion plugin such as `nvim-cmp` or the built-in
`vim.lsp.completion`, it will consume the server's completion items.

## Testing

```sh
lx test
```

Lux installs `busted` as a test dependency. If you already have `busted`
on your `PATH`, you can run it directly from the project root; `.busted`
sets up the `src/` module path.

The suite covers the JSON wrapper, lexer, parser, the `Endpoint` /
`Reference` model, document/position mapping, completion, hover,
document symbols, diagnostics, RPC framing, server lifecycle, and a full
stdio integration test of `src/main.lua`.

## Layout

```
src/
  main.lua              stdio entrypoint and read loop
  dbml/
    rpc.lua             Content-Length framing and JSON-RPC
    json.lua            JSON helpers (array/object/null)
    document.lua        text store and offset/position mapping
    lexer.lua           DBML tokenizer
    parser.lua          error-tolerant DBML parser
    ref.lua             Endpoint / Reference model
    analysis.lua        parse cache and errors
    symbols.lua         symbol table and document symbols
    diagnostics.lua     syntax and semantic diagnostics
    completion.lua      completion contexts and items
    hover.lua           hover contents
    server.lua          LSP lifecycle, diagnostics, and request dispatch
    log.lua             stderr logging
  vendor/
    dkjson.lua          vendored JSON implementation (MIT)
spec/                   busted tests
```

## JSON dependency

The server vendors [dkjson](https://dkolf.de/src/dkjson-lua.fsl/) 2.5 at
`src/vendor/dkjson.lua` (MIT license). The wrapper in `src/dbml/json.lua`
adds explicit empty-array and empty-object helpers, because Lua tables
cannot otherwise distinguish `[]` from `{}`.

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
