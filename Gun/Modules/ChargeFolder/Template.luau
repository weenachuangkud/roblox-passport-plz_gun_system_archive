local module = {}

function module:BeginCharge(Character, Tool, Handle, ChargeLevel)
	if ChargeLevel == 0 then
	elseif ChargeLevel == 1 then
	elseif ChargeLevel == 2 then
	elseif ChargeLevel == 3 then
	end
end

function module:EndCharge(Character, Tool, Handle) end

return table.isfrozen(module) and module or table.freeze(module)
