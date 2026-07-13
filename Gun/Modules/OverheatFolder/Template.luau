local module = {}

function module:BeginOverheat(Character, Tool, Handle) end

function module:EndOverheat(Character, Tool, Handle) end

return table.isfrozen(module) and module or table.freeze(module)
