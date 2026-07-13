local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ResetSens = game.ReplicatedStorage:WaitForChild("ResetSens")

local Player = Players.LocalPlayer
local defaultSensitivity = UserInputService.MouseDeltaSensitivity
local lastData = nil
local hasData = false

local function apply(data)
	if not data then
		return
	end

	local camera = workspace.CurrentCamera
	if not camera then
		return
	end

	Player.CameraMode = Enum.CameraMode.Classic
	Player.CameraMinZoomDistance = 0
	Player.CameraMaxZoomDistance = 20

	UserInputService.MouseDeltaSensitivity = defaultSensitivity
	UserInputService.MouseIconEnabled = data.MouseIconEnabled
	camera.FieldOfView = data.FOV
end

ResetSens.Event:Connect(function(data)
	lastData = data
	hasData = true

	apply(data)
end)

Player.CharacterAdded:Connect(function()
	if not hasData then
		return
	end

	task.wait()

	apply(lastData)

	task.wait(1)
	apply(lastData)
end)
