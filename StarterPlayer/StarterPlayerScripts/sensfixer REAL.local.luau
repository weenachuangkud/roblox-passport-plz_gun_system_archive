-- Place this LocalScript in StarterPlayer > StarterPlayerScripts.
-- It survives character death, so it can reset MouseDeltaSensitivity and camera state
-- even if the gun Tool LocalScript is destroyed while scoped.

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Player = Players.LocalPlayer

-- [TEAM CHECK] Define the exact name of the excluded team
local EXCLUDED_TEAM_NAME = "Choosing"

local FALLBACK_MOUSE_DELTA_SENSITIVITY = 1 -- Roblox default. Change only if your game intentionally uses another base multiplier.
local FALLBACK_FOV = 70

local SENS_DEFAULT_ATTRIBUTE = "GunClient_DefaultMouseDeltaSensitivity"
local SENS_ADS_ACTIVE_ATTRIBUTE = "GunClient_ADSActive"

local CAMERA_MODE_ATTRIBUTE = "GunClient_DefaultCameraMode"
local CAMERA_MIN_ZOOM_ATTRIBUTE = "GunClient_DefaultCameraMinZoom"
local CAMERA_MAX_ZOOM_ATTRIBUTE = "GunClient_DefaultCameraMaxZoom"
local CAMERA_FOV_ATTRIBUTE = "GunClient_DefaultCameraFOV"
local MOUSE_BEHAVIOR_ATTRIBUTE = "GunClient_DefaultMouseBehavior"

-- [TEAM CHECK] Helper function to check if the script should be active
local function IsScriptEnabledForTeam()
	if Player.Team and Player.Team.Name == EXCLUDED_TEAM_NAME then
		return false
	end
	return true
end

local function IsValidSensitivity(value)
	return typeof(value) == "number" and value > 0 and value < 100
end

local function IsValidNumber(value)
	return typeof(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function GetEnumByName(enumType, name, fallback)
	if typeof(name) ~= "string" then
		return fallback
	end

	local ok, enumItem = pcall(function()
		return enumType[name]
	end)

	if ok and enumItem then
		return enumItem
	end

	return fallback
end

local function CaptureDefaultsIfMissing()
	-- [TEAM CHECK] Do not capture defaults if on the excluded team
	if not IsScriptEnabledForTeam() then
		return
	end

	local adsWasAlreadyActive = Player:GetAttribute(SENS_ADS_ACTIVE_ATTRIBUTE) == true

	if not IsValidSensitivity(Player:GetAttribute(SENS_DEFAULT_ATTRIBUTE)) then
		local currentSensitivity = adsWasAlreadyActive and FALLBACK_MOUSE_DELTA_SENSITIVITY
			or UserInputService.MouseDeltaSensitivity
		if not IsValidSensitivity(currentSensitivity) then
			currentSensitivity = FALLBACK_MOUSE_DELTA_SENSITIVITY
		end
		Player:SetAttribute(SENS_DEFAULT_ATTRIBUTE, currentSensitivity)
	end

	-- If this script starts while the player is already stuck scoped, do not capture
	-- the stuck scoped camera state as the default. Use normal Roblox defaults instead.
	if typeof(Player:GetAttribute(CAMERA_MODE_ATTRIBUTE)) ~= "string" then
		Player:SetAttribute(CAMERA_MODE_ATTRIBUTE, adsWasAlreadyActive and "Classic" or Player.CameraMode.Name)
	end

	if not IsValidNumber(Player:GetAttribute(CAMERA_MIN_ZOOM_ATTRIBUTE)) then
		Player:SetAttribute(CAMERA_MIN_ZOOM_ATTRIBUTE, Player.CameraMinZoomDistance)
	end

	if not IsValidNumber(Player:GetAttribute(CAMERA_MAX_ZOOM_ATTRIBUTE)) then
		Player:SetAttribute(CAMERA_MAX_ZOOM_ATTRIBUTE, Player.CameraMaxZoomDistance)
	end

	local camera = Workspace.CurrentCamera
	if camera and not IsValidNumber(Player:GetAttribute(CAMERA_FOV_ATTRIBUTE)) then
		Player:SetAttribute(CAMERA_FOV_ATTRIBUTE, adsWasAlreadyActive and FALLBACK_FOV or camera.FieldOfView)
	end

	if typeof(Player:GetAttribute(MOUSE_BEHAVIOR_ATTRIBUTE)) ~= "string" then
		Player:SetAttribute(
			MOUSE_BEHAVIOR_ATTRIBUTE,
			adsWasAlreadyActive and "Default" or UserInputService.MouseBehavior.Name
		)
	end
end

local function GetDefaultSensitivity()
	local stored = Player:GetAttribute(SENS_DEFAULT_ATTRIBUTE)
	if IsValidSensitivity(stored) then
		return stored
	end

	Player:SetAttribute(SENS_DEFAULT_ATTRIBUTE, FALLBACK_MOUSE_DELTA_SENSITIVITY)
	return FALLBACK_MOUSE_DELTA_SENSITIVITY
end

local function ResetCamera(optionalData)
	-- If your game intentionally uses locked first person as the normal default,
	-- this restores the captured default instead of always forcing Classic.
	local defaultCameraModeName = Player:GetAttribute(CAMERA_MODE_ATTRIBUTE)
	local defaultCameraMode = GetEnumByName(Enum.CameraMode, defaultCameraModeName, Enum.CameraMode.Classic)

	local cameraMode = optionalData and optionalData.CameraMode
	if typeof(cameraMode) == "string" then
		cameraMode = GetEnumByName(Enum.CameraMode, cameraMode, defaultCameraMode)
	elseif typeof(cameraMode) ~= "EnumItem" then
		cameraMode = defaultCameraMode
	end

	Player.CameraMode = cameraMode

	local minZoom = optionalData and optionalData.CameraMinZoomDistance
	if not IsValidNumber(minZoom) then
		minZoom = Player:GetAttribute(CAMERA_MIN_ZOOM_ATTRIBUTE)
	end
	if IsValidNumber(minZoom) then
		Player.CameraMinZoomDistance = minZoom
	end

	local maxZoom = optionalData and optionalData.CameraMaxZoomDistance
	if not IsValidNumber(maxZoom) then
		maxZoom = Player:GetAttribute(CAMERA_MAX_ZOOM_ATTRIBUTE)
	end
	if IsValidNumber(maxZoom) then
		Player.CameraMaxZoomDistance = maxZoom
	end

	local defaultMouseBehaviorName = Player:GetAttribute(MOUSE_BEHAVIOR_ATTRIBUTE)
	local defaultMouseBehavior = GetEnumByName(Enum.MouseBehavior, defaultMouseBehaviorName, Enum.MouseBehavior.Default)
	local mouseBehavior = optionalData and optionalData.MouseBehavior
	if typeof(mouseBehavior) == "string" then
		mouseBehavior = GetEnumByName(Enum.MouseBehavior, mouseBehavior, defaultMouseBehavior)
	elseif typeof(mouseBehavior) ~= "EnumItem" then
		mouseBehavior = defaultMouseBehavior
	end
	UserInputService.MouseBehavior = mouseBehavior
	UserInputService.MouseIconEnabled = true

	local camera = Workspace.CurrentCamera
	if camera then
		local fov = optionalData and optionalData.FOV
		if not IsValidNumber(fov) then
			fov = Player:GetAttribute(CAMERA_FOV_ATTRIBUTE)
		end
		if not IsValidNumber(fov) then
			fov = FALLBACK_FOV
		end

		camera.FieldOfView = fov
		camera.CameraType = Enum.CameraType.Custom
	end
end

local function ResetSensitivityAndCamera(optionalData)
	-- [TEAM CHECK] Abort reset if on the excluded team
	if not IsScriptEnabledForTeam() then
		return
	end

	optionalData = optionalData or {}
	CaptureDefaultsIfMissing()

	local baseSensitivity = optionalData.Sensitivity
	if not IsValidSensitivity(baseSensitivity) then
		baseSensitivity = GetDefaultSensitivity()
	end

	UserInputService.MouseDeltaSensitivity = baseSensitivity
	Player:SetAttribute(SENS_DEFAULT_ATTRIBUTE, baseSensitivity)
	Player:SetAttribute(SENS_ADS_ACTIVE_ATTRIBUTE, false)

	ResetCamera(optionalData)
end

local function ResetRepeatedly(optionalData)
	-- [TEAM CHECK] Abort execution sequence if on the excluded team
	if not IsScriptEnabledForTeam() then
		return
	end

	-- Other camera scripts can run on the same frame as death/respawn.
	-- Run the reset a few times so the final state wins without needing the gun script to survive.
	ResetSensitivityAndCamera(optionalData)
	task.defer(function()
		ResetSensitivityAndCamera(optionalData)
	end)
	task.delay(0.1, function()
		ResetSensitivityAndCamera(optionalData)
	end)
	task.delay(0.5, function()
		ResetSensitivityAndCamera(optionalData)
	end)
end

local function HookCharacter(character)
	local humanoid = character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid", 5)
	if humanoid then
		humanoid.Died:Connect(function()
			ResetRepeatedly()
		end)
	end
end

CaptureDefaultsIfMissing()

-- Reset before/after respawn. CharacterRemoving is important for dying while scoped.
Player.CharacterRemoving:Connect(function()
	ResetRepeatedly()
end)

Player.CharacterAdded:Connect(function(character)
	ResetRepeatedly()
	HookCharacter(character)
end)

if Player.Character then
	HookCharacter(Player.Character)
end

-- Support your existing ResetSens BindableEvent/RemoteEvent if other gun scripts fire it.
local resetSens = ReplicatedStorage:FindFirstChild("ResetSens")
if resetSens then
	if resetSens:IsA("BindableEvent") then
		resetSens.Event:Connect(ResetRepeatedly)
	elseif resetSens:IsA("RemoteEvent") then
		resetSens.OnClientEvent:Connect(ResetRepeatedly)
	end
end

-- If a previous version already left the player stuck scoped before this script was added,
-- this recovers on startup when the gun marked ADS active.
if Player:GetAttribute(SENS_ADS_ACTIVE_ATTRIBUTE) == true then
	ResetRepeatedly({
		Sensitivity = FALLBACK_MOUSE_DELTA_SENSITIVITY,
		CameraMode = "Classic",
		MouseBehavior = "Default",
		FOV = FALLBACK_FOV,
	})
end
