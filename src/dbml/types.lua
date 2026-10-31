-- Shared LuaCATS type definitions.
--
-- This module has no runtime behavior; it exists so LuaLS (and humans)
-- can see the shape of the AST, LSP payloads, and internal records.

---@class dbml.Range
---@field start integer 0-based byte offset, inclusive
---@field stop integer 0-based byte offset, exclusive

---@class dbml.Position
---@field line integer
---@field character integer

---@class dbml.LspRange
---@field start dbml.Position
---@field ["end"] dbml.Position

---@class dbml.Error
---@field message string
---@field start integer
---@field stop integer
---@field line integer
---@field col integer

---@class dbml.Token
---@field type string
---@field value string
---@field start integer
---@field stop integer
---@field line integer
---@field col integer

---@class dbml.Name
---@field name string
---@field range dbml.Range
---@field token dbml.Token

---@class dbml.QualifiedName
---@field parts string[]
---@field ranges dbml.Range[]
---@field name string
---@field range dbml.Range

---@class dbml.SettingsContext
---@field kind string
---@field table? dbml.Table
---@field column? dbml.Column
---@field enum? dbml.Enum
---@field value? dbml.EnumValue
---@field ref? dbml.RefStatement
---@field expression? dbml.Reference
---@field group? dbml.TableGroup

---@class dbml.Setting
---@field key string
---@field key_range dbml.Range
---@field value? string
---@field value_range? dbml.Range
---@field ref? dbml.Reference

---@class dbml.IndexColumn
---@field name string
---@field range dbml.Range

---@class dbml.IndexExpression
---@field text string
---@field range dbml.Range

---@class dbml.Index
---@field kind string
---@field columns dbml.IndexColumn[]
---@field expressions dbml.IndexExpression[]
---@field has_expression boolean
---@field settings dbml.Setting[]
---@field settings_range? dbml.Range
---@field start integer
---@field stop integer
---@field range dbml.Range

---@class dbml.Note
---@field text string
---@field range dbml.Range

---@class dbml.Column
---@field name string
---@field name_range dbml.Range
---@field type? string
---@field type_range? dbml.Range
---@field start integer
---@field stop integer
---@field range dbml.Range
---@field settings dbml.Setting[]
---@field settings_range? dbml.Range

---@class dbml.TableInclude
---@field name string
---@field range dbml.Range

---@class dbml.Table
---@field kind string
---@field partial boolean
---@field name string
---@field full_name string
---@field schema? string
---@field name_range dbml.Range
---@field alias? string
---@field alias_range? dbml.Range
---@field columns dbml.Column[]
---@field indexes dbml.Index[]
---@field includes dbml.TableInclude[]
---@field settings? dbml.Setting[]
---@field settings_range? dbml.Range
---@field indexes_range? dbml.Range
---@field indexes_body_range? dbml.Range
---@field note? dbml.Note
---@field body_start? integer
---@field body_end? integer
---@field start integer
---@field stop integer
---@field range dbml.Range

---@class dbml.EnumValue
---@field name string
---@field name_range dbml.Range
---@field start integer
---@field stop integer
---@field range dbml.Range
---@field settings dbml.Setting[]
---@field settings_range? dbml.Range

---@class dbml.Enum
---@field kind string
---@field name string
---@field full_name string
---@field schema? string
---@field name_range dbml.Range
---@field values dbml.EnumValue[]
---@field settings? dbml.Setting[]
---@field settings_range? dbml.Range
---@field note? dbml.Note
---@field body_start? integer
---@field body_end? integer
---@field start integer
---@field stop integer
---@field range dbml.Range

---@class dbml.TableGroupMember
---@field name string
---@field range dbml.Range

---@class dbml.TableGroup
---@field kind string
---@field name string
---@field name_range dbml.Range
---@field members dbml.TableGroupMember[]
---@field settings? dbml.Setting[]
---@field settings_range? dbml.Range
---@field note? dbml.Note
---@field body_start? integer
---@field body_end? integer
---@field start integer
---@field stop integer
---@field range dbml.Range

---@class dbml.Project
---@field kind string
---@field name string
---@field name_range dbml.Range
---@field settings dbml.Setting[]
---@field body_start? integer
---@field body_end? integer
---@field start integer
---@field stop integer
---@field range dbml.Range

---@class dbml.Records
---@field kind string
---@field name? string
---@field settings? dbml.Setting[]
---@field settings_range? dbml.Range
---@field range dbml.Range

---@class dbml.RefStatement
---@field kind string
---@field name? string
---@field name_range? dbml.Range
---@field expressions dbml.Reference[]
---@field start integer
---@field stop? integer
---@field range dbml.Range
---@field body_start? integer
---@field body_end? integer

---@class dbml.Ast
---@field kind string
---@field statements dbml.Statement[]
---@field tables dbml.Table[]
---@field enums dbml.Enum[]
---@field refs dbml.RefStatement[]
---@field groups dbml.TableGroup[]
---@field projects dbml.Project[]

---@alias dbml.Statement dbml.Table|dbml.Enum|dbml.RefStatement|dbml.TableGroup|dbml.Project|dbml.Records

---@class dbml.SymbolTable
---@field tables table<string, dbml.Table>
---@field table_list dbml.Table[]
---@field aliases table<string, dbml.Table>
---@field enums table<string, dbml.Enum>
---@field enum_list dbml.Enum[]
---@field columns table<string, table<string, dbml.Column>>

---@class dbml.Analysis
---@field tokens dbml.Token[]
---@field ast dbml.Ast
---@field errors dbml.Error[]
---@field symbols dbml.SymbolTable

---@class dbml.Endpoint
---@field schema? string
---@field table string
---@field column? string
---@field columns? dbml.IndexColumn[]
---@field parts string[]
---@field ranges dbml.Range[]
---@field name string
---@field range dbml.Range
---@field table_range dbml.Range
---@field column_range? dbml.Range

---@class dbml.EndpointInit
---@field schema? string
---@field table string
---@field column? string
---@field columns? dbml.IndexColumn[]
---@field parts? string[]
---@field ranges? dbml.Range[]
---@field name? string
---@field range dbml.Range
---@field table_range dbml.Range
---@field column_range? dbml.Range

---@class dbml.Reference
---@field kind string
---@field from dbml.Endpoint
---@field to dbml.Endpoint
---@field operator string
---@field source "top_level"|"inline"
---@field parent? dbml.Endpoint
---@field name? string
---@field name_range? dbml.Range
---@field range dbml.Range
---@field settings? dbml.Setting[]
---@field settings_range? dbml.Range

---@class dbml.ReferenceInit
---@field kind? string
---@field from dbml.Endpoint
---@field to dbml.Endpoint
---@field operator string
---@field source string
---@field parent? dbml.Endpoint
---@field name? string
---@field name_range? dbml.Range
---@field range dbml.Range
---@field settings? dbml.Setting[]
---@field settings_range? dbml.Range

---@class dbml.CompletionSpec
---@field label string
---@field kind? integer
---@field detail? string
---@field documentation? string
---@field snippet? string
---@field sort_text? string
---@field filter_text? string

---@class dbml.CompletionOptions
---@field snippets? boolean

---@class dbml.CompletionItem
---@field label string
---@field kind integer
---@field detail? string
---@field documentation? string
---@field sortText? string
---@field filterText? string
---@field insertText string
---@field insertTextFormat? integer
---@field textEdit table

---@class dbml.RelatedEntry
---@field range dbml.Range
---@field message? string

---@class dbml.DiagnosticEntry
---@field start integer
---@field stop integer
---@field key string
---@field diagnostic dbml.Diagnostic

---@class dbml.Diagnostic
---@field range dbml.LspRange
---@field severity integer
---@field code string
---@field source string
---@field message string
---@field relatedInformation? table[]

---@class dbml.Location
---@field uri string
---@field range dbml.LspRange

---@class dbml.Hover
---@field contents { kind: string, value: string }
---@field range dbml.LspRange

---@class dbml.DocumentSymbol
---@field name string
---@field kind integer
---@field detail? string
---@field range dbml.LspRange
---@field selectionRange dbml.LspRange
---@field children? dbml.DocumentSymbol[]

---@class dbml.TextDocumentContentChangeEvent
---@field range? dbml.LspRange
---@field text? string

---@class dbml.ServerOptions
---@field send? fun(message: table)

---@alias dbml.PositionEncoding "utf-8"|"utf-16"

return {}
