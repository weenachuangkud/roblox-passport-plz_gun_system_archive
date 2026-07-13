local collection = game:GetService("CollectionService")
local Players = game:GetService("Players")
local gunclient = script.GunClient

local function clientAttach(tool)
	for _, child in ipairs(tool:GetChildren()) do
		if child.Name == "GunClient" then
			if child:IsA("LocalScript") then
				return
			end
			child:Destroy()
		end
	end
	gunclient:Clone().Parent = tool
end

for _, tool in ipairs(collection:GetTagged("gun")) do
	if tool:IsA("Tool") then
		clientAttach(tool)
	end
end

collection:GetInstanceAddedSignal("gun"):Connect(function(tool)
	if tool:IsA("Tool") then
		clientAttach(tool)
	end
end)

Players.PlayerAdded:Connect(function(player)
	player.CharacterAdded:Connect(function(character)
		task.wait(0.1)
		for _, tool in ipairs(player.Backpack:GetChildren()) do
			if collection:HasTag(tool, "gun") then
				clientAttach(tool)
			end
		end
	end)
end)

for _, player in ipairs(Players:GetPlayers()) do
	player.CharacterAdded:Connect(function(character)
		task.wait(0.1)
		for _, tool in ipairs(player.Backpack:GetChildren()) do
			if collection:HasTag(tool, "gun") then
				clientAttach(tool)
			end
		end
	end)
end
