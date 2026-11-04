-- Same-file find-references.

local occurrences = require("dbml.occurrences")
local targets = require("dbml.targets")

local M = {}

---@param analysis dbml.Analysis
---@param document dbml.Document
---@param position dbml.Position
---@param include_declaration boolean
---@return dbml.Location[]
function M.references(analysis, document, position, include_declaration)
  local target = targets.at(analysis, document, position)
  if not target then
    return {}
  end

  local result = {}
  for _, occurrence in ipairs(occurrences.for_target(analysis, target)) do
    if include_declaration or not occurrence.declaration then
      result[#result + 1] = {
        uri = document.uri,
        range = {
          start = document:position_at(occurrence.range.start),
          ["end"] = document:position_at(occurrence.range.stop),
        },
      }
    end
  end
  return result
end

return M
