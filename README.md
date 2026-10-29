# dbml-ls

A DBML language server written in Lua 5.4.

It is editor-agnostic and speaks the Language Server Protocol over
stdin/stdout, so Neovim, VS Code, or any other LSP client can use it
without an HTTP server or a socket.

## Status

Round 1 implements:

- **Completion** for top-level keywords (`Table`, `Enum`, `Ref`,
  `TableGroup`, `Project`), common SQL/DBML types, column settings,
  table/enum names, columns after `table.` / alias member access, enum
  values, and ref operators.
- **Hover** for tables, columns, types/enums, refs, indexes, table groups,
  and projects.
- **Document symbols** for tables, columns, enums, enum values, refs,
  table groups, and projects.
- Full-text document synchronization, with defensive support for
  incremental changes.
- UTF-8 and UTF-16 position encoding negotiation.
- Snippet completion when the client supports it.

Not implemented yet:

- Diagnostics
- Go-to-definition and find-references
- Rename and formatting
- Workspace/multi-file indexing (single-buffer only for now)
- Syntax highlighting (belongs in a Neovim syntax or tree-sitter
  plugin, not in the language server)
- Semantic tokens

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

The suite covers the JSON wrapper, lexer, parser, document/position
mapping, completion, hover, document symbols, RPC framing, server
lifecycle, and a full stdio integration test of `src/main.lua`.

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
    analysis.lua        parse cache and errors
    symbols.lua         symbol table and document symbols
    completion.lua      completion contexts and items
    hover.lua           hover contents
    server.lua          LSP lifecycle and request dispatch
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
  and workspace-wide completion are future work.
- DBML column types are free-form. The type list in completion is a set
  of suggestions, not a validation list.
- The parser is deliberately error-tolerant so completion keeps working
  while a statement is half-typed.
- Logs go to stderr only; stdout is reserved for the protocol.
