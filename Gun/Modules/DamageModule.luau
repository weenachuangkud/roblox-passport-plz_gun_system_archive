local module = {}

local Players = game:GetService("Players")

local CIVILIAN_TEAMS = {
	["Civilians"] = true,
	["Approved Civilian"] = true,
}

local function notifyGangKill(killerPlayer, victimPlayer)
	if not killerPlayer or not killerPlayer.Parent then
		return
	end
	if not victimPlayer or not victimPlayer.Parent then
		return
	end
	local callback = _G.onGangKillConfirmed
	if type(callback) == "function" then
		task.spawn(callback, killerPlayer, victimPlayer)
	end
end

local function resolvePlayer(obj)
	if not obj then
		return nil
	end
	local char = obj
	for _ = 1, 3 do
		local p = Players:GetPlayerFromCharacter(char)
		if p then
			return p
		end
		char = char.Parent
		if not char then
			break
		end
	end
	return nil
end

module.CanDamage = function(targetObj, taggerObj, friendlyFire, damage)
	local humanoid = targetObj:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		humanoid = targetObj.Parent:FindFirstChildOfClass("Humanoid")
		if not humanoid then
			humanoid = targetObj.Parent.Parent:FindFirstChildOfClass("Humanoid")
		end
	end

	if not (taggerObj and humanoid) then
		return false
	end

	if friendlyFire then
		if damage then
			local killerPlayer = resolvePlayer(taggerObj)
			local victimPlayer = Players:GetPlayerFromCharacter(targetObj)
				or Players:GetPlayerFromCharacter(targetObj.Parent)
			if killerPlayer and victimPlayer and killerPlayer ~= victimPlayer and humanoid.Health - damage <= 0 then
				notifyGangKill(killerPlayer, victimPlayer)
			end
		end
		return true
	end

	local player = resolvePlayer(taggerObj)
	local p = Players:GetPlayerFromCharacter(targetObj) or Players:GetPlayerFromCharacter(targetObj.Parent)

	if p and player then
		if (player.Team and player.Team.Name == "Choosing") or (p.Team and p.Team.Name == "Choosing") then
			return false
		end

		if p == player then
			return false
		end

		local attackerTeam = player.Team and player.Team.Name or ""
		local victimTeam = p.Team and p.Team.Name or ""

		if
			attackerTeam == "Union Guards"
			and (victimTeam == "CGB" or victimTeam == "Government" or victimTeam == "Diplomats")
		then
			return false
		end

		local attackerChar = player.Character
		local victimChar = p.Character

		-- GangPVP only applies when both players are on civilian teams
		if CIVILIAN_TEAMS[attackerTeam] and CIVILIAN_TEAMS[victimTeam] then
			if attackerChar and victimChar then
				local attackerPVP = attackerChar:FindFirstChild("GangPVP")
				if attackerPVP and attackerPVP.Value then
					local victimPVP = victimChar:FindFirstChild("GangPVP")
					if not victimPVP or not victimPVP.Value then
						return false
					end
					local attackerGangEntry = _G.getPlayerGangSync and _G.getPlayerGangSync(player)
					local victimGangEntry = _G.getPlayerGangSync and _G.getPlayerGangSync(p)
					if attackerGangEntry and victimGangEntry and attackerGangEntry == victimGangEntry then
						return false
					end
					if damage and humanoid.Health - damage <= 0 then
						notifyGangKill(player, p)
					end
					return true
				end
			end
		end

		local allowed = false

		if player.Character then
			local tool = player.Character:FindFirstChildOfClass("Tool")
			if tool and (tool.Name == "TK-Tokarev" or tool.Name == "Silenced Tokarev") then
				allowed = true
			end
		end

		if not allowed then
			if attackerTeam == "Guards" then
				local character = player.Character
				if victimTeam == "Shrekism" then
					allowed = true
				end
				if not allowed and character then
					local tool = character:FindFirstChildOfClass("Tool")
					if tool and tool.Name == "Tokarev" then
						allowed = true
					end
				end
				if not allowed and victimTeam == "Raiders" then
					allowed = true
				end
				if not allowed and (victimTeam == "Civilians" or victimTeam == "Approved Civilian") then
					local antiRK = p:FindFirstChild("AntiRK")
					if antiRK and antiRK.Value == false then
						allowed = true
					end
				end
			elseif attackerTeam == "Raiders" then
				if victimTeam == "Civilians" or victimTeam == "Approved Civilian" then
					if
						p.Character
						and p.Character:FindFirstChild("Head")
						and p.Character.Head:FindFirstChild("WantedUI")
					then
						allowed = true
					end
				elseif victimTeam == "Raiders" then
					allowed = false
				else
					allowed = true
				end
			elseif attackerTeam == "Shrekism" then
				if victimTeam == "Civilians" or victimTeam == "Approved Civilian" or victimTeam == "Shrekism" then
					if
						p.Character
						and p.Character:FindFirstChild("Head")
						and p.Character.Head:FindFirstChild("WantedUI")
					then
						allowed = true
					end
				else
					allowed = true
				end
			elseif attackerTeam == "Media Men" then
				local character = player.Character
				if character then
					local tool = character:FindFirstChildOfClass("Tool")
					if tool and tool.Name == "Tokarev" then
						allowed = victimTeam == "Media Men"
					else
						allowed = attackerTeam ~= victimTeam
					end
				end
			else
				if p.Neutral or player.Neutral then
					allowed = true
				elseif p.TeamColor ~= player.TeamColor then
					allowed = true
				end
			end
		end

		if allowed and damage and (humanoid.Health - damage <= 0) then
			notifyGangKill(player, p)
		end

		return allowed
	else
		local targetTEAM = targetObj:FindFirstChild("TEAM")
		local TEAM = taggerObj:FindFirstChild("TEAM")

		if TEAM and targetTEAM then
			if
				TEAM.Value == "Union Guards"
				and (targetTEAM.Value == "CGB" or targetTEAM.Value == "Government" or targetTEAM.Value == "Diplomats")
			then
				return false
			elseif targetTEAM.Value ~= TEAM.Value then
				return true
			elseif TEAM.Value == "Guards" then
				if player and player.Character then
					local tool = player.Character:FindFirstChildOfClass("Tool")
					if not (tool and tool.Name == "Tokarev") then
						return false
					end
				end
				return targetTEAM.Value == "Civilians" or targetTEAM.Value == "Raiders"
			elseif TEAM.Value == "Media Men" then
				if player and player.Character then
					local tool = player.Character:FindFirstChildOfClass("Tool")
					if tool and tool.Name == "Tokarev" then
						return targetTEAM.Value == "Media Men"
					else
						return TEAM.Value ~= targetTEAM.Value
					end
				end
			else
				return false
			end
		else
			return true
		end
	end

	return false
end

return module
