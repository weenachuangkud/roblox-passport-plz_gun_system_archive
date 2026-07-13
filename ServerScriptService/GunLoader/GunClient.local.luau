local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local GuiService = game:GetService("GuiService")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local UserGameSettings = UserSettings():GetService("UserGameSettings")

local Miscs = ReplicatedStorage:WaitForChild("Gun"):WaitForChild("Miscs")
local Modules = ReplicatedStorage:WaitForChild("Gun"):WaitForChild("Modules")
local Events = ReplicatedStorage:WaitForChild("Gun"):WaitForChild("Events")
local Remotes = ReplicatedStorage:WaitForChild("Gun"):WaitForChild("Remotes")

local Tool = script.Parent
local AnimationFolder = Tool:WaitForChild("AnimationFolder")
local ValueFolder = Tool:WaitForChild("ValueFolder")

local Camera = Workspace.CurrentCamera

local Player = Players.LocalPlayer
local Character = Player.Character
if not Character or not Character.Parent then
	Character = Player.CharacterAdded:Wait()
end
local Humanoid = Character:WaitForChild("Humanoid")
local HumanoidRootPart = Character:WaitForChild("HumanoidRootPart")
local Head = Character:WaitForChild("Head")
local Torso = Character:FindFirstChild("Torso")
local LeftArm = Character:FindFirstChild("Left Arm")
local RightArm = Character:FindFirstChild("Right Arm")

local PlayerGui = Player:WaitForChild("PlayerGui")
local Mouse = Player:GetMouse()
local GunServer = Tool:WaitForChild("GunServer")
local ChangeMagAndAmmo = GunServer:WaitForChild("ChangeMagAndAmmo")
local MarkerEvent = script:WaitForChild("MarkerEvent")
local ResetSens = game.ReplicatedStorage:WaitForChild("ResetSens")

function ReadClientCameraSensitivity()
	local ok, value = pcall(function()
		return UserGameSettings.MouseSensitivity
	end)

	if ok and typeof(value) == "number" then
		return value
	end

	return nil
end

function WriteClientCameraSensitivity(value)
	if typeof(value) ~= "number" then
		return
	end

	pcall(function()
		UserGameSettings.MouseSensitivity = math.clamp(value, 0, 4)
	end)
end

local GUI = script:WaitForChild("GunGUI")
if GUI:IsA("ScreenGui") then
	-- If the tool/script is removed while the gun is equipped, do not let a
	-- detached gun HUD survive the player's respawn in PlayerGui.
	GUI.ResetOnSpawn = true
	GUI.Enabled = false
	-- Use global ZIndex comparison so HUD descendants can render above the scope
	-- overlay even when they do not share the same direct parent.
	GUI.ZIndexBehavior = Enum.ZIndexBehavior.Global
	-- Keep this weapon HUD above other lower-priority ScreenGuis. Relative order
	-- inside this ScreenGui is still controlled by the ZIndex constants below.
	GUI.DisplayOrder = math.max(GUI.DisplayOrder, 1000)
end

local MOBILE_CONTROL_ZINDEX = 12000
local AMMO_DISPLAY_ZINDEX = 11500
local SCOPE_OVERLAY_ZINDEX = 9000
local DEFAULT_MOBILE_ADS_CAMERA_SENSITIVITY_MULTIPLIER = 0.55
local MOBILE_ADS_CAMERA_SENSITIVITY_TWEEN_TIME = 0.22
local MIN_MOBILE_ADS_CAMERA_SENSITIVITY = 0.05
local ClientCameraSensitivityTweenId = 0

function GetMobileADSCameraSensitivityMultiplier()
	local override = Tool:GetAttribute("MobileADSSensitivityMultiplier")
	if typeof(override) == "number" then
		return math.clamp(override, 0.05, 1)
	end

	return DEFAULT_MOBILE_ADS_CAMERA_SENSITIVITY_MULTIPLIER
end

function SmoothWriteClientCameraSensitivity(targetValue, duration)
	if typeof(targetValue) ~= "number" then
		return
	end

	targetValue = math.clamp(targetValue, 0, 4)
	duration = duration or 0
	ClientCameraSensitivityTweenId += 1
	local tweenId = ClientCameraSensitivityTweenId

	local startValue = ReadClientCameraSensitivity()
	if typeof(startValue) ~= "number" or duration <= 0 then
		WriteClientCameraSensitivity(targetValue)
		return
	end

	task.spawn(function()
		local startedAt = os.clock()
		while ClientCameraSensitivityTweenId == tweenId do
			local alpha = math.clamp((os.clock() - startedAt) / duration, 0, 1)
			local easedAlpha = 1 - ((1 - alpha) ^ 3)
			WriteClientCameraSensitivity(startValue + ((targetValue - startValue) * easedAlpha))

			if alpha >= 1 then
				break
			end

			task.wait()
		end

		if ClientCameraSensitivityTweenId == tweenId then
			WriteClientCameraSensitivity(targetValue)
		end
	end)
end

function SetGuiTreeZIndex(root, zIndex)
	if not root then
		return
	end

	if root:IsA("GuiObject") then
		root.ZIndex = zIndex
	end

	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("GuiObject") then
			descendant.ZIndex = zIndex
		end
	end
end

function LowerScopeOverlayZIndex()
	-- Scope blackout/circle should sit above the world, but below the weapon HUD
	-- and mobile controls. This prevents the ammo display from being covered.
	SetGuiTreeZIndex(GUI.Scope, SCOPE_OVERLAY_ZINDEX)
end

local MobileButtonHost = GUI:FindFirstChild("MobileButtonHost")
if not MobileButtonHost then
	MobileButtonHost = Instance.new("Frame")
	MobileButtonHost.Name = "MobileButtonHost"
	MobileButtonHost.BackgroundTransparency = 1
	MobileButtonHost.BorderSizePixel = 0
	MobileButtonHost.Size = UDim2.fromScale(1, 1)
	MobileButtonHost.Position = UDim2.fromScale(0, 0)
	MobileButtonHost.ZIndex = MOBILE_CONTROL_ZINDEX
	MobileButtonHost.Parent = GUI
end

local MobileButtons = {
	AimButton = GUI.MobileButtons.AimButton,
	FireButton = GUI.MobileButtons.FireButton,
	SubFireButton = GUI.SubFireButton,
	HoldDownButton = GUI.MobileButtons.HoldDownButton,
	InspectButton = GUI.MobileButtons.InspectButton,
	ReloadButton = GUI.MobileButtons.ReloadButton,
	SwitchButton = GUI.MobileButtons.SwitchButton,
	MeleeButton = GUI.MobileButtons.MeleeButton,
	AltButton = GUI.MobileButtons.AltButton,
}

function RaiseMobileControlsZIndex()
	SetGuiTreeZIndex(MobileButtonHost, MOBILE_CONTROL_ZINDEX)
	SetGuiTreeZIndex(GUI.MobileButtons, MOBILE_CONTROL_ZINDEX)

	for _, button in pairs(MobileButtons) do
		SetGuiTreeZIndex(button, MOBILE_CONTROL_ZINDEX)
	end
end

local function RaiseCounterTextZIndex(counter)
	if not counter then
		return
	end

	-- First put the whole counter above the scope overlay.
	SetGuiTreeZIndex(counter, AMMO_DISPLAY_ZINDEX)

	-- Then push bars/backgrounds behind the actual text. The old code gave the
	-- Fill and the labels the same ZIndex, so the fill could render over labels
	-- depending on hierarchy/order.
	local fill = counter:FindFirstChild("Fill")
	if fill then
		SetGuiTreeZIndex(fill, AMMO_DISPLAY_ZINDEX)
	end

	for _, name in ipairs({ "Current", "Max", "Frame", "Reloading", "NoMoreAmmo", "Overheated" }) do
		local child = counter:FindFirstChild(name)
		if child then
			SetGuiTreeZIndex(child, AMMO_DISPLAY_ZINDEX + 5)
		end
	end
end

function RaiseAmmoDisplayZIndex()
	-- Keep the ammo/weapon HUD above the scope blackout, but still below the
	-- mobile controls so touch buttons always remain clickable and visible.
	SetGuiTreeZIndex(GUI.Frame, AMMO_DISPLAY_ZINDEX)
	SetGuiTreeZIndex(GUI.MagCartridge, AMMO_DISPLAY_ZINDEX)
	SetGuiTreeZIndex(GUI.ChargeBar, AMMO_DISPLAY_ZINDEX)

	local counter = GUI.Frame and GUI.Frame:FindFirstChild("Counter")
	if counter then
		RaiseCounterTextZIndex(counter:FindFirstChild("Mag"))
		RaiseCounterTextZIndex(counter:FindFirstChild("Ammo"))
		RaiseCounterTextZIndex(counter:FindFirstChild("Heat"))
	end
end

function ApplyGunGuiLayering()
	if GUI:IsA("ScreenGui") then
		GUI.ZIndexBehavior = Enum.ZIndexBehavior.Global
		GUI.DisplayOrder = math.max(GUI.DisplayOrder, 1000)
	end

	LowerScopeOverlayZIndex()
	RaiseAmmoDisplayZIndex()
	RaiseMobileControlsZIndex()
end

ApplyGunGuiLayering()

-- Detect input platform
function IsTouch()
	return UserInputService.TouchEnabled
		and not UserInputService.KeyboardEnabled
		and not UserInputService.GamepadEnabled
end

function IsController()
	return UserInputService.GamepadEnabled and not UserInputService.KeyboardEnabled
end

function IsConsoleOrTouch()
	return IsTouch() or IsController()
end

local TouchGui
local TouchControlFrame
local JumpButton

function FindJumpButton()
	local tGui = PlayerGui:FindFirstChild("TouchGui")
	if tGui then
		local tcf = tGui:FindFirstChild("TouchControlFrame")
		if tcf then
			local jb = tcf:FindFirstChild("JumpButton")
			if jb then
				return jb
			end
		end
	end
	return nil
end

-- Keep the gun buttons inside GunGUI.
-- The previous version moved the real buttons into Roblox's TouchGui/JumpButton.
-- If the player died while equipped, the Tool/LocalScript could be destroyed while
-- those buttons were no longer descendants of GunGUI, leaving them stuck on screen.
function RefreshMobileButtonHost()
	MobileButtonHost.Parent = GUI
	MobileButtonHost.Visible = true
	ApplyGunGuiLayering()

	if IsTouch() then
		local jumpButton = FindJumpButton()
		if jumpButton then
			-- Match the old behavior as closely as possible: before the cleanup fix,
			-- buttons were parented directly into JumpButton, so their local origin was
			-- JumpButton's coordinate space. Because MobileButtonHost now lives inside
			-- GunGUI instead of TouchGui, compensate for GunGUI ignoring the topbar inset.
			-- Without this, the host sits slightly too high on mobile.
			local inset = GUI.IgnoreGuiInset and GuiService:GetGuiInset() or Vector2.new(0, 0)
			MobileButtonHost.AnchorPoint = Vector2.new(0, 0)
			MobileButtonHost.Size = UDim2.fromOffset(jumpButton.AbsoluteSize.X, jumpButton.AbsoluteSize.Y)
			MobileButtonHost.Position =
				UDim2.fromOffset(jumpButton.AbsolutePosition.X + inset.X, jumpButton.AbsolutePosition.Y + inset.Y)
			return MobileButtonHost
		end
	elseif IsController() then
		MobileButtonHost.Size = UDim2.fromScale(1, 1)
		MobileButtonHost.Position = UDim2.fromScale(0, 0)
		return MobileButtonHost
	end

	MobileButtonHost.Size = UDim2.fromScale(1, 1)
	MobileButtonHost.Position = UDim2.fromScale(0, 0)
	return nil
end

function GetButtonParent()
	if IsConsoleOrTouch() then
		return RefreshMobileButtonHost()
	end
	return nil
end

if UserInputService.TouchEnabled then
	-- wait for TouchGui which appears shortly after character loads
	TouchGui = PlayerGui:FindFirstChild("TouchGui") or PlayerGui:WaitForChild("TouchGui", 5)
	if TouchGui then
		TouchControlFrame = TouchGui:FindFirstChild("TouchControlFrame")
			or TouchGui:WaitForChild("TouchControlFrame", 5)
		if TouchControlFrame then
			JumpButton = TouchControlFrame:FindFirstChild("JumpButton")
				or TouchControlFrame:WaitForChild("JumpButton", 5)
		end
	end
end

local GunVisualEffects = Miscs.GunVisualEffects
local Scanners = Miscs.Scanners

local SmokeTrail = require(Modules.SmokeTrail)
local SettingModifier = require(Modules.SettingModifier)
local DamageModule = require(Modules.DamageModule)
local Utilities = require(Modules.Utilities)
local Thread = Utilities.Thread
local ProjectileMotion = Utilities.ProjectileMotion
local Math = Utilities.Math
local Spring = Utilities.Spring
local CloneTable = Utilities.CloneTable
local RotatedRegion3 = Utilities.RotatedRegion3
local RaycastHitbox = Utilities.RaycastHitboxV4
local CreatePacket = unpack(Utilities.DataPacket)

local gunEvent = Events.gunEvent

local InflictTarget = Remotes.InflictTarget
local ShatterGlass = Remotes.ShatterGlass
local VisualizeBeam = Remotes.VisualizeBeam
local VisibleMuzzle = Remotes.VisibleMuzzle

local GUID = HttpService:GenerateGUID()
local BindToStepName = "UpdateGun_" .. GUID

-- Optimized lightweight IDs for hot firing paths.
-- The weapon GUID above remains globally unique; these only need to be unique
-- inside this client-side gun session and are much cheaper than GenerateGUID().
local BulletCounter = 0
local AudioCounter = 0

local function NewBulletId()
	BulletCounter += 1
	return "Bullet_" .. BulletCounter
end

local function NewAudioId()
	AudioCounter += 1
	return "Audio_" .. AudioCounter
end

local TopbarOffset = (GUI.IgnoreGuiInset and GuiService:GetGuiInset()) or Vector2.new(0, 0)

-- Use one shared aim pixel for the crosshair, scope overlay, and firing ray.
-- AbsolutePosition is the top-left of a GuiObject, so using it directly makes
-- mobile/low-resolution aim drift. The center of the Center object is the actual
-- visual aim point.
local function GetGuiObjectCenter(guiObject)
	if guiObject and guiObject:IsA("GuiObject") then
		local size = guiObject.AbsoluteSize
		local position = guiObject.AbsolutePosition
		return Vector2.new(position.X + size.X * 0.5, position.Y + size.Y * 0.5)
	end

	local viewportSize = Camera.ViewportSize
	return Vector2.new(viewportSize.X * 0.5, viewportSize.Y * 0.5)
end

local function GetCrosshairAimPoint()
	return GetGuiObjectCenter(GUI.Crosshair.Center)
end

local function ScaleOffset(offset, scale)
	return math.round(offset * scale)
end

local function GetGunHudScale()
	local viewportSize = Camera.ViewportSize
	local scale = math.min(viewportSize.X / 1280, viewportSize.Y / 720)

	if IsTouch() then
		-- Mobile has much less usable screen area because the thumb controls and
		-- Roblox hotbar occupy the bottom of the screen.
		scale *= 0.85
	end

	return math.clamp(scale, 0.62, 1)
end

local function GetOrCreateUIScale(parent, name)
	if not parent then
		return nil
	end

	local uiScale = parent:FindFirstChild(name)
	if not uiScale then
		uiScale = Instance.new("UIScale")
		uiScale.Name = name
		uiScale.Parent = parent
	end

	return uiScale
end

local AmmoFrameUIScale = GetOrCreateUIScale(GUI.Frame, "GunResponsiveScale")
local MagCartridgeUIScale = GetOrCreateUIScale(GUI.MagCartridge, "GunResponsiveScale")
local ChargeBarUIScale = GetOrCreateUIScale(GUI.ChargeBar, "GunResponsiveScale")

local function ApplyResponsiveGunHudScale()
	local scale = GetGunHudScale()

	if AmmoFrameUIScale and AmmoFrameUIScale.Scale ~= scale then
		AmmoFrameUIScale.Scale = scale
	end
	if MagCartridgeUIScale and MagCartridgeUIScale.Scale ~= scale then
		MagCartridgeUIScale.Scale = scale
	end
	if ChargeBarUIScale and ChargeBarUIScale.Scale ~= scale then
		ChargeBarUIScale.Scale = scale
	end

	return scale
end

local TargetMarker = script:WaitForChild("TargetMarker")
local LockedEntity
local RNG = Random.new()
local Humanoids = CollectionService:GetTagged("Humanoids")
local HumanoidIndex = {}

for i, humanoid in ipairs(Humanoids) do
	HumanoidIndex[humanoid] = i
end

CollectionService:GetInstanceAddedSignal("Humanoids"):Connect(function(humanoid)
	if HumanoidIndex[humanoid] then
		return
	end
	table.insert(Humanoids, humanoid)
	HumanoidIndex[humanoid] = #Humanoids
end)

CollectionService:GetInstanceRemovedSignal("Humanoids"):Connect(function(humanoid)
	local index = HumanoidIndex[humanoid]
	if not index then
		return
	end

	local lastHumanoid = Humanoids[#Humanoids]
	Humanoids[index] = lastHumanoid
	Humanoids[#Humanoids] = nil
	if lastHumanoid and lastHumanoid ~= humanoid then
		HumanoidIndex[lastHumanoid] = index
	end
	HumanoidIndex[humanoid] = nil
end)

local CommonVariables = {
	Equipped = false,
	ActuallyEquipped = false,
	Enabled = true,
	Down = false,
	HoldDown = false,
	Reloading = false,
	CanCancelReload = false,
	AimDown = false,
	Scoping = false,
	Inspecting = false,
	Charging = false,
	Charged = false,
	Overheated = false,
	CanBeCooledDown = true,
	Switching = false,
	Alting = false,
	AlreadyHit = false,
	CurrentFireRate = 0,
	ShootCounts = 0,
	CurrentRate = 0,
	LastRate = 0,
	ElapsedTime = 0,
	CasingCount = 0,
	LastUpdate = nil,
	LastUpdate2 = nil,
	Radar = nil,
	Beam = nil,
	Attach0 = nil,
	Attach1 = nil,
	Misc = nil,
	LaserTrail = nil,
	Hitbox = nil,
	Hitbox2 = nil,
	BoltSegments = {},
	Animations = {},
	SettingModules = {},
	Keyframes = {},
	KeyframeConnections = {},
	Casings = {},
	HitHumanoids = {}, -- legacy array kept for compatibility; hot-path lookups use HitHumanoidSet below
	HitHumanoidSet = {},
	MeleeHitHumanoids = {}, -- legacy array kept for compatibility; hot-path lookups use MeleeHitHumanoidSet below
	MeleeHitHumanoidSet = {},
	MeleeHitHumanoidCount = 0,
	BlockedModels = {}, -- legacy array kept for compatibility; hot-path lookups use BlockedModelSet below
	BlockedModelSet = {},
	InitialSensitivity = UserInputService.MouseDeltaSensitivity,
	InitialClientCameraSensitivity = ReadClientCameraSensitivity(),
	ClientCameraSensitivityOverrideActive = false,
	Motor6DInstances = {},
	GripId = 0,
	DefaultC0 = nil,
	DefaultC1 = nil,
	Handle2 = nil,
	Grip2 = nil,
	LastRecoilTime = 0,
	RecoilCount = 0,
}
local Variables = {}

local IgnoreList = { Camera, Tool, Character }

local RegionParams = OverlapParams.new()
RegionParams.FilterType = Enum.RaycastFilterType.Exclude
RegionParams.FilterDescendantsInstances = IgnoreList
RegionParams.MaxParts = 0
RegionParams.CollisionGroup = "Default"

local RayParams = RaycastParams.new()
RayParams.FilterType = Enum.RaycastFilterType.Exclude
RayParams.FilterDescendantsInstances = IgnoreList
RayParams.IgnoreWater = true

local DEBUG_PROFILE = false
local CastRayProfileName = "CastRay_(GunClient_" .. Tool.Name .. ")"

local function CopyArray(array, extraCapacity)
	if not array then
		return {}
	end

	local length = #array
	local copy = table.create(length + (extraCapacity or 0))
	for i = 1, length do
		copy[i] = array[i]
	end
	return copy
end

local Setting = Tool:WaitForChild("Setting")
local Module = require(Setting)
local ConditionableGunMods = require(Setting:WaitForChild("ConditionableGunMods"))
local CanShootConditions = require(Setting:WaitForChild("CanShootConditions"))
local OnClientShootEvents = require(Setting:WaitForChild("OnClientShootEvents"))

if Module.DualWeldEnabled then
	CommonVariables.Handle2 = Tool:WaitForChild("Handle2", 2)
	if CommonVariables.Handle2 == nil and Module.DualWeldEnabled then
		error('"Dual" setting is enabled but "Handle2" is missing!')
	end
end

local Settings = {}
for i, v in pairs(Setting:GetChildren()) do
	if v.Name ~= "CanShootConditions" and v.Name ~= "ConditionableGunMods" and v.Name ~= "OnClientShootEvents" then
		table.insert(Settings, v)
	end
end
table.sort(Settings, function(a, b)
	return tonumber(a.Name) < tonumber(b.Name)
end)

for i, v in ipairs(Settings) do
	table.insert(CommonVariables.SettingModules, require(v))
	table.insert(Variables, {
		Mag = ValueFolder[i].Mag.Value,
		Ammo = ValueFolder[i].Ammo.Value,
		Heat = 0,
		MaxAmmo = CommonVariables.SettingModules[i].MaxAmmo,
		ElapsedCooldownTime = 0,
		ChargeLevel = 0,
		FireModes = CommonVariables.SettingModules[i].FireModes,
		FireMode = 1,
		ShotsForDepletion = 0,
		ShotID = 0,
		HandleIndex = 1,
		FireAnimIndex = 1,
		LastFireAnimIndex = 1,
		AimFireAnimIndex = 1,
		AimLastFireAnimIndex = 1,
		ShotgunPumpinAnimIndex = 1,
		ChargeLevelCap = math.clamp(CommonVariables.SettingModules[i].ChargeLevelCap, 1, 3),
	})
end

for i, v in ipairs(AnimationFolder:GetChildren()) do
	local AnimTable = {}
	if CommonVariables.SettingModules[i].EquippedAnimationID ~= nil then
		AnimTable.EquippedAnim = v:WaitForChild("EquippedAnim")
		AnimTable.EquippedAnim = Humanoid:LoadAnimation(AnimTable.EquippedAnim)
	end
	if CommonVariables.SettingModules[i].EmptyEquippedAnimationID ~= nil then
		AnimTable.EmptyEquippedAnim = v:WaitForChild("EmptyEquippedAnim")
		AnimTable.EmptyEquippedAnim = Humanoid:LoadAnimation(AnimTable.EmptyEquippedAnim)
	end
	if CommonVariables.SettingModules[i].IdleAnimationID ~= nil then
		AnimTable.IdleAnim = v:WaitForChild("IdleAnim")
		AnimTable.IdleAnim = Humanoid:LoadAnimation(AnimTable.IdleAnim)
	end
	if CommonVariables.SettingModules[i].EmptyIdleAnimationID ~= nil then
		AnimTable.EmptyIdleAnim = v:WaitForChild("EmptyIdleAnim")
		AnimTable.EmptyIdleAnim = Humanoid:LoadAnimation(AnimTable.EmptyIdleAnim)
	end
	if #CommonVariables.SettingModules[i].FireAnimations > 0 then
		local FireAnimFolder = v:WaitForChild("FireAnimations")
		AnimTable.FireAnims = {}
		for ii, vv in ipairs(CommonVariables.SettingModules[i].FireAnimations) do
			if vv.FireAnimationID ~= nil then
				local Anim = FireAnimFolder:WaitForChild("FireAnim_" .. ii)
				table.insert(AnimTable.FireAnims, { Humanoid:LoadAnimation(Anim), vv.FireAnimationSpeed })
			end
		end
	end
	if #CommonVariables.SettingModules[i].LastFireAnimations > 0 then
		local LastFireAnimFolder = v:WaitForChild("LastFireAnimations")
		AnimTable.LastFireAnims = {}
		for ii, vv in ipairs(CommonVariables.SettingModules[i].LastFireAnimations) do
			if vv.LastFireAnimationID ~= nil then
				local Anim = LastFireAnimFolder:WaitForChild("LastFireAnim_" .. ii)
				table.insert(AnimTable.LastFireAnims, { Humanoid:LoadAnimation(Anim), vv.LastFireAnimationSpeed })
			end
		end
	end
	if #CommonVariables.SettingModules[i].ShotgunPumpinAnimations > 0 then
		local ShotgunPumpinAnimFolder = v:WaitForChild("ShotgunPumpinAnimations")
		AnimTable.ShotgunPumpinAnims = {}
		for ii, vv in ipairs(CommonVariables.SettingModules[i].ShotgunPumpinAnimations) do
			if vv.ShotgunPumpinAnimationID ~= nil then
				local Anim = ShotgunPumpinAnimFolder:WaitForChild("ShotgunPumpinAnim_" .. ii)
				table.insert(
					AnimTable.ShotgunPumpinAnims,
					{ Humanoid:LoadAnimation(Anim), vv.ShotgunPumpinAnimationSpeed }
				)
			end
		end
	end
	if CommonVariables.SettingModules[i].ShotgunClipinAnimationID ~= nil then
		AnimTable.ShotgunClipinAnim = v:WaitForChild("ShotgunClipinAnim")
		AnimTable.ShotgunClipinAnim = Humanoid:LoadAnimation(AnimTable.ShotgunClipinAnim)
	end
	if CommonVariables.SettingModules[i].ReloadAnimationID ~= nil then
		AnimTable.ReloadAnim = v:WaitForChild("ReloadAnim")
		AnimTable.ReloadAnim = Humanoid:LoadAnimation(AnimTable.ReloadAnim)
	end
	if CommonVariables.SettingModules[i].HoldDownAnimationID ~= nil then
		AnimTable.HoldDownAnim = v:WaitForChild("HoldDownAnim")
		AnimTable.HoldDownAnim = Humanoid:LoadAnimation(AnimTable.HoldDownAnim)
	end
	if CommonVariables.SettingModules[i].AimIdleAnimationID ~= nil then
		AnimTable.AimIdleAnim = v:WaitForChild("AimIdleAnim")
		AnimTable.AimIdleAnim = Humanoid:LoadAnimation(AnimTable.AimIdleAnim)
	end
	if CommonVariables.SettingModules[i].EmptyAimIdleAnimationID ~= nil then
		AnimTable.EmptyAimIdleAnim = v:WaitForChild("EmptyAimIdleAnim")
		AnimTable.EmptyAimIdleAnim = Humanoid:LoadAnimation(AnimTable.EmptyAimIdleAnim)
	end
	if #CommonVariables.SettingModules[i].AimFireAnimations > 0 then
		local AimFireAnimFolder = v:WaitForChild("AimFireAnimations")
		AnimTable.AimFireAnims = {}
		for ii, vv in ipairs(CommonVariables.SettingModules[i].AimFireAnimations) do
			if vv.AimFireAnimationID ~= nil then
				local Anim = AimFireAnimFolder:WaitForChild("AimFireAnim_" .. ii)
				table.insert(AnimTable.AimFireAnims, { Humanoid:LoadAnimation(Anim), vv.AimFireAnimationSpeed })
			end
		end
	end
	if #CommonVariables.SettingModules[i].AimLastFireAnimations > 0 then
		local AimLastFireAnimFolder = v:WaitForChild("AimLastFireAnimations")
		AnimTable.AimLastFireAnims = {}
		for ii, vv in ipairs(CommonVariables.SettingModules[i].AimLastFireAnimations) do
			if vv.AimFireAnimationID ~= nil then
				local Anim = AimLastFireAnimFolder:WaitForChild("AimLastFireAnim_" .. ii)
				table.insert(AnimTable.AimLastFireAnims, { Humanoid:LoadAnimation(Anim), vv.AimLastFireAnimationSpeed })
			end
		end
	end
	if CommonVariables.SettingModules[i].AimChargingAnimationID ~= nil then
		AnimTable.AimChargingAnim = v:WaitForChild("AimChargingAnim")
		AnimTable.AimChargingAnim = Humanoid:LoadAnimation(AnimTable.AimChargingAnim)
	end
	if
		CommonVariables.SettingModules[i].TacticalReloadAnimationEnabled
		and CommonVariables.SettingModules[i].TacticalReloadAnimationID ~= nil
	then
		AnimTable.TacticalReloadAnim = v:WaitForChild("TacticalReloadAnim")
		AnimTable.TacticalReloadAnim = Humanoid:LoadAnimation(AnimTable.TacticalReloadAnim)
	end
	if
		CommonVariables.SettingModules[i].InspectAnimationEnabled
		and CommonVariables.SettingModules[i].InspectAnimationID ~= nil
	then
		AnimTable.InspectAnim = v:WaitForChild("InspectAnim")
		AnimTable.InspectAnim = Humanoid:LoadAnimation(AnimTable.InspectAnim)
	end
	if
		CommonVariables.SettingModules[i].InspectAnimationEnabled
		and CommonVariables.SettingModules[i].EmptyInspectAnimationID ~= nil
	then
		AnimTable.EmptyInspectAnim = v:WaitForChild("EmptyInspectAnim")
		AnimTable.EmptyInspectAnim = Humanoid:LoadAnimation(AnimTable.EmptyInspectAnim)
	end
	if
		CommonVariables.SettingModules[i].ShotgunReload
		and CommonVariables.SettingModules[i].PreShotgunReload
		and CommonVariables.SettingModules[i].PreShotgunReloadAnimationID ~= nil
	then
		AnimTable.PreShotgunReloadAnim = v:WaitForChild("PreShotgunReloadAnim")
		AnimTable.PreShotgunReloadAnim = Humanoid:LoadAnimation(AnimTable.PreShotgunReloadAnim)
	end
	if CommonVariables.SettingModules[i].MinigunRevUpAnimationID ~= nil then
		AnimTable.MinigunRevUpAnim = v:WaitForChild("MinigunRevUpAnim")
		AnimTable.MinigunRevUpAnim = Humanoid:LoadAnimation(AnimTable.MinigunRevUpAnim)
	end
	if CommonVariables.SettingModules[i].MinigunRevDownAnimationID ~= nil then
		AnimTable.MinigunRevDownAnim = v:WaitForChild("MinigunRevDownAnim")
		AnimTable.MinigunRevDownAnim = Humanoid:LoadAnimation(AnimTable.MinigunRevDownAnim)
	end
	if
		CommonVariables.SettingModules[i].ChargingAnimationEnabled
		and CommonVariables.SettingModules[i].ChargingAnimationID ~= nil
	then
		AnimTable.ChargingAnim = v:WaitForChild("ChargingAnim")
		AnimTable.ChargingAnim = Humanoid:LoadAnimation(AnimTable.ChargingAnim)
	end
	if
		CommonVariables.SettingModules[i].SelectiveFireEnabled
		and CommonVariables.SettingModules[i].SwitchAnimationID ~= nil
	then
		AnimTable.SwitchAnim = v:WaitForChild("SwitchAnim")
		AnimTable.SwitchAnim = Humanoid:LoadAnimation(AnimTable.SwitchAnim)
	end
	if
		CommonVariables.SettingModules[i].BatteryEnabled
		and CommonVariables.SettingModules[i].OverheatAnimationID ~= nil
	then
		AnimTable.OverheatAnim = v:WaitForChild("OverheatAnim")
		AnimTable.OverheatAnim = Humanoid:LoadAnimation(AnimTable.OverheatAnim)
	end
	if
		CommonVariables.SettingModules[i].MeleeAttackEnabled
		and CommonVariables.SettingModules[i].MeleeAttackAnimationID ~= nil
	then
		AnimTable.MeleeAttackAnim = v:WaitForChild("MeleeAttackAnim")
		AnimTable.MeleeAttackAnim = Humanoid:LoadAnimation(AnimTable.MeleeAttackAnim)
	end
	if Module.AltFire and CommonVariables.SettingModules[i].AltAnimationID ~= nil then
		AnimTable.AltAnim = v:WaitForChild("AltAnim")
		AnimTable.AltAnim = Humanoid:LoadAnimation(AnimTable.AltAnim)
	end
	if CommonVariables.SettingModules[i].LaserBeamStartupAnimationID ~= nil then
		AnimTable.LaserBeamStartupAnim = v:WaitForChild("LaserBeamStartupAnim")
		AnimTable.LaserBeamStartupAnim = Humanoid:LoadAnimation(AnimTable.LaserBeamStartupAnim)
	end
	if CommonVariables.SettingModules[i].LaserBeamLoopAnimationID ~= nil then
		AnimTable.LaserBeamLoopAnim = v:WaitForChild("LaserBeamLoopAnim")
		AnimTable.LaserBeamLoopAnim = Humanoid:LoadAnimation(AnimTable.LaserBeamLoopAnim)
	end
	if CommonVariables.SettingModules[i].LaserBeamStopAnimationID ~= nil then
		AnimTable.LaserBeamStopAnim = v:WaitForChild("LaserBeamStopAnim")
		AnimTable.LaserBeamStopAnim = Humanoid:LoadAnimation(AnimTable.LaserBeamStopAnim)
	end
	table.insert(CommonVariables.Animations, AnimTable)
end

local CurrentFireMode = 1
local CurrentModule = CommonVariables.SettingModules[CurrentFireMode]
local CurrentVariables = Variables[CurrentFireMode]
local CurrentAnimTable = CommonVariables.Animations[CurrentFireMode]
local CurrentCrosshair = GUI:WaitForChild("Crosshair")[CurrentFireMode]

local function SetADSSensitivityEnabled(enabled)
	local adsSensitivity = CurrentModule and CurrentModule.ADSMouseSensitivity or 1

	if enabled then
		UserInputService.MouseDeltaSensitivity = CommonVariables.InitialSensitivity * adsSensitivity

		-- MouseDeltaSensitivity only affects mouse delta. Mobile camera movement is
		-- controlled through the client camera sensitivity, so scale that separately
		-- while ADS is active and restore the player's original value afterwards.
		if IsTouch() then
			if not CommonVariables.ClientCameraSensitivityOverrideActive then
				CommonVariables.InitialClientCameraSensitivity = ReadClientCameraSensitivity()
				CommonVariables.ClientCameraSensitivityOverrideActive = true
			end

			if CommonVariables.InitialClientCameraSensitivity then
				local mobileADSScale = adsSensitivity * GetMobileADSCameraSensitivityMultiplier()
				local targetSensitivity = math.max(
					CommonVariables.InitialClientCameraSensitivity * mobileADSScale,
					MIN_MOBILE_ADS_CAMERA_SENSITIVITY
				)
				SmoothWriteClientCameraSensitivity(targetSensitivity, MOBILE_ADS_CAMERA_SENSITIVITY_TWEEN_TIME)
			end
		end
	else
		UserInputService.MouseDeltaSensitivity = CommonVariables.InitialSensitivity

		if CommonVariables.ClientCameraSensitivityOverrideActive then
			if CommonVariables.InitialClientCameraSensitivity then
				SmoothWriteClientCameraSensitivity(
					CommonVariables.InitialClientCameraSensitivity,
					MOBILE_ADS_CAMERA_SENSITIVITY_TWEEN_TIME
				)
			end

			CommonVariables.ClientCameraSensitivityOverrideActive = false
		end
	end
end

for i, v in pairs(GUI.Crosshair:GetChildren()) do
	if v:IsA("CanvasGroup") then
		v.Visible = (tonumber(v.Name) == CurrentFireMode)
	end
end

CommonVariables.ShootCounts = CurrentModule.ShootCounts

local UniversalTable
if Module.UniversalAmmoEnabled then
	UniversalTable = {
		Ammo = ValueFolder.Ammo.Value,
		MaxAmmo = Module.Ammo,
	}
else
	UniversalTable = CurrentVariables
end

local HandleToFire = Tool:FindFirstChild(CurrentModule.Handles[1], true)

-- Hot-path handle attachment cache. Refresh whenever the fire mode or handle changes.
local CurrentHandleModeFolder
local CurrentFirePoint
local CurrentMuzzlePoint
local CurrentSmokeTrailPoint
local CurrentModeChildren = {}

local function RefreshHandleCache()
	CurrentHandleModeFolder = nil
	CurrentFirePoint = nil
	CurrentMuzzlePoint = nil
	CurrentSmokeTrailPoint = nil
	table.clear(CurrentModeChildren)

	if not HandleToFire then
		return
	end

	local fireModeName = tostring(CurrentFireMode)
	CurrentHandleModeFolder = HandleToFire:FindFirstChild(fireModeName) or HandleToFire[CurrentFireMode]
	CurrentFirePoint = HandleToFire:FindFirstChild("GunFirePoint" .. CurrentFireMode)
	CurrentMuzzlePoint = HandleToFire:FindFirstChild("GunMuzzlePoint" .. CurrentFireMode)
	CurrentSmokeTrailPoint = HandleToFire:FindFirstChild("SmokeTrail" .. CurrentFireMode)

	if CurrentHandleModeFolder then
		for _, child in ipairs(CurrentHandleModeFolder:GetChildren()) do
			CurrentModeChildren[child.Name] = child
		end
	end
end

local function GetHandleModeFolder(handle)
	if not handle then
		return nil
	end
	return handle:FindFirstChild(tostring(CurrentFireMode)) or handle[CurrentFireMode]
end

local function GetCurrentModeChild(name)
	if not name then
		return nil
	end
	return CurrentModeChildren[name] or (CurrentHandleModeFolder and CurrentHandleModeFolder:FindFirstChild(name))
end

local function PlayCurrentModeSound(name)
	local sound = GetCurrentModeChild(name)
	if sound and sound:IsA("Sound") then
		sound:Play()
	end
	return sound
end

local function StopCurrentModeSound(name)
	local sound = GetCurrentModeChild(name)
	if sound and sound:IsA("Sound") then
		sound:Stop()
	end
	return sound
end

local function IsCurrentModeSoundPlayingLooped(name)
	local sound = GetCurrentModeChild(name)
	return sound and sound:IsA("Sound") and sound.Playing and sound.Looped
end

local function GetShootingHandleData(handle)
	if handle == HandleToFire then
		return CurrentHandleModeFolder, CurrentFirePoint, CurrentMuzzlePoint, CurrentSmokeTrailPoint
	end

	if not handle then
		return nil, nil, nil, nil
	end

	local modeFolder = GetHandleModeFolder(handle)
	return modeFolder,
	handle:FindFirstChild("GunFirePoint" .. CurrentFireMode),
	handle:FindFirstChild("GunMuzzlePoint" .. CurrentFireMode),
	handle:FindFirstChild("SmokeTrail" .. CurrentFireMode)
end

RefreshHandleCache()

local MagCartridgeIcons = {}

local function ClearMagCartridgeIcons()
	table.clear(MagCartridgeIcons)
	for _, child in ipairs(GUI.MagCartridge:GetChildren()) do
		if not child:IsA("UIGridLayout") then
			child:Destroy()
		end
	end
end

local function RebuildMagCartridgeCache()
	table.clear(MagCartridgeIcons)
	for _, child in ipairs(GUI.MagCartridge:GetChildren()) do
		local index = tonumber(child.Name)
		if index then
			MagCartridgeIcons[index] = child
		end
	end
end

local function BuildMagCartridgeIcons(visibleCount)
	ClearMagCartridgeIcons()
	if not Module.MagCartridge or CurrentModule.BatteryEnabled or CurrentModule.AmmoPerMag == math.huge then
		return
	end

	visibleCount = visibleCount or CurrentVariables.Mag
	for i = 1, CurrentModule.AmmoPerMag do
		local Bullet = GUI.MagCartridge.UIGridLayout.Template:Clone()
		Bullet.Name = tostring(i)
		Bullet.LayoutOrder = i
		Bullet.Visible = i <= visibleCount
		Bullet.Parent = GUI.MagCartridge
		MagCartridgeIcons[i] = Bullet
	end
end

local function GetMagCartridgeIcon(index)
	local icon = MagCartridgeIcons[index]
	if icon and icon.Parent then
		return icon
	end
	RebuildMagCartridgeCache()
	return MagCartridgeIcons[index]
end

local function SetMagCartridgeVisibleThrough(count)
	if not Module.MagCartridge then
		return
	end
	for i = 1, count do
		local bullet = GetMagCartridgeIcon(i)
		if bullet then
			bullet.Visible = true
		end
	end
end

local CurrentAimFireAnim = #CurrentAnimTable.AimFireAnims > 0 and CurrentAnimTable.AimFireAnims[1][1] or nil
local CurrentAimFireAnimationSpeed = #CurrentAnimTable.AimFireAnims > 0 and CurrentAnimTable.AimFireAnims[1][2] or nil
local CurrentFireAnim = #CurrentAnimTable.FireAnims > 0 and CurrentAnimTable.FireAnims[1][1] or nil
local CurrentFireAnimationSpeed = #CurrentAnimTable.FireAnims > 0 and CurrentAnimTable.FireAnims[1][2] or nil

local CurrentAimLastFireAnim = #CurrentAnimTable.AimLastFireAnims > 0 and CurrentAnimTable.AimLastFireAnims[1][1] or nil
local CurrentAimLastFireAnimationSpeed = #CurrentAnimTable.AimLastFireAnims > 0
	and CurrentAnimTable.AimLastFireAnims[1][2]
	or nil
local CurrentLastFireAnim = #CurrentAnimTable.LastFireAnims > 0 and CurrentAnimTable.LastFireAnims[1][1] or nil
local CurrentLastFireAnimationSpeed = #CurrentAnimTable.LastFireAnims > 0 and CurrentAnimTable.LastFireAnims[1][2]
	or nil

local CurrentShotgunPumpinAnim = #CurrentAnimTable.ShotgunPumpinAnims > 0 and CurrentAnimTable.ShotgunPumpinAnims[1][1]
	or nil
local CurrentShotgunPumpinAnimationSpeed = #CurrentAnimTable.ShotgunPumpinAnims > 0
	and CurrentAnimTable.ShotgunPumpinAnims[1][2]
	or nil

local BeamTable = {}
local CrosshairPointAttachment = Instance.new("Attachment")
CrosshairPointAttachment.Name = "CrosshairPointAttachment"
local LaserBeamEffect = GunVisualEffects:FindFirstChild(CurrentModule.LaserBeamEffect)
if LaserBeamEffect then
	for i, v in pairs(LaserBeamEffect.HitEffect:GetChildren()) do
		if v.ClassName == "ParticleEmitter" then
			local particle = v:Clone()
			particle.Enabled = true
			particle.Parent = CrosshairPointAttachment
		end
	end
	for i, v in pairs(LaserBeamEffect.LaserBeams:GetChildren()) do
		if v.ClassName == "Beam" then
			local beam = v:Clone()
			table.insert(BeamTable, beam)
		end
	end
end

local function FindAnimationNameForKeyframe(AnimObject)
	if CurrentModule.AnimationKeyframes[AnimObject.Name] then
		table.insert(CommonVariables.Keyframes, { AnimObject, CurrentModule.AnimationKeyframes[AnimObject.Name] })
	end
end

for _, a in pairs(CurrentAnimTable) do
	if typeof(a) == "table" then
		for _, a2 in pairs(a) do
			FindAnimationNameForKeyframe(a2[1])
		end
	else
		FindAnimationNameForKeyframe(a)
	end
end

BuildMagCartridgeIcons(CurrentVariables.Mag)

local Springs = {
	Scope = Spring.spring.new(Vector3.new(0, 200, 0)),
	Knockback = Spring.spring.new(Vector3.new()),
	CameraSpring = Spring.spring.new(Vector3.new()),
	CrossScale = Spring.spring.new(0),
	CrossSpring = Spring.spring.new(0),
}

Springs.Scope.s = CurrentModule.ScopeSwaySpeed
Springs.Scope.d = CurrentModule.ScopeSwayDamper

Springs.Knockback.s = CurrentModule.ScopeKnockbackSpeed
Springs.Knockback.d = CurrentModule.ScopeKnockbackDamper

Springs.CameraSpring.s = CurrentModule.RecoilSpeed
Springs.CameraSpring.d = CurrentModule.RecoilDamper

Springs.CrossScale.s = 10
Springs.CrossScale.d = 0.8
Springs.CrossScale.t = 1

Springs.CrossSpring.s = 12
Springs.CrossSpring.d = 0.65

local function SetCrossScale(Scale)
	Springs.CrossScale.t = Scale
end

local function SetCrossSize(Size)
	Springs.CrossSpring.t = Size
end

local function SetCrossSettings(Size, Speed, Damper)
	Springs.CrossSpring.t = Size
	Springs.CrossSpring.s = Speed
	Springs.CrossSpring.d = Damper
end

local function Random2DDirection(Velocity, X, Y)
	return Vector2.new(X, Y) * (Velocity or 1)
end

local function GetInstanceFromAncestor(Table)
	if Table[1] == "Tool" then
		return Tool:FindFirstChild(Table[2], true)
	end
	if Table[1] ~= "Character" then
		return
	end
	return Character:FindFirstChild(Table[2], true)
end

local function AddressTableValue(ValueName, Setting)
	if CurrentModule.ChargedShotAdvanceEnabled and Setting.ChargeAlterTable then
		local AlterTable = Setting.ChargeAlterTable[ValueName]
		return AlterTable
			and ((CurrentVariables.ChargeLevel == 1 and AlterTable.Level1) or (CurrentVariables.ChargeLevel == 2 and AlterTable.Level2) or (CurrentVariables.ChargeLevel == 3 and AlterTable.Level3) or Setting[ValueName])
			or Setting[ValueName]
	else
		return Setting[ValueName]
	end
end

local function CanShoot()
	if CanShootConditions[CurrentFireMode] ~= nil then
		return CanShootConditions[CurrentFireMode](
			Tool,
			Humanoid,
			CurrentVariables.Heat,
			CurrentModule.MaxHeat,
			CurrentVariables.Mag,
			CurrentModule.AmmoPerMag,
			UniversalTable.Ammo,
			UniversalTable.MaxAmmo,
			CommonVariables.ShootCounts,
			CommonVariables.CurrentFireRate
		)
	end
	return true
end

local function HasEnoughMag(ammoCost)
	return CurrentVariables.Mag >= ammoCost
end

local function CanBeginFiring(ammoCost)
	return CommonVariables.ActuallyEquipped
		and CommonVariables.Enabled
		and CommonVariables.Down
		and not CommonVariables.Overheated
		and not CommonVariables.HoldDown
		and not CommonVariables.Switching
		and not CommonVariables.Alting
		and HasEnoughMag(ammoCost)
		and CurrentVariables.Heat < CurrentModule.MaxHeat
		and Humanoid.Health > 0
		and CanShoot()
end

local function CanContinueFiring(ammoCost)
	return CommonVariables.ActuallyEquipped
		and not CommonVariables.Overheated
		and not CommonVariables.HoldDown
		and CommonVariables.Down
		and not CommonVariables.Switching
		and not CommonVariables.Alting
		and HasEnoughMag(ammoCost)
		and CurrentVariables.Heat < CurrentModule.MaxHeat
		and Humanoid.Health > 0
		and CanShoot()
end

local function WaitWhileEquipped(duration)
	local startTime = os.clock()
	while (os.clock() - startTime) < duration do
		Thread:Wait()
		if not CommonVariables.ActuallyEquipped then
			return false
		end
	end
	return true
end

local function IsGunConditionMet(conditionName, module)
	local condition = ConditionableGunMods[conditionName]
	if not condition then
		return false
	end

	return condition(
		Tool,
		Humanoid,
		CurrentVariables.Heat,
		module.MaxHeat,
		CurrentVariables.Mag,
		module.AmmoPerMag,
		UniversalTable.Ammo,
		UniversalTable.MaxAmmo,
		CommonVariables.ShootCounts,
		CommonVariables.CurrentFireRate
	)
end

local function RegisterModifierName(modNames, conditionKey, conditionName, bulletId)
	modNames = modNames or {}
	modNames[conditionKey] = modNames[conditionKey] or {}

	if bulletId then
		modNames[conditionKey][bulletId] = modNames[conditionKey][bulletId] or {}
		table.insert(modNames[conditionKey][bulletId], conditionName)
	else
		table.insert(modNames[conditionKey], conditionName)
	end

	return modNames
end

local function ApplyConditionModifiers(module, conditionKey, modNames, bulletId)
	local conditions = module and module[conditionKey]
	if not conditions or next(conditions) == nil then
		return module, modNames
	end

	local outputModule = module
	for conditionName, modifier in pairs(conditions) do
		if IsGunConditionMet(conditionName, outputModule) then
			if outputModule == module then
				outputModule = CloneTable(module)
			end
			outputModule = SettingModifier(outputModule, { modifier })
			modNames = RegisterModifierName(modNames, conditionKey, conditionName, bulletId)
		end
	end

	return outputModule, modNames
end

local function TrackOnce(set, value)
	if not value or set[value] then
		return false
	end
	set[value] = true
	return true
end

local function Untrack(set, value)
	if value then
		set[value] = nil
	end
end

local function TrackMeleeHumanoid(targetHumanoid)
	if not targetHumanoid or CommonVariables.MeleeHitHumanoidSet[targetHumanoid] then
		return false
	end
	if CommonVariables.MeleeHitHumanoidCount >= CurrentModule.MaxHits then
		return false
	end
	CommonVariables.MeleeHitHumanoidSet[targetHumanoid] = true
	CommonVariables.MeleeHitHumanoidCount += 1
	return true
end

local function UntrackMeleeHumanoid(targetHumanoid)
	if targetHumanoid and CommonVariables.MeleeHitHumanoidSet[targetHumanoid] then
		CommonVariables.MeleeHitHumanoidSet[targetHumanoid] = nil
		CommonVariables.MeleeHitHumanoidCount = math.max(CommonVariables.MeleeHitHumanoidCount - 1, 0)
	end
end

local function ClearMeleeTracking()
	table.clear(CommonVariables.MeleeHitHumanoids)
	table.clear(CommonVariables.MeleeHitHumanoidSet)
	CommonVariables.MeleeHitHumanoidCount = 0
end

local TargetRootCache = setmetatable({}, { __mode = "k" })

local function GetTargetRoot(model)
	if not model then
		return nil
	end

	local cached = TargetRootCache[model]
	if cached and cached.Parent then
		return cached
	end

	local root = model:FindFirstChild("HumanoidRootPart")
		or model:FindFirstChild("Torso")
		or model:FindFirstChild("UpperTorso")
		or model:FindFirstChild("Head")
	TargetRootCache[model] = root
	return root
end

local function PopulateHumanoids(humanoids)
	for _, v in ipairs(Humanoids) do
		if
			v.Parent
			and v.Parent ~= Character
			and DamageModule.CanDamage(v.Parent, Character, CurrentModule.FriendlyFire)
		then
			table.insert(humanoids, v)
		end
	end
end

local function CastRay(Type, StartPos, Direction, Length, Blacklist, IgnoreWater, RealTargetHumanoid)
	if DEBUG_PROFILE then
		debug.profilebegin(CastRayProfileName)
	end
	local Blacklist = CopyArray(Blacklist, 20)
	local ShouldIgnoreHumanoid = CurrentModule.IgnoreHumanoids
	if Type ~= "Beam" then
		ShouldIgnoreHumanoid = false
	end
	local Iterations = 0
	local NewRay = Ray.new(StartPos, Direction * Length)
	local HitPart, HitPoint, HitNormal, HitMaterial =
		nil, StartPos + (Direction * Length), Vector3.new(0, 1, 0), Enum.Material.Air
	while Iterations < 20 do
		Iterations = Iterations + 1
		HitPart, HitPoint, HitNormal, HitMaterial =
			Workspace:FindPartOnRayWithIgnoreList(NewRay, Blacklist, false, IgnoreWater)
		if HitPart then
			local Target = HitPart:FindFirstAncestorOfClass("Model")
			local TargetHumanoid = Target and Target:FindFirstChildOfClass("Humanoid")
			local TargetTool = HitPart:FindFirstAncestorOfClass("Tool")
			if RealTargetHumanoid and TargetHumanoid then
				ShouldIgnoreHumanoid = (RealTargetHumanoid ~= TargetHumanoid)
			end
			if
				HitPart.Transparency > 0.75
				or HitPart.Name == "Handle"
				or (TargetHumanoid and (TargetHumanoid.Health <= 0 or not DamageModule.CanDamage(
					Target,
					Character,
					CurrentModule.FriendlyFire
					) or ShouldIgnoreHumanoid))
					or TargetTool
			then
				table.insert(Blacklist, HitPart)
			else
				break
			end
		else
			break
		end
	end
	if DEBUG_PROFILE then
		debug.profileend()
	end
	return HitPart, HitPoint, HitNormal, HitMaterial
end

local function Get3DPosition(Type, CurrentPosOnScreen)
	local screenPoint = CurrentPosOnScreen or GetCrosshairAimPoint()
	local InputRay = Camera:ScreenPointToRay(screenPoint.X, screenPoint.Y, 1000)
	local EndPos = InputRay.Origin + InputRay.Direction
	local HitPart, HitPoint, HitNormal, HitMaterial =
		CastRay(Type, Camera.CFrame.p, (EndPos - Camera.CFrame.p).Unit, 1000, IgnoreList, true)
	return HitPoint
end

local function Get3DPosition2()
	local Type = CurrentModule.LaserBeam and "Beam" or "Tip"
	if Module.DirectShootingAt == "None" then
		return Get3DPosition(Type, GetCrosshairAimPoint())
	else
		local FirePointObject = CurrentFirePoint
		if FirePointObject ~= nil then
			local Direction = (
				(FirePointObject.WorldCFrame * CFrame.new(0, 0, -5000)).p - FirePointObject.WorldPosition
			).Unit
			local HitPart, HitPoint, HitNormal, HitMaterial =
				CastRay("Direct", FirePointObject.WorldPosition, Direction, 5000, IgnoreList, true)
			if Module.DirectShootingAt == "Both" then
				return HitPoint
			else
				if Module.DirectShootingAt == "FirstPerson" then
					if (Camera.Focus.Position - Camera.CFrame.Position).Magnitude <= 2 then
						return HitPoint
					else
						return Get3DPosition(Type, GetCrosshairAimPoint())
					end
				elseif Module.DirectShootingAt == "ThirdPerson" then
					if (Camera.Focus.Position - Camera.CFrame.Position).Magnitude > 2 then
						return HitPoint
					else
						return Get3DPosition(Type, GetCrosshairAimPoint())
					end
				end
			end
		else
			return Get3DPosition(Type, GetCrosshairAimPoint())
		end
	end
end

local function CheckPartInScanner(part)
	if part and CommonVariables.Radar then
		local PartPos, OnScreen = Camera:WorldToScreenPoint(part.Position)
		if OnScreen then
			local FrameSize = CommonVariables.Radar.AbsoluteSize
			local FramePos = CommonVariables.Radar.AbsolutePosition
			return PartPos.X > FramePos.X
				and PartPos.Y > FramePos.Y
				and PartPos.X < FramePos.X + FrameSize.X
				and PartPos.Y < FramePos.Y + FrameSize.Y
		end
	end
	return false
end

local function CheckForLockedTarget(Target, LockedOnTargets)
	local Found = false
	for _, v in pairs(LockedOnTargets) do
		if v and v.TargetEntity == Target then
			Found = true
			break
		end
	end
	return Found
end

local function FindNearestEntity(LockedOnTargets)
	local humanoids = {}
	PopulateHumanoids(humanoids)

	local headPos = Head.Position
	local mousePos = Get3DPosition2() or (headPos + Head.CFrame.LookVector * CurrentModule.LockOnDistance)
	local toMouse = mousePos - headPos
	local mouseDirection = toMouse.Magnitude > 0 and toMouse.Unit or Head.CFrame.LookVector

	local RealDist = CurrentModule.LockOnDistance
	local MinOffset = nil
	local TargetModel = nil
	local TargetHumanoid = nil
	local TargetTorso = nil
	local AlreadyLocked = false
	local LocketTargetCount = 0
	local SubHumanoids = {}

	if LockedOnTargets then
		for _, v in ipairs(humanoids) do
			local parent = v.Parent
			local torso = GetTargetRoot(parent)
			local Dist = torso and (headPos - torso.Position).Magnitude or math.huge
			if
				v
				and torso
				and v.Health > 0
				and CheckPartInScanner(torso)
				and Dist < (RealDist + (torso.Size.Magnitude / 2.5))
			then
				if CheckForLockedTarget(parent, LockedOnTargets) then
					LocketTargetCount += 1
				end
				table.insert(SubHumanoids, v)
			end
		end
	end

	for _, v in ipairs(LockedOnTargets ~= nil and SubHumanoids or humanoids) do
		local parent = v.Parent
		local torso = GetTargetRoot(parent)
		if v and torso then
			local torsoPos = torso.Position
			local Dist = (headPos - torsoPos).Magnitude
			local Offset = (((mouseDirection * Dist) + headPos) - torsoPos).Magnitude
			local CanFind = Dist < (RealDist + (torso.Size.Magnitude / 2.5))
				and Offset < CurrentModule.LockOnRadius
				and (not MinOffset or Offset < MinOffset)
				and v.Health > 0

			if LockedOnTargets then
				CanFind = false
				local ShouldIgnore = false
				if CurrentModule.IgnoreLockedTargets and LocketTargetCount < #SubHumanoids then
					ShouldIgnore = CheckForLockedTarget(parent, LockedOnTargets)
				end
				if
					CurrentModule.ContinueTrackingTargets
					and LocketTargetCount >= #SubHumanoids
					and #SubHumanoids < CurrentModule.MaximumTargets
				then
					ShouldIgnore = false
				end
				if v.Health > 0 and not ShouldIgnore and CheckPartInScanner(torso) then
					CanFind = Dist < (RealDist + (torso.Size.Magnitude / 2.5))
				end
			end

			local hit = not CurrentModule.LockOnThroughWall
				and CastRay("LockOn", headPos, (torsoPos - headPos).Unit, 999, IgnoreList, true, v)
				or nil
			local CanLock = true
			if not CurrentModule.LockOnThroughWall then
				CanLock = hit and hit:IsDescendantOf(parent)
			end
			if CanFind and CanLock and DamageModule.CanDamage(parent, Character, CurrentModule.FriendlyFire) then
				TargetModel = parent
				TargetHumanoid = v
				TargetTorso = torso
				AlreadyLocked = CheckForLockedTarget(parent, LockedOnTargets)
				RealDist = Dist
				MinOffset = Offset
			end
		end
	end
	table.clear(SubHumanoids)
	return TargetModel, TargetHumanoid, TargetTorso, AlreadyLocked
end

function SetCustomGrip(Enabled)
	if Enabled then
		CommonVariables.GripId += 1
		local LastGripId = CommonVariables.GripId
		for i, v in pairs(Module.CustomGrips) do
			if LastGripId ~= CommonVariables.GripId then
				break
			end
			local Part0 = GetInstanceFromAncestor(v.CustomGripPart0)
			local Part1 = GetInstanceFromAncestor(v.CustomGripPart1)
			if not Part0 or not Part1 then
				continue
			end
			local Motor6DInstance = Instance.new("Motor6D")
			Motor6DInstance.Name = v.CustomGripName
			Motor6DInstance.Part0 = Part0
			Motor6DInstance.Part1 = Part1
			Motor6DInstance:SetAttribute("Id", i)
			if Part1.Name == "Handle" and Part1.Parent == Tool then
				if not CommonVariables.DefaultC0 or not CommonVariables.DefaultC1 then
					repeat
						task.wait()
						if LastGripId ~= CommonVariables.GripId then
							break
						end
					until RightArm:FindFirstChild("RightGrip")
					if LastGripId == CommonVariables.GripId then
						local RightGrip = RightArm:FindFirstChild("RightGrip")
						if RightGrip then
							CommonVariables.DefaultC0 = RightGrip.C0
							CommonVariables.DefaultC1 = RightGrip.C1
							RightGrip.Enabled = false
							RightGrip:Destroy()
						end
					end
				end
				if CommonVariables.DefaultC0 and CommonVariables.DefaultC1 then
					if v.AlignC0AndC1FromDefaultGrip then
						Motor6DInstance.C0 = CommonVariables.DefaultC0
						Motor6DInstance.C1 = CommonVariables.DefaultC1
					end
					if v.CustomGripCFrame then
						Motor6DInstance.C0 *= v.CustomGripC0
						Motor6DInstance.C1 *= v.CustomGripC1
					end
					Motor6DInstance.Parent = Part0
					table.insert(CommonVariables.Motor6DInstances, Motor6DInstance)
				end
			else
				if v.AlignC0AndC1FromDefaultGrip and CommonVariables.DefaultC0 and CommonVariables.DefaultC1 then
					Motor6DInstance.C0 = CommonVariables.DefaultC0
					Motor6DInstance.C1 = CommonVariables.DefaultC1
				end
				if v.CustomGripCFrame then
					Motor6DInstance.C0 *= v.CustomGripC0
					Motor6DInstance.C1 *= v.CustomGripC1
				end
				Motor6DInstance.Parent = Part0
				table.insert(CommonVariables.Motor6DInstances, Motor6DInstance)
			end
		end
	else
		CommonVariables.GripId += 1
		for _, v in pairs(CommonVariables.Motor6DInstances) do
			if v then
				v:Destroy()
			end
		end
		table.clear(CommonVariables.Motor6DInstances)
		CommonVariables.DefaultC0 = nil
		CommonVariables.DefaultC1 = nil
	end
end

local function SetTextIfChanged(label, value)
	local text = tostring(value)
	if label.Text ~= text then
		label.Text = text
	end
end

local function SetVisibleIfChanged(guiObject, visible)
	if guiObject.Visible ~= visible then
		guiObject.Visible = visible
	end
end

local function SetSizeIfChanged(guiObject, size)
	if guiObject.Size ~= size then
		guiObject.Size = size
	end
end

local function SetPositionIfChanged(guiObject, position)
	if guiObject.Position ~= position then
		guiObject.Position = position
	end
end

local function TweenSizeIfChanged(guiObject, size, easingDirection, easingStyle, duration, override)
	if guiObject.Size ~= size then
		guiObject:TweenSize(size, easingDirection, easingStyle, duration, override)
	end
end

local function SafeRatio(value, maxValue)
	if not maxValue or maxValue == math.huge or maxValue <= 0 then
		return 1
	end
	return math.clamp(value / maxValue, 0, 1)
end

function UpdateGUI()
	local Counter = GUI.Frame.Counter
	local MagCounter = Counter.Mag
	local AmmoCounter = Counter.Ammo
	local HeatCounter = Counter.Heat
	local FireMode = GUI.Frame.FireMode
	local ChargeBar = GUI.ChargeBar

	if CurrentModule.AmmoPerMag ~= math.huge and CurrentModule.MaxHeat ~= math.huge then
		SetVisibleIfChanged(Counter, true)
	end

	TweenSizeIfChanged(
		MagCounter.Fill,
		UDim2.new(SafeRatio(CurrentVariables.Mag, CurrentModule.AmmoPerMag), 0, 1, 0),
		Enum.EasingDirection.Out,
		Enum.EasingStyle.Quint,
		0.25,
		true
	)
	TweenSizeIfChanged(
		AmmoCounter.Fill,
		UDim2.new(SafeRatio(UniversalTable.Ammo, UniversalTable.MaxAmmo), 0, 1, 0),
		Enum.EasingDirection.Out,
		Enum.EasingStyle.Quint,
		0.25,
		true
	)
	TweenSizeIfChanged(
		HeatCounter.Fill,
		UDim2.new(SafeRatio(CurrentVariables.Heat, CurrentModule.MaxHeat), 0, 1, 0),
		Enum.EasingDirection.Out,
		Enum.EasingStyle.Quint,
		0.25,
		true
	)

	SetTextIfChanged(MagCounter.Current, CurrentVariables.Mag)
	SetTextIfChanged(MagCounter.Max, CurrentModule.AmmoPerMag)
	SetTextIfChanged(AmmoCounter.Current, UniversalTable.Ammo)
	SetTextIfChanged(AmmoCounter.Max, UniversalTable.MaxAmmo)
	SetTextIfChanged(HeatCounter.Current, CurrentVariables.Heat)
	SetTextIfChanged(HeatCounter.Max, CurrentModule.MaxHeat)

	local altVisible = Module.AltFire and CurrentModule.AltName ~= ""
	SetVisibleIfChanged(FireMode.Alternative, altVisible)
	SetTextIfChanged(FireMode.Alternative, CurrentModule.AltName)

	local selectiveText = CurrentModule.FireModeTexts[CurrentVariables.FireMode] or ""
	SetVisibleIfChanged(FireMode.Selective, CurrentModule.SelectiveFireEnabled and selectiveText ~= "")
	SetTextIfChanged(FireMode.Selective, selectiveText)

	local notReloading = not CommonVariables.Reloading
	SetVisibleIfChanged(MagCounter.Current, notReloading)
	SetVisibleIfChanged(MagCounter.Max, notReloading)
	SetVisibleIfChanged(MagCounter.Frame, notReloading)
	SetVisibleIfChanged(MagCounter.Reloading, CommonVariables.Reloading)

	local hasAmmo = UniversalTable.Ammo > 0
	SetVisibleIfChanged(AmmoCounter.Current, hasAmmo)
	SetVisibleIfChanged(AmmoCounter.Max, hasAmmo)
	SetVisibleIfChanged(AmmoCounter.Frame, hasAmmo)
	SetVisibleIfChanged(AmmoCounter.NoMoreAmmo, not hasAmmo)

	SetVisibleIfChanged(HeatCounter, CurrentModule.BatteryEnabled)
	SetVisibleIfChanged(HeatCounter.Current, not CommonVariables.Overheated)
	SetVisibleIfChanged(HeatCounter.Max, not CommonVariables.Overheated)
	SetVisibleIfChanged(HeatCounter.Frame, not CommonVariables.Overheated)
	SetVisibleIfChanged(HeatCounter.Overheated, CommonVariables.Overheated)

	local showChargeBar = CurrentModule.ChargedShotAdvanceEnabled
		or (CurrentModule.HoldAndReleaseEnabled and not CurrentModule.LockOnScan)
	SetVisibleIfChanged(ChargeBar, showChargeBar)
	SetVisibleIfChanged(
		ChargeBar.Level1,
		not CurrentModule.HoldAndReleaseEnabled and CurrentVariables.ChargeLevelCap > 1
	)
	SetVisibleIfChanged(
		ChargeBar.Level2,
		not CurrentModule.HoldAndReleaseEnabled and CurrentVariables.ChargeLevelCap > 2
	)

	local ChargeTime = CurrentModule.AdvancedChargingTime
	if CurrentVariables.ChargeLevelCap == 1 then
		ChargeTime = CurrentModule.Level1ChargingTime
	elseif CurrentVariables.ChargeLevelCap == 2 then
		ChargeTime = CurrentModule.Level2ChargingTime
	end

	local hudScale = ApplyResponsiveGunHudScale()
	local hudRightOffset = ScaleOffset(-260, hudScale)

	SetPositionIfChanged(ChargeBar.Level1, UDim2.new(CurrentModule.Level1ChargingTime / ChargeTime, 0, 0.5, 0))
	SetPositionIfChanged(ChargeBar.Level2, UDim2.new(CurrentModule.Level2ChargingTime / ChargeTime, 0, 0.5, 0))
	SetPositionIfChanged(
		ChargeBar,
		Module.MagCartridge and UDim2.new(1, hudRightOffset, 1, ScaleOffset(-70, hudScale))
			or UDim2.new(1, hudRightOffset, 1, ScaleOffset(-35, hudScale))
	)

	SetVisibleIfChanged(GUI.MagCartridge, Module.MagCartridge)

	SetVisibleIfChanged(MagCounter, not CurrentModule.BatteryEnabled)
	SetVisibleIfChanged(AmmoCounter, Module.UniversalAmmoEnabled or CurrentModule.LimitedAmmoEnabled)
	SetVisibleIfChanged(HeatCounter, CurrentModule.BatteryEnabled)
	SetSizeIfChanged(
		Counter,
		(Module.UniversalAmmoEnabled or CurrentModule.LimitedAmmoEnabled) and UDim2.new(1, 0, 0, 100)
			or UDim2.new(1, 0, 0, 55)
	)
	SetPositionIfChanged(
		GUI.Frame,
		showChargeBar
			and (
				Module.MagCartridge and UDim2.new(1, hudRightOffset, 1, ScaleOffset(-190, hudScale))
				or UDim2.new(1, hudRightOffset, 1, ScaleOffset(-150, hudScale))
			)
			or (
				Module.MagCartridge and UDim2.new(1, hudRightOffset, 1, ScaleOffset(-150, hudScale))
				or UDim2.new(1, hudRightOffset, 1, ScaleOffset(-110, hudScale))
			)
	)

	local showButtons = IsConsoleOrTouch()
	if showButtons then
		RefreshMobileButtonHost()
	end
	-- Show the melee button based on the weapon setting only.
	-- The animation may be nil/not loaded yet for some melee weapons, but the
	-- actual attack function already checks the animation before playing.
	local hasMeleeAttack = CurrentModule.MeleeAttackEnabled == true
	ApplyGunGuiLayering()

	-- Every individual button is hidden/shown directly because some buttons may be
	-- moved into the MobileButtonHost for touch/controller layout.
	-- SubFireButton is the old tiny extra fire button, so keep it hidden permanently.
	SetVisibleIfChanged(GUI.MobileButtons, showButtons)
	SetVisibleIfChanged(MobileButtons.FireButton, showButtons)
	SetVisibleIfChanged(MobileButtons.SubFireButton, false)
	SetVisibleIfChanged(MobileButtons.AimButton, showButtons and CurrentModule.ADSEnabled)
	SetVisibleIfChanged(MobileButtons.HoldDownButton, showButtons and CurrentModule.HoldDownEnabled)
	SetVisibleIfChanged(MobileButtons.InspectButton, showButtons and CurrentModule.InspectAnimationEnabled)
	SetVisibleIfChanged(MobileButtons.SwitchButton, showButtons and CurrentModule.SelectiveFireEnabled)
	SetVisibleIfChanged(MobileButtons.ReloadButton, showButtons and not CurrentModule.BatteryEnabled)
	SetVisibleIfChanged(MobileButtons.MeleeButton, showButtons and hasMeleeAttack)
	SetVisibleIfChanged(MobileButtons.AltButton, showButtons and Module.AltFire)
end

local GuiUpdateQueued = false

function RequestGUIUpdate()
	if GuiUpdateQueued then
		return
	end

	GuiUpdateQueued = true
	task.defer(function()
		GuiUpdateQueued = false
		if CommonVariables.Equipped then
			UpdateGUI()
		end
	end)
end

local function SetAllMobileButtonsVisible(visible)
	SetVisibleIfChanged(GUI.MobileButtons, visible)
	for _, button in pairs(MobileButtons) do
		SetVisibleIfChanged(button, visible)
	end
end

-- Restore all mobile/console buttons to their original parent (GUI.MobileButtons / GUI).
-- This also recovers buttons from the old TouchGui/JumpButton parenting path.
local function RestoreMobileButtons()
	local function returnButton(buttonName, button)
		if buttonName == "SubFireButton" then
			button.Parent = GUI
		else
			button.Parent = GUI.MobileButtons
		end
	end

	local jb = FindJumpButton()
	if jb then
		for _, child in ipairs(jb:GetChildren()) do
			for name, btn in pairs(MobileButtons) do
				if child == btn then
					returnButton(name, btn)
				end
			end
		end
	end

	for _, child in ipairs(MobileButtonHost:GetChildren()) do
		for name, btn in pairs(MobileButtons) do
			if child == btn then
				returnButton(name, btn)
			end
		end
	end

	for name, button in pairs(MobileButtons) do
		returnButton(name, button)
	end
end

local function HardHideMobileControls()
	if GUI:IsA("ScreenGui") then
		GUI.Enabled = false
	end
	SetAllMobileButtonsVisible(false)
	RestoreMobileButtons()
	SetAllMobileButtonsVisible(false)
end

local function UpdateCrosshair()
	if UserInputService.MouseEnabled and UserInputService.KeyboardEnabled then
		local offset = GUI.IgnoreGuiInset and GuiService:GetGuiInset().Y or 0
		GUI.Crosshair.Position = UDim2.new(0, Mouse.X, 0, Mouse.Y + offset)
	elseif IsController() then
		GUI.Crosshair.Position = UDim2.new(0.5, 0, 0.5, 0)
	elseif IsTouch() then
		--if (Camera.Focus.Position - Camera.CFrame.Position).Magnitude > 2 then
		--	GUI.Crosshair.Position = UDim2.new(0.5, 0, 0.5, 0)
		--else
		GUI.Crosshair.Position = UDim2.new(0.5, 0, 0.5, 0)
		--end
	end
end

function Render(dt)
	Springs.Knockback.t = Springs.Knockback.t:Lerp(Vector3.new(), 0.2)

	local isMouseKeyboard = UserInputService.MouseEnabled and UserInputService.KeyboardEnabled
	local isTouch = IsTouch()
	local isController = IsController()
	local cameraCFrame = Camera.CFrame
	local cameraFocus = Camera.Focus
	local isFirstPerson = (cameraFocus.Position - cameraCFrame.Position).Magnitude <= 2

	-- Update the crosshair before the scope reads its AbsolutePosition. The old
	-- order made the scope use the previous frame's/mobile stale position.
	if Module.DirectShootingAt == "None" then
		UpdateCrosshair()
	else
		local FirePointObject = CurrentFirePoint
		if FirePointObject then
			local Position = Camera:WorldToScreenPoint((FirePointObject.WorldCFrame * CFrame.new(0, 0, -5000)).Position)

			if Module.DirectShootingAt == "Both" then
				GUI.Crosshair.Position = UDim2.fromOffset(Position.X, Position.Y)
			elseif Module.DirectShootingAt == "FirstPerson" then
				if isFirstPerson then
					GUI.Crosshair.Position = UDim2.fromOffset(Position.X, Position.Y)
				else
					UpdateCrosshair()
				end
			elseif Module.DirectShootingAt == "ThirdPerson" then
				if not isFirstPerson then
					GUI.Crosshair.Position = UDim2.fromOffset(Position.X, Position.Y)
				else
					UpdateCrosshair()
				end
			end
		else
			UpdateCrosshair()
		end
	end

	local Delta = UserInputService:GetMouseDelta() / CurrentModule.ScopeSensitivity
	local Offset = GUI.Scope.AbsoluteSize.X * 0.5
	local guiInset = GuiService:GetGuiInset()

	if CommonVariables.Scoping and isMouseKeyboard then
		GUI.Scope.Position = UDim2.new(
			0,
			Springs.Scope.p.X + (Springs.Knockback.p.Y * 1000),
			0,
			Springs.Scope.p.Y + (Springs.Knockback.p.X * 200) + guiInset.Y
		)
		Springs.Scope.t = Vector3.new(Mouse.X - Offset - Delta.X, Mouse.Y - Offset - Delta.Y, 0)
	elseif CommonVariables.Scoping and (isTouch or isController) then
		local aimPoint = GetCrosshairAimPoint()
		GUI.Scope.Position = UDim2.new(
			0,
			Springs.Scope.p.X + (Springs.Knockback.p.Y * 1000),
			0,
			Springs.Scope.p.Y + (Springs.Knockback.p.X * 200)
		)
		Springs.Scope.t = Vector3.new(
			aimPoint.X - Offset - Delta.X,
			aimPoint.Y - Offset - Delta.Y,
			0
		)
	end

	GUI.Scope.Visible = CommonVariables.Scoping
	GUI.Crosshair.Visible = not CommonVariables.Scoping

	if not CommonVariables.Scoping then
		Springs.Scope.t = Vector3.new(600, 200, 0)
	end

	local Size = Springs.CrossSpring.p * 4 * Springs.CrossScale.p
	GUI.Crosshair.Size = UDim2.new(0, Size, 0, Size)

	local Cross = GUI.Crosshair.Center.ImageLabel

	if not CommonVariables.Scoping then
		local BASE_OFFSET = 7
		local SPREAD_MULT = 3
		local MAX_OFFSET = 1000
		local spread = AddressTableValue("Spread", CurrentModule)
		local camRecoil = math.abs(Springs.CameraSpring.p.X) + math.abs(Springs.CameraSpring.p.Y)
		local offset = BASE_OFFSET + math.clamp(spread * SPREAD_MULT, 0, MAX_OFFSET) + math.clamp(camRecoil * 6, 0, 22)

		Cross.UP.Position = UDim2.new(0.5, 0, 0.5, -offset)
		Cross.DOWN.Position = UDim2.new(0.5, 0, 0.5, offset)
		Cross.LEFT.Position = UDim2.new(0.5, -offset, 0.5, 0)
		Cross.RIGHT.Position = UDim2.new(0.5, offset, 0.5, 0)
	else
		local idle = 7
		Cross.UP.Position = UDim2.new(0.5, 0, 0.5, -idle) --0.5, 0, 0.5, -idle
		Cross.DOWN.Position = UDim2.new(0.5, 0, 0.5, idle) --0.5, 0, 0.5, idle
		Cross.LEFT.Position = UDim2.new(0.5, -idle, 0.5, 0) --0.5, -idle, 0.5, 0
		Cross.RIGHT.Position = UDim2.new(0.5, idle, 0.5, 0) --0.5, idle, 0.5, 0
	end

	Camera.CFrame = Camera.CFrame
		* CFrame.Angles(
			Springs.CameraSpring.p.X * (dt * 60),
			Springs.CameraSpring.p.Y * (dt * 60),
			Springs.CameraSpring.p.Z * (dt * 60)
		)
end

function SetAnimationTrack(AnimationName, Action, Speed, FadeTime, WhenToSet)
	local AnimationTrack = CurrentAnimTable[AnimationName]
	if AnimationName == "AimFireAnim" then
		AnimationTrack = CurrentAimFireAnim
	elseif AnimationName == "FireAnim" then
		AnimationTrack = CurrentFireAnim
	elseif AnimationName == "AimLastFireAnim" then
		AnimationTrack = CurrentAimLastFireAnim
	elseif AnimationName == "LastFireAnim" then
		AnimationTrack = CurrentLastFireAnim
	elseif AnimationName == "ShotgunPumpinAnim" then
		AnimationTrack = CurrentShotgunPumpinAnim
	elseif AnimationName == "InspectAnim" then
		AnimationTrack = (CurrentVariables.Mag <= 0) and CurrentAnimTable.EmptyInspectAnim
			or CurrentAnimTable.InspectAnim
	end
	if AnimationTrack then
		local CanSet = true
		if WhenToSet then
			if WhenToSet == "IsPlaying" then
				CanSet = AnimationTrack.IsPlaying
			else
				CanSet = not AnimationTrack.IsPlaying
			end
		end
		if CanSet then
			if Action == "Play" then
				AnimationTrack:Play(FadeTime, nil, Speed)
			else
				AnimationTrack:Stop(FadeTime)
			end
		end
	end
end

function SetFireSoundLoopEnabled(Id, Enabled)
	if CurrentModule.ShouldLoop then
		local FireSound = GetCurrentModeChild(AddressTableValue("FireSound", CurrentModule))
		if FireSound and FireSound:IsA("Sound") then
			gunEvent:Fire("PlayAudio", {
				Instance = FireSound,
				Origin = CurrentMuzzlePoint,
				Echo = CurrentModule.EchoEffect,
				Silenced = CurrentModule.SilenceEffect,
				LoopData = {
					Enabled = Enabled,
					Id = Id,
				},
			}, nil, true)
		end
	end
end

function VisibleMuzz(MuzzlePointObject, Enabled)
	for i, v in pairs(MuzzlePointObject:GetChildren()) do
		if v.ClassName == "ParticleEmitter" then
			if v:FindFirstChild("EmitCount") then
				if Enabled then
					Thread:Delay(0.01, function()
						v:Emit(v.EmitCount.Value)
					end)
				end
			else
				v.Enabled = Enabled
			end
		end
	end
end

local MarkerSoundPool = {}
local MAX_MARKER_SOUND_POOL = 4

local function ReturnMarkerSound(sound)
	sound:Stop()
	sound.Parent = nil
	if #MarkerSoundPool < MAX_MARKER_SOUND_POOL then
		table.insert(MarkerSoundPool, sound)
	else
		sound:Destroy()
	end
end

local function PlayPooledMarkerSound(ClientModule, IsHeadshot)
	local sound = table.remove(MarkerSoundPool) or GUI.Crosshair.MarkerSound:Clone()
	sound.Name = "MarkerSoundClone"
	sound.SoundId = "rbxassetid://" .. ClientModule.HitmarkerSoundIDs[math.random(1, #ClientModule.HitmarkerSoundIDs)]
	sound.PlaybackSpeed = IsHeadshot and ClientModule.HitmarkerSoundPitchHS or ClientModule.HitmarkerSoundPitch
	sound.Parent = GUI.Crosshair
	sound:Play()

	local returned = false
	local connection
	local function release()
		if returned then
			return
		end
		returned = true
		if connection then
			connection:Disconnect()
			connection = nil
		end
		ReturnMarkerSound(sound)
	end

	connection = sound.Ended:Connect(release)
	Thread:Delay(1.25, release)
end

local ShellPool = {}
local MAX_SHELL_POOL_PER_TYPE = 24

local function GetPooledShell(shellType)
	local pool = ShellPool[shellType]
	local shell = pool and table.remove(pool)
	if shell then
		return shell
	end
	return Miscs.BulletShells[shellType]:Clone()
end

local function ReturnPooledShell(shellType, shell)
	if not shell then
		return
	end
	shell.Parent = nil
	shell.Velocity = Vector3.zero
	shell.RotVelocity = Vector3.zero
	for _, child in ipairs(shell:GetChildren()) do
		if child:IsA("Sound") and child.Name == "BulletShellHitSound" then
			child:Destroy()
		end
	end

	ShellPool[shellType] = ShellPool[shellType] or {}
	if #ShellPool[shellType] < MAX_SHELL_POOL_PER_TYPE then
		table.insert(ShellPool[shellType], shell)
	else
		shell:Destroy()
	end
end

function MarkHit(ClientModule, IsHeadshot)
	if ClientModule.HitmarkerEnabled then
		if IsHeadshot then
			GUI.Crosshair.Hitmarker.ImageColor3 = ClientModule.HitmarkerColorHS
			GUI.Crosshair.Hitmarker.ImageTransparency = 0
			TweenService:Create(
				GUI.Crosshair.Hitmarker,
				TweenInfo.new(ClientModule.HitmarkerFadeTimeHS, Enum.EasingStyle.Linear, Enum.EasingDirection.Out),
				{ ImageTransparency = 1 }
			):Play()
		else
			GUI.Crosshair.Hitmarker.ImageColor3 = ClientModule.HitmarkerColor
			GUI.Crosshair.Hitmarker.ImageTransparency = 0
			TweenService:Create(
				GUI.Crosshair.Hitmarker,
				TweenInfo.new(ClientModule.HitmarkerFadeTime, Enum.EasingStyle.Linear, Enum.EasingDirection.Out),
				{ ImageTransparency = 1 }
			):Play()
		end
		PlayPooledMarkerSound(ClientModule, IsHeadshot)
	end
end

function EjectShell(ShootingHandle, TempModule)
	if AddressTableValue("BulletShellEnabled", TempModule) then
		if AddressTableValue("BulletShellParticles", TempModule) then
			local ShellEjectParticlePoint = ShootingHandle:FindFirstChild("ShellEjectParticlePoint" .. CurrentFireMode)
			local ShellEjectEffect = GunVisualEffects:FindFirstChild(AddressTableValue("ShellEjectEffect", TempModule))
			if ShellEjectParticlePoint and ShellEjectEffect then
				for i, v in pairs(ShellEjectEffect:GetChildren()) do
					if v.ClassName == "ParticleEmitter" then
						local Count = 1
						local Particle = v:Clone()
						Particle.Parent = ShellEjectParticlePoint
						if Particle:FindFirstChild("EmitCount") then
							Count = Particle.EmitCount.Value
						end
						Thread:Delay(0.01, function()
							Particle:Emit(Count)
							Debris:AddItem(Particle, Particle.Lifetime.Max)
						end)
					end
				end
			end
		end
		local RadomizeRotVelocity = AddressTableValue("RadomizeRotVelocity", TempModule)
		local EjectPoint = ShootingHandle:FindFirstChild("ShellEjectPoint" .. CurrentFireMode)
		if not EjectPoint then
			return
		end
		local ShellType = AddressTableValue("BulletShellType", TempModule)
		local Shell = GetPooledShell(ShellType)
		Shell.CFrame = EjectPoint.WorldCFrame
		Shell.CanCollide = AddressTableValue("AllowCollide", TempModule)
		Shell.Velocity = EjectPoint.WorldCFrame.LookVector * AddressTableValue("BulletShellVelocity", TempModule)
		Shell.RotVelocity = (
			RadomizeRotVelocity and EjectPoint.WorldCFrame.XVector or EjectPoint.WorldCFrame.LookVector
		) * AddressTableValue("BulletShellRotVelocity", TempModule)
		Shell.Parent = Camera
		local TouchedConnection = nil
		if AddressTableValue("BulletShellHitSoundEnabled", TempModule) then
			local BulletShellHitSoundIDs = AddressTableValue("BulletShellHitSoundIDs", TempModule)
			local BulletShellHitSoundVolume = AddressTableValue("BulletShellHitSoundVolume", TempModule)
			local BulletShellHitSoundPitchMin = AddressTableValue("BulletShellHitSoundPitchMin", TempModule)
			local BulletShellHitSoundPitchMax = AddressTableValue("BulletShellHitSoundPitchMax", TempModule)
			TouchedConnection = Shell.Touched:Connect(function(Hit)
				if not Hit:IsDescendantOf(Character) then
					local Sound = Instance.new("Sound")
					Sound.Name = "BulletShellHitSound"
					Sound.SoundId = "rbxassetid://" .. BulletShellHitSoundIDs[math.random(1, #BulletShellHitSoundIDs)]
					Sound.PlaybackSpeed = RNG:NextNumber(BulletShellHitSoundPitchMin, BulletShellHitSoundPitchMax)
					Sound.Volume = BulletShellHitSoundVolume
					Sound.Parent = Shell
					Sound:Play()
					if TouchedConnection then
						TouchedConnection:Disconnect()
						TouchedConnection = nil
					end
				end
			end)
		end
		Thread:Delay(AddressTableValue("DisappearTime", TempModule), function()
			if TouchedConnection then
				TouchedConnection:Disconnect()
				TouchedConnection = nil
			end
			ReturnPooledShell(ShellType, Shell)
		end)
	end
end

local ClientCasingPool = {}
local MAX_CLIENT_CASING_POOL_PER_TYPE = math.max(Module.MaxCount or 0, 24)

local function GetClientCasingTemplate(casingType)
	return casingType == "Bullet" and GUI.MagCartridge.UIGridLayout.Template or GUI.MagCartridge.UIGridLayout.Shell
end

local function GetPooledClientCasing(casingType)
	ClientCasingPool[casingType] = ClientCasingPool[casingType] or {}
	local casing = table.remove(ClientCasingPool[casingType])
	if casing then
		return casing
	end
	return GetClientCasingTemplate(casingType):Clone()
end

local function ReturnPooledClientCasing(casing, casingType)
	if not casing then
		return
	end

	casing.Parent = nil
	casing.Visible = true
	ClientCasingPool[casingType] = ClientCasingPool[casingType] or {}
	if #ClientCasingPool[casingType] < MAX_CLIENT_CASING_POOL_PER_TYPE then
		table.insert(ClientCasingPool[casingType], casing)
	else
		casing:Destroy()
	end
end

function CreateCasing(ObjRot, Pos, Size, Vel, Type, Shockwave)
	local MaxedOut = CommonVariables.CasingCount >= Module.MaxCount
	if MaxedOut and Module.RemoveOldAtMax then
		local RemoveCoutndown = math.random(1, Module.MaxCount)
		for casing, _ in pairs(CommonVariables.Casings) do
			RemoveCoutndown = RemoveCoutndown - 1
			if RemoveCoutndown <= 0 then
				local data = CommonVariables.Casings[casing]
				ReturnPooledClientCasing(casing, data and data.Type or "Shell")
				CommonVariables.CasingCount = CommonVariables.CasingCount - 1
				CommonVariables.Casings[casing] = nil
				MaxedOut = CommonVariables.CasingCount >= Module.MaxCount
				break
			end
		end
	end
	if not MaxedOut then
		CommonVariables.CasingCount = CommonVariables.CasingCount + 1
		local Rot = ObjRot
		local XCenter = Pos.X + (Size.X / 2)
		local YCenter = Pos.Y + (Size.Y / 2)
		local Data = {
			RotVel = (math.random() * 2 - 1) * Module.MaxRotationSpeed,
			Rot = Rot,
			Pos = (Pos and Vector2.new(XCenter, YCenter) or Vector2.new(0, 0)) + TopbarOffset,
			Vel = Vel or Vector2.new(0, 0),
			Type = Type,
		}
		local Clone = GetPooledClientCasing(Type)
		Clone.Rotation = Rot
		Clone.Visible = true
		CommonVariables.Casings[Clone] = Data
		Clone.Parent = GUI
		if Shockwave then
			Thread:Spawn(function()
				local ShockwaveClone = GUI.MagCartridge.UIGridLayout.Shockwave:Clone()
				local Degree = math.rad(math.random(360))
				ShockwaveClone.Position = UDim2.new(0, XCenter, 0, YCenter)
				ShockwaveClone.Rotation = math.deg(Degree)
				ShockwaveClone.Parent = GUI
				local Tween = TweenService:Create(
					ShockwaveClone,
					TweenInfo.new(0.25, Enum.EasingStyle.Linear, Enum.EasingDirection.Out),
					{ Size = UDim2.new(0, 50, 0, 50), ImageTransparency = 1 }
				)
				Tween:Play()
				Tween.Completed:Wait()
				ShockwaveClone:Destroy()
			end)
		end
	end
end

function Fire(ShootingHandle, MousePosition, FireDirections, TempModule, ModNames, Target, FirstShot)
	if (CurrentVariables.Mag - AddressTableValue("AmmoCost", TempModule)) <= 0 then
		if CommonVariables.AimDown then
			if CurrentAimLastFireAnim then
				if CurrentAimFireAnim and CurrentAimFireAnim.Looped then
					SetAnimationTrack("AimFireAnim", "Stop", nil, 0)
				end
				SetAnimationTrack("AimLastFireAnim", "Play", CurrentAimLastFireAnimationSpeed, 0.05)
			else
				if CurrentAimFireAnim then
					if CurrentFireAnim and CurrentFireAnim.Looped then
						SetAnimationTrack("FireAnim", "Stop", nil, 0)
					end
					SetAnimationTrack(
						"AimFireAnim",
						"Play",
						CurrentAimFireAnimationSpeed,
						0.05,
						CurrentAimFireAnim.Looped and "IsNotPlaying" or nil
					)
				else
					if CurrentLastFireAnim then
						if CurrentFireAnim and CurrentFireAnim.Looped then
							SetAnimationTrack("FireAnim", "Stop", nil, 0)
						end
						SetAnimationTrack("LastFireAnim", "Play", CurrentLastFireAnimationSpeed, 0.05)
					else
						SetAnimationTrack(
							"FireAnim",
							"Play",
							CurrentFireAnimationSpeed,
							0.05,
							(CurrentFireAnim and CurrentFireAnim.Looped) and "IsNotPlaying" or nil
						)
					end
				end
			end
		else
			if CurrentAimFireAnim and CurrentAimFireAnim.Looped then
				SetAnimationTrack("AimFireAnim", "Stop", nil, 0)
			end
			if CurrentLastFireAnim then
				if CurrentFireAnim and CurrentFireAnim.Looped then
					SetAnimationTrack("FireAnim", "Stop", nil, 0)
				end
				SetAnimationTrack("LastFireAnim", "Play", CurrentLastFireAnimationSpeed, 0.05)
			else
				SetAnimationTrack(
					"FireAnim",
					"Play",
					CurrentFireAnimationSpeed,
					0.05,
					(CurrentFireAnim and CurrentFireAnim.Looped) and "IsNotPlaying" or nil
				)
			end
		end
	else
		if CurrentAimFireAnim and CommonVariables.AimDown then
			if CurrentFireAnim and CurrentFireAnim.Looped then
				SetAnimationTrack("FireAnim", "Stop", nil, 0)
			end
			SetAnimationTrack(
				"AimFireAnim",
				"Play",
				CurrentAimFireAnimationSpeed,
				0.05,
				CurrentAimFireAnim.Looped and "IsNotPlaying" or nil
			)
		else
			if CurrentAimFireAnim and CurrentAimFireAnim.Looped then
				SetAnimationTrack("AimFireAnim", "Stop", nil, 0)
			end
			SetAnimationTrack(
				"FireAnim",
				"Play",
				CurrentFireAnimationSpeed,
				0.05,
				(CurrentFireAnim and CurrentFireAnim.Looped) and "IsNotPlaying" or nil
			)
		end
	end
	SetAnimationTrack("MinigunRevUpAnim", "Stop")
	local CanPlay = true
	if TempModule.LockOnScan and TempModule.InstaBurst then
		CanPlay = FirstShot
	end
	local ShootingHandleModeFolder, ShootingFirePoint, ShootingMuzzlePoint = GetShootingHandleData(ShootingHandle)
	local FireSound = ShootingHandleModeFolder
		and ShootingHandleModeFolder:FindFirstChild(AddressTableValue("FireSound", TempModule))
	if CanPlay and FireSound and not TempModule.ShouldLoop then
		local Track = FireSound
		if FireSound:IsA("Folder") then
			local Tracks = FireSound:GetChildren()
			local Chosen = math.random(1, #Tracks)
			Track = Tracks[Chosen]
		end
		if Track ~= nil then
			gunEvent:Fire("PlayAudio", {
				Instance = Track,
				Origin = ShootingMuzzlePoint,
				Echo = TempModule.EchoEffect,
				Silenced = TempModule.SilenceEffect,
			}, (TempModule.LowAmmo and CurrentVariables.Mag <= TempModule.AmmoPerMag / 5) and {
				CurrentAmmo = CurrentVariables.Mag,
				AmmoPerMag = TempModule.AmmoPerMag,
				Instance = ShootingHandleModeFolder
					and ShootingHandleModeFolder:FindFirstChild(AddressTableValue("LowAmmoSound", TempModule)),
				RaisePitch = TempModule.RaisePitch,
			} or nil, true)
		end
	end
	local Misc = {
		ChargeLevel = CurrentVariables.ChargeLevel,
		LockedEntity = Target or LockedEntity,
		MousePosition = MousePosition,
		ModuleName = TempModule.ModuleName,
		ModNames = ModNames,
		FirstShot = FirstShot,
	}
	gunEvent:Fire(
		"VisualizeBullet",
		Tool,
		ShootingHandle,
		FireDirections,
		ShootingFirePoint,
		ShootingMuzzlePoint,
		Misc,
		true
	)
	local OnClientShootEventName = AddressTableValue("OnClientShootEventName", TempModule)
	if OnClientShootEventName ~= "None" then
		OnClientShootEvents[OnClientShootEventName](
			AddressTableValue("OnClientShootEventData", TempModule),
			Character,
			Tool,
			ShootingHandle,
			FireDirections,
			ShootingFirePoint,
			ShootingMuzzlePoint,
			Misc
		)
	end
	local CanTrigger = true
	if TempModule.LockOnScan and TempModule.InstaBurst then
		CanTrigger = FirstShot
	end
	if CanTrigger then
		Thread:Spawn(function()
			if not TempModule.CameraRecoilingEnabled then
				return
			end

			local now = time()
			local dt = now - (CommonVariables.LastRecoilTime or 0)
			CommonVariables.LastRecoilTime = now

			if TempModule.RecoilMode == "Normal" then
				local recoil = AddressTableValue("Recoil", TempModule)
				local scale = CommonVariables.AimDown and (1 - TempModule.ADSRecoilRedution) or 1

				local rx = math.rad(
					recoil * Math.Randomize2(TempModule.AngleXMin, TempModule.AngleXMax, TempModule.Accuracy) * scale
				)
				local ry = math.rad(
					recoil * Math.Randomize2(TempModule.AngleYMin, TempModule.AngleYMax, TempModule.Accuracy) * scale
				)
				local rz = math.rad(
					recoil * Math.Randomize2(TempModule.AngleZMin, TempModule.AngleZMax, TempModule.Accuracy) * scale
				)

				Springs.Knockback:Accelerate(
					Vector3.new(-rx * TempModule.ScopeKnockbackMultiplier, -ry * TempModule.ScopeKnockbackMultiplier, 0)
				)
				Springs.CameraSpring:Accelerate(Vector3.new(rx, ry, rz))
				Thread:Wait(0.03)
				Springs.CameraSpring:Accelerate(Vector3.new(-rx, -ry, 0))
			end

			if TempModule.RecoilMode == "Pattern" then
				local baseRecoil = AddressTableValue("Recoil", TempModule) / 7.6
				local scale = CommonVariables.AimDown and (1 - TempModule.ADSRecoilRedution) or 1

				if dt > TempModule.SprayCurve.ResetTime then
					CommonVariables.RecoilCount = 0
				end

				CommonVariables.RecoilCount += 1
				local index = math.clamp(CommonVariables.RecoilCount, 1, #TempModule.SprayPattern)
				local spray = TempModule.SprayPattern[index]
				if not spray then
					return
				end

				local patternYaw = spray[1] * baseRecoil * scale
				local patternPitch = spray[2] * baseRecoil * scale

				local kickX = Math.Randomize2(TempModule.AngleXMin, TempModule.AngleXMax, TempModule.Accuracy)
					* baseRecoil
					* scale
				local kickY = Math.Randomize2(TempModule.AngleYMin, TempModule.AngleYMax, TempModule.Accuracy)
					* baseRecoil
					* scale

				local blend = 0.35
				local pitch = kickX + (patternPitch - kickX) * blend
				local yaw = kickY + (patternYaw - kickY) * blend

				Springs.CameraSpring:Accelerate(Vector3.new(math.rad(pitch), math.rad(yaw), 0))
			end
		end)

		Springs.CrossSpring:Accelerate(AddressTableValue("CrossExpansion", TempModule))
		if AddressTableValue("SelfKnockback", TempModule) then
			local basePower = AddressTableValue("SelfKnockbackPower", TempModule)
			local multiplier = AddressTableValue("SelfKnockbackMultiplier", TempModule)
			local reduction = AddressTableValue("SelfKnockbackRedution", TempModule)

			local grounded = Humanoid.FloorMaterial ~= Enum.Material.Air
			if not grounded then
				basePower *= 0.15
			end

			local power = basePower * multiplier * (1 - reduction)
			local dir = (Torso.Position - MousePosition)
			dir = Vector3.new(dir.X, 0, dir.Z)
			if dir.Magnitude == 0 then
				return
			end
			dir = dir.Unit

			local horiz = Vector3.new(Torso.Velocity.X, 0, Torso.Velocity.Z)
			local new = horiz + dir * power
			if new.Magnitude > 22 then
				new = new.Unit * 22
			end
			Torso.Velocity = Vector3.new(new.X, Torso.Velocity.Y, new.Z)
		end
	end

	local CanTrigger2 = true
	if TempModule.LockOnScan and TempModule.InstaBurst and TempModule.TriggerOnce then
		CanTrigger2 = FirstShot
	end
	if not CanTrigger2 then
		return
	end

	if TempModule.BatteryEnabled then
		CurrentVariables.ShotsForDepletion = CurrentVariables.ShotsForDepletion + 1
		if CurrentVariables.ShotsForDepletion >= TempModule.ShotsForDepletion then
			CurrentVariables.ShotsForDepletion = 0
			UniversalTable.Ammo = math.clamp(
				UniversalTable.Ammo
				- RNG:NextInteger(
					AddressTableValue("MinDepletion", TempModule),
					AddressTableValue("MaxDepletion", TempModule)
				),
				0,
				UniversalTable.MaxAmmo
			)
		end
		CurrentVariables.Heat = math.clamp(
			CurrentVariables.Heat
				+ RNG:NextInteger(
					AddressTableValue("HeatPerFireMin", TempModule),
					AddressTableValue("HeatPerFireMax", TempModule)
				),
			0,
			TempModule.MaxHeat
		)
	else
		local LastMag = CurrentVariables.Mag
		CurrentVariables.Mag =
			math.clamp(CurrentVariables.Mag - AddressTableValue("AmmoCost", TempModule), 0, TempModule.AmmoPerMag)
		if Module.MagCartridge and not TempModule.BatteryEnabled and TempModule.AmmoPerMag ~= math.huge then
			for i = 0, (LastMag - CurrentVariables.Mag) - 1 do
				local Bullet = GetMagCartridgeIcon(LastMag - i)
				if Bullet then
					if Module.Ejection then
						local Vel = Random2DDirection(
							Module.Velocity,
							math.random(Module.XMin, Module.XMax),
							math.random(Module.YMin, Module.YMax)
						) * (math.random() ^ 0.5)
						CreateCasing(
							Bullet.Rotation,
							Bullet.AbsolutePosition,
							Bullet.AbsoluteSize,
							Vel,
							"shell",
							Module.Shockwave
						)
					end
					Bullet.Visible = false
				end
			end
		end
	end
	ChangeMagAndAmmo:FireServer(CurrentFireMode, CurrentVariables.Mag, UniversalTable.Ammo)
	CommonVariables.ShootCounts = CommonVariables.ShootCounts - 1
	if CommonVariables.ShootCounts <= 0 then
		CommonVariables.ShootCounts = TempModule.ShootCounts
	end
	CurrentVariables.ShotID = CurrentVariables.ShotID + 1
	local LastShotID = CurrentVariables.ShotID
	Thread:Spawn(function()
		CommonVariables.CanBeCooledDown = false
		local Interrupted = false
		local StartTime = os.clock()
		repeat
			Thread:Wait()
			if LastShotID ~= CurrentVariables.ShotID then
				break
			end
		until (os.clock() - StartTime) >= AddressTableValue("TimeBeforeCooldown", TempModule)
		if LastShotID ~= CurrentVariables.ShotID then
			Interrupted = true
		end
		if not Interrupted then
			CommonVariables.CanBeCooledDown = true
		end
	end)
	RequestGUIUpdate()
	if CurrentAnimTable.EmptyIdleAnim and CurrentVariables.Mag <= 0 then
		if CurrentAnimTable.EmptyAimIdleAnim and CommonVariables.AimDown then
			SetAnimationTrack("AimIdleAnim", "Stop")
			SetAnimationTrack("EmptyAimIdleAnim", "Play", TempModule.EmptyAimIdleAnimationSpeed)
		else
			SetAnimationTrack("IdleAnim", "Stop")
			SetAnimationTrack("EmptyIdleAnim", "Play", TempModule.EmptyIdleAnimationSpeed)
		end
	end
end

function CycleHandles()
	CurrentVariables.HandleIndex = CurrentVariables.HandleIndex % #CurrentModule.Handles + 1
	HandleToFire = Tool:FindFirstChild(CurrentModule.Handles[CurrentVariables.HandleIndex], true)
	RefreshHandleCache()

	if #CurrentAnimTable.AimFireAnims > 0 then
		CurrentVariables.AimFireAnimIndex = CurrentVariables.AimFireAnimIndex % #CurrentAnimTable.AimFireAnims + 1
		CurrentAimFireAnim = CurrentAnimTable.AimFireAnims[CurrentVariables.AimFireAnimIndex][1]
		CurrentAimFireAnimationSpeed = CurrentAnimTable.AimFireAnims[CurrentVariables.AimFireAnimIndex][2]
	end
	if #CurrentAnimTable.FireAnims > 0 then
		CurrentVariables.FireAnimIndex = CurrentVariables.FireAnimIndex % #CurrentAnimTable.FireAnims + 1
		CurrentFireAnim = CurrentAnimTable.FireAnims[CurrentVariables.FireAnimIndex][1]
		CurrentFireAnimationSpeed = CurrentAnimTable.FireAnims[CurrentVariables.FireAnimIndex][2]
	end
	if #CurrentAnimTable.AimLastFireAnims > 0 then
		CurrentVariables.AimLastFireAnimIndex = CurrentVariables.AimLastFireAnimIndex
			% #CurrentAnimTable.AimLastFireAnims
			+ 1
		CurrentAimLastFireAnim = CurrentAnimTable.AimLastFireAnims[CurrentVariables.AimLastFireAnimIndex][1]
		CurrentAimLastFireAnimationSpeed = CurrentAnimTable.AimLastFireAnims[CurrentVariables.AimLastFireAnimIndex][2]
	end
	if #CurrentAnimTable.LastFireAnims > 0 then
		CurrentVariables.LastFireAnimIndex = CurrentVariables.LastFireAnimIndex % #CurrentAnimTable.LastFireAnims + 1
		CurrentLastFireAnim = CurrentAnimTable.LastFireAnims[CurrentVariables.LastFireAnimIndex][1]
		CurrentLastFireAnimationSpeed = CurrentAnimTable.LastFireAnims[CurrentVariables.LastFireAnimIndex][2]
	end
	if #CurrentAnimTable.ShotgunPumpinAnims > 0 then
		CurrentVariables.ShotgunPumpinAnimIndex = CurrentVariables.ShotgunPumpinAnimIndex
			% #CurrentAnimTable.ShotgunPumpinAnims
			+ 1
		CurrentShotgunPumpinAnim = CurrentAnimTable.ShotgunPumpinAnims[CurrentVariables.ShotgunPumpinAnimIndex][1]
		CurrentShotgunPumpinAnimationSpeed =
			CurrentAnimTable.ShotgunPumpinAnims[CurrentVariables.ShotgunPumpinAnimIndex][2]
	end
end

CommonVariables.ADSCameraModeWasForced = false
CommonVariables.CameraModeBeforeADS = nil

function CommonVariables.ForceADSCameraMode()
	if not CommonVariables.ADSCameraModeWasForced then
		CommonVariables.CameraModeBeforeADS = Player.CameraMode
		CommonVariables.ADSCameraModeWasForced = true
	end

	if Player.CameraMode ~= Enum.CameraMode.LockFirstPerson then
		Player.CameraMode = Enum.CameraMode.LockFirstPerson
	end
end

function CommonVariables.RestoreADSCameraMode()
	if not CommonVariables.ADSCameraModeWasForced then
		return
	end

	local modeToRestore = CommonVariables.CameraModeBeforeADS
	CommonVariables.ADSCameraModeWasForced = false
	CommonVariables.CameraModeBeforeADS = nil

	if modeToRestore then
		Player.CameraMode = modeToRestore
	end
end

function SetADS(ForceDisable)
	if not CurrentModule.ADSEnabled then
		return
	end
	local Info
	local function Disable()
		Info =
			TweenInfo.new(CurrentModule.TweenLengthNAD, CurrentModule.EasingStyleNAD, CurrentModule.EasingDirectionNAD)
		TweenService:Create(Camera, Info, { FieldOfView = 70 }):Play()
		SetCrossScale(1)
		if CommonVariables.ActuallyEquipped then
			SetAnimationTrack("AimIdleAnim", "Stop")
			SetAnimationTrack("EmptyAimIdleAnim", "Stop")
			if CurrentAnimTable.EmptyIdleAnim and CurrentVariables.Mag <= 0 then
				SetAnimationTrack("EmptyIdleAnim", "Play", CurrentModule.EmptyIdleAnimationSpeed)
			else
				SetAnimationTrack("IdleAnim", "Play", CurrentModule.IdleAnimationSpeed)
			end
		end
		SetADSSensitivityEnabled(false)
		CommonVariables.AimDown = false
		CommonVariables.Scoping = false
		if CurrentModule.HideCrosshair then
			TweenService:Create(CurrentCrosshair, Info, { GroupTransparency = 0 }):Play()
		end

		-- Reload/hold-down call SetADS(true) to cancel ADS. Do not force the
		-- player into first person unless ADS actually forced it first.
		CommonVariables.RestoreADSCameraMode()
	end
	if ForceDisable then
		Disable()
		return
	end
	if not CommonVariables.Equipped then
		return
	end
	if
		not CommonVariables.Reloading
		and not CommonVariables.Overheated
		and not CommonVariables.HoldDown
		and not CommonVariables.Switching
		and not CommonVariables.Alting
		and not CommonVariables.AimDown
		and CommonVariables.ActuallyEquipped
	then
		Info = TweenInfo.new(CurrentModule.TweenLength, CurrentModule.EasingStyle, CurrentModule.EasingDirection)
		TweenService:Create(Camera, Info, { FieldOfView = CurrentModule.ADSFieldOfView }):Play()
		SetCrossScale(CurrentModule.ADSCrossScale)
		SetAnimationTrack("InspectAnim", "Stop", nil, 0)
		if CurrentAnimTable.AimIdleAnim then
			SetAnimationTrack("IdleAnim", "Stop")
			SetAnimationTrack("EmptyIdleAnim", "Stop")
			if CurrentAnimTable.EmptyAimIdleAnim and CurrentVariables.Mag <= 0 then
				SetAnimationTrack("EmptyAimIdleAnim", "Play", CurrentModule.EmptyAimIdleAnimationSpeed)
			else
				SetAnimationTrack("AimIdleAnim", "Play", CurrentModule.AimIdleAnimationSpeed)
			end
		end
		SetADSSensitivityEnabled(true)
		CommonVariables.AimDown = true
		if CurrentModule.HideCrosshair then
			TweenService:Create(CurrentCrosshair, Info, { GroupTransparency = 1 }):Play()
		end
		if not Module.ThirdPersonADS then
			CommonVariables.ForceADSCameraMode()
		else
			if Module.ForceFirstPerson then
				CommonVariables.ForceADSCameraMode()
			end
		end
		if CurrentModule.ADSType == "Sniper" then
			local StartTime = os.clock()
			repeat
				Thread:Wait()
				if not (CommonVariables.ActuallyEquipped or CommonVariables.AimDown) then
					break
				end
			until (os.clock() - StartTime) >= CurrentModule.ScopeDelay
			if CommonVariables.ActuallyEquipped and CommonVariables.AimDown then
				GUI.Scope.ZoomSound:Play()
				CommonVariables.ForceADSCameraMode()
				CommonVariables.Scoping = true
			end
		end
	else
		Disable()
	end
end

function SetChargeEffect(ChargeLevel, ChargeEffect)
	gunEvent:Fire("VisualizeCharge", ChargeEffect, "Begin", Character, Tool, HandleToFire, ChargeLevel, true)
end

function CleanupBeamTable()
	for _, beam in pairs(BeamTable) do
		if beam then
			beam:Destroy()
		end
	end
	table.clear(BeamTable)
end

function CleanupClientCasings()
	for casing, data in pairs(CommonVariables.Casings) do
		ReturnPooledClientCasing(casing, data and data.Type or "Shell")
	end
	table.clear(CommonVariables.Casings)
	CommonVariables.CasingCount = 0
end

function RemoveStuff(StopSounds)
	for _, v in pairs(CommonVariables.KeyframeConnections) do
		v:Disconnect()
	end
	table.clear(CommonVariables.KeyframeConnections)
	LockedEntity = nil
	TargetMarker.Enabled = false
	TargetMarker.Parent = script
	TargetMarker.Adornee = nil
	if CommonVariables.Radar then
		CommonVariables.Radar:Destroy()
		CommonVariables.Radar = nil
	end
	if CommonVariables.Beam then
		CommonVariables.Beam:Destroy()
		CommonVariables.Beam = nil
	end
	if CommonVariables.Attach0 then
		CommonVariables.Attach0:Destroy()
		CommonVariables.Attach0 = nil
	end
	if CommonVariables.Attach1 then
		CommonVariables.Attach1:Destroy()
		CommonVariables.Attach1 = nil
	end
	if CommonVariables.LaserTrail then
		CommonVariables.LaserTrail:Destroy()
		CommonVariables.LaserTrail = nil
	end
	CleanupBeamTable()
	CrosshairPointAttachment:ClearAllChildren()
	CrosshairPointAttachment.Parent = nil
	CleanupClientCasings()
	for _, a in pairs(CurrentAnimTable) do
		if typeof(a) == "table" then
			for _, a2 in pairs(a) do
				if a2[1].IsPlaying then
					a2[1]:Stop()
				end
			end
		else
			if a.IsPlaying then
				a:Stop()
			end
		end
	end
	if StopSounds then
		for _, h in pairs(CurrentModule.Handles) do
			local handle = Tool:FindFirstChild(h, true)
			if handle then
				for _, s in pairs(handle[CurrentFireMode]:GetChildren()) do
					if s:IsA("Sound") and s.IsPlaying then
						s:Stop()
					end
				end
			end
		end
	end
end

function Overheat()
	if
		CommonVariables.ActuallyEquipped
		and CommonVariables.Enabled
		and not CommonVariables.Overheated
		and CurrentVariables.Heat >= CurrentModule.MaxHeat
	then
		CommonVariables.Overheated = true
		SetAnimationTrack("InspectAnim", "Stop", nil, 0)
		SetADS(true)
		RequestGUIUpdate()
		if CommonVariables.ActuallyEquipped then
			SetAnimationTrack("OverheatAnim", "Play", CurrentModule.OverheatAnimationSpeed)
			HandleToFire[CurrentFireMode].OverheatSound:Play()
			gunEvent:Fire(
				"VisualizeOverheat",
				CurrentModule.OverheatEffect,
				"Begin",
				Character,
				Tool,
				HandleToFire,
				true
			)
		end
		for i = 1, CurrentModule.MaxHeat do
			Thread:Wait(CurrentModule.OverheatTime / CurrentModule.MaxHeat)
			CurrentVariables.Heat = CurrentVariables.Heat - 1
			RequestGUIUpdate()
			if CurrentVariables.Heat == 0 then
				CommonVariables.Overheated = false
				break
			end
		end
		CommonVariables.Overheated = false
		RequestGUIUpdate()
		if CommonVariables.ActuallyEquipped then
			gunEvent:Fire("VisualizeOverheat", CurrentModule.OverheatEffect, "End", Character, Tool, HandleToFire, true)
		end
	end
end

function Reload()
	if
		CommonVariables.ActuallyEquipped
		and CommonVariables.Enabled
		and not CommonVariables.Reloading
		and (UniversalTable.Ammo > 0 or not (Module.UniversalAmmoEnabled or CurrentModule.LimitedAmmoEnabled))
		and CurrentVariables.Mag < CurrentModule.AmmoPerMag
	then
		CommonVariables.Reloading = true
		SetAnimationTrack("InspectAnim", "Stop", nil, 0)
		if CommonVariables.AimDown or CommonVariables.Scoping then
			SetADS(true)
		end
		RequestGUIUpdate()
		local function PlayIdleAnim()
			SetAnimationTrack("IdleAnim", "Stop")
			SetAnimationTrack("EmptyIdleAnim", "Stop")
			SetAnimationTrack("AimIdleAnim", "Stop")
			SetAnimationTrack("EmptyAimIdleAnim", "Stop")
			if CurrentAnimTable.EmptyIdleAnim and CurrentVariables.Mag <= 0 then
				if CurrentAnimTable.EmptyAimIdleAnim and CommonVariables.AimDown then
					SetAnimationTrack("EmptyAimIdleAnim", "Play", CurrentModule.EmptyAimIdleAnimationSpeed)
				else
					SetAnimationTrack("EmptyIdleAnim", "Play", CurrentModule.EmptyIdleAnimationSpeed)
				end
			else
				if CurrentAnimTable.AimIdleAnim and CommonVariables.AimDown then
					SetAnimationTrack("AimIdleAnim", "Play", CurrentModule.AimIdleAnimationSpeed)
				else
					SetAnimationTrack("IdleAnim", "Play", CurrentModule.IdleAnimationSpeed)
				end
			end
		end
		if CurrentModule.ShotgunReload then
			if CurrentModule.PreShotgunReload then
				if CommonVariables.ActuallyEquipped then
					SetAnimationTrack("PreShotgunReloadAnim", "Play", CurrentModule.PreShotgunReloadAnimationSpeed)
					HandleToFire[CurrentFireMode].PreReloadSound:Play()
				end
				local StartTime = os.clock()
				repeat
					Thread:Wait()
					if not CommonVariables.ActuallyEquipped or CommonVariables.CanCancelReload then
						if CommonVariables.ActuallyEquipped and CommonVariables.CanCancelReload then
							PlayIdleAnim()
							SetAnimationTrack("PreShotgunReloadAnim", "Stop")
							if HandleToFire[CurrentFireMode].PreReloadSound.Playing then
								HandleToFire[CurrentFireMode].PreReloadSound:Stop()
							end
						end
						break
					end
				until (os.clock() - StartTime) >= CurrentModule.PreShotgunReloadSpeed
			end
			for i = 1, (CurrentModule.AmmoPerMag - CurrentVariables.Mag) do
				if CommonVariables.ActuallyEquipped then
					SetAnimationTrack("ShotgunClipinAnim", "Play", CurrentModule.ShotgunClipinAnimationSpeed)
					HandleToFire[CurrentFireMode].ShotgunClipin:Play()
				end
				local StartTime = os.clock()
				repeat
					Thread:Wait()
					if not CommonVariables.ActuallyEquipped or CommonVariables.CanCancelReload then
						if CommonVariables.ActuallyEquipped and CommonVariables.CanCancelReload then
							PlayIdleAnim()
							SetAnimationTrack("ShotgunClipinAnim", "Stop")
							if HandleToFire[CurrentFireMode].ShotgunClipin.Playing then
								HandleToFire[CurrentFireMode].ShotgunClipin:Stop()
							end
						end
						break
					end
				until (os.clock() - StartTime) >= CurrentModule.ShellClipinSpeed
				if CommonVariables.CanCancelReload then
					break
				end
				if CurrentVariables.Mag < CurrentModule.AmmoPerMag then
					if CommonVariables.ActuallyEquipped then
						if
							(Module.UniversalAmmoEnabled or CurrentModule.LimitedAmmoEnabled)
							and UniversalTable.MaxAmmo ~= math.huge
						then
							if UniversalTable.Ammo > 0 then
								CurrentVariables.Mag = CurrentVariables.Mag + 1
								UniversalTable.Ammo = UniversalTable.Ammo - 1
								if Module.MagCartridge and not CurrentModule.BatteryEnabled then
									SetMagCartridgeVisibleThrough(CurrentVariables.Mag)
								end
								RequestGUIUpdate()
							end
						else
							CurrentVariables.Mag = CurrentVariables.Mag + 1
							RequestGUIUpdate()
						end
						ChangeMagAndAmmo:FireServer(CurrentFireMode, CurrentVariables.Mag, UniversalTable.Ammo)
					end
				else
					break
				end
				if
					(Module.UniversalAmmoEnabled or CurrentModule.LimitedAmmoEnabled)
					and UniversalTable.MaxAmmo ~= math.huge
				then
					if not CommonVariables.ActuallyEquipped or UniversalTable.Ammo <= 0 then
						break
					end
				else
					if not CommonVariables.ActuallyEquipped then
						break
					end
				end
			end
		end
		if CommonVariables.ActuallyEquipped and not CommonVariables.CanCancelReload then
			if CurrentModule.TacticalReloadAnimationEnabled then
				if CurrentVariables.Mag > 0 then
					SetAnimationTrack("TacticalReloadAnim", "Play", CurrentModule.TacticalReloadAnimationSpeed)
					HandleToFire[CurrentFireMode].TacticalReloadSound:Play()
				else
					SetAnimationTrack("ReloadAnim", "Play", CurrentModule.ReloadAnimationSpeed)
					HandleToFire[CurrentFireMode].ReloadSound:Play()
				end
			else
				SetAnimationTrack("ReloadAnim", "Play", CurrentModule.ReloadAnimationSpeed)
				HandleToFire[CurrentFireMode].ReloadSound:Play()
			end
		end
		local ReloadTime = (CurrentVariables.Mag > 0 and CurrentModule.TacticalReloadAnimationEnabled)
			and CurrentModule.TacticalReloadTime
			or CurrentModule.ReloadTime
		local StartTime = os.clock()
		repeat
			Thread:Wait()
			if not CommonVariables.ActuallyEquipped or CommonVariables.CanCancelReload then
				if CommonVariables.ActuallyEquipped and CommonVariables.CanCancelReload then
					PlayIdleAnim()
					SetAnimationTrack("TacticalReloadAnim", "Stop")
					if HandleToFire[CurrentFireMode].TacticalReloadSound.Playing then
						HandleToFire[CurrentFireMode].TacticalReloadSound:Stop()
					end
					SetAnimationTrack("ReloadAnim", "Stop")
					if HandleToFire[CurrentFireMode].ReloadSound.Playing then
						HandleToFire[CurrentFireMode].ReloadSound:Stop()
					end
				end
				break
			end
		until (os.clock() - StartTime) >= ReloadTime
		if CommonVariables.ActuallyEquipped and not CommonVariables.CanCancelReload then
			if not CurrentModule.ShotgunReload then
				if Module.MagCartridge and Module.DropAllRemainingBullets and not CurrentModule.BatteryEnabled then
					for i = 1, CurrentVariables.Mag do
						local Bullet = GetMagCartridgeIcon(i)
						if Bullet then
							local Vel = Random2DDirection(
								Module.DropVelocity,
								math.random(Module.DropXMin, Module.DropXMax),
								math.random(Module.DropYMin, Module.DropYMax)
							) * (math.random() ^ 0.5)
							CreateCasing(Bullet.Rotation, Bullet.AbsolutePosition, Bullet.AbsoluteSize, Vel, "Bullet")
						end
					end
				end
				if
					(Module.UniversalAmmoEnabled or CurrentModule.LimitedAmmoEnabled)
					and UniversalTable.MaxAmmo ~= math.huge
				then
					local AmmoToUse = math.min(CurrentModule.AmmoPerMag - CurrentVariables.Mag, UniversalTable.Ammo)
					CurrentVariables.Mag = CurrentVariables.Mag + AmmoToUse
					UniversalTable.Ammo = UniversalTable.Ammo - AmmoToUse
				else
					CurrentVariables.Mag = CurrentModule.AmmoPerMag
				end
				ChangeMagAndAmmo:FireServer(CurrentFireMode, CurrentVariables.Mag, UniversalTable.Ammo)
			end
			PlayIdleAnim()
		end
		CommonVariables.Reloading = false
		CommonVariables.CanCancelReload = false
		if Module.MagCartridge and not CurrentModule.BatteryEnabled then
			SetMagCartridgeVisibleThrough(CurrentVariables.Mag)
		end
		RequestGUIUpdate()
	end
end

function OnHoldingDown()
	if CurrentModule.HoldDownEnabled then
		if
			not CommonVariables.Reloading
			and not CommonVariables.Overheated
			and CommonVariables.ActuallyEquipped
			and CommonVariables.Enabled
		then
			if not CommonVariables.HoldDown then
				CommonVariables.HoldDown = true
				SetAnimationTrack("AimIdleAnim", "Stop")
				SetAnimationTrack("IdleAnim", "Stop")
				SetAnimationTrack("HoldDownAnim", "Play", CurrentModule.HoldDownAnimationSpeed)

				-- Only cancel ADS if ADS/scope is active. Calling SetADS(true)
				-- while not aiming should not touch CameraMode.
				if CommonVariables.AimDown or CommonVariables.Scoping then
					SetADS(true)
				end
			else
				CommonVariables.HoldDown = false
				SetAnimationTrack("IdleAnim", "Play", CurrentModule.IdleAnimationSpeed)
				SetAnimationTrack("HoldDownAnim", "Stop")
			end
		end
	end
end

function OnInspecting()
	if
		not CommonVariables.Reloading
		and not CommonVariables.Overheated
		and CommonVariables.ActuallyEquipped
		and CommonVariables.Enabled
		and not CommonVariables.AimDown
		and not CommonVariables.Inspecting
		and not CommonVariables.Switching
		and not CommonVariables.Alting
		and CurrentModule.InspectAnimationEnabled
	then
		CommonVariables.Inspecting = true
		local AnimationSpeed = CurrentAnimTable.InspectAnim and CurrentModule.InspectAnimationSpeed or 0
		local AnimationLength = CurrentAnimTable.InspectAnim and CurrentAnimTable.InspectAnim.Length or 0
		if CurrentVariables.Mag <= 0 then
			AnimationSpeed = CurrentAnimTable.EmptyInspectAnim and CurrentModule.EmptyInspectAnimationSpeed
				or (CurrentAnimTable.InspectAnim and CurrentModule.InspectAnimationSpeed or 0)
			AnimationLength = CurrentAnimTable.EmptyInspectAnim and CurrentAnimTable.EmptyInspectAnim.Length
				or (CurrentAnimTable.InspectAnim and CurrentAnimTable.InspectAnim.Length or 0)
		end
		SetAnimationTrack("InspectAnim", "Play", AnimationSpeed)
		local StartTime = os.clock()
		repeat
			Thread:Wait()
			if
				not CommonVariables.ActuallyEquipped
				or CommonVariables.Reloading
				or CommonVariables.Overheated
				or not CommonVariables.Enabled
				or CommonVariables.AimDown
				or CommonVariables.Switching
				or CommonVariables.Alting
			then
				break
			end
		until (os.clock() - StartTime) >= AnimationLength / AnimationSpeed
		CommonVariables.Inspecting = false
	end
end

function OnSwitching()
	if
		not CommonVariables.Reloading
		and not CommonVariables.Overheated
		and CommonVariables.ActuallyEquipped
		and CommonVariables.Enabled
		and not CommonVariables.Switching
		and not CommonVariables.Alting
		and CurrentModule.SelectiveFireEnabled
	then
		CommonVariables.Switching = true
		SetAnimationTrack("InspectAnim", "Stop", nil, 0)
		SetAnimationTrack("SwitchAnim", "Play", CurrentModule.SwitchAnimationSpeed)
		local StartTime = os.clock()
		repeat
			Thread:Wait()
			if
				not CommonVariables.ActuallyEquipped
				or CommonVariables.Reloading
				or CommonVariables.Overheated
				or not CommonVariables.Enabled
			then
				break
			end
		until (os.clock() - StartTime) >= CurrentModule.SwitchTime
		CommonVariables.Switching = false
		if
			CommonVariables.ActuallyEquipped
			and not CommonVariables.Reloading
			and not CommonVariables.Overheated
			and CommonVariables.Enabled
		then
			HandleToFire[CurrentFireMode].SwitchSound:Play()
			CurrentVariables.FireMode = CurrentVariables.FireMode % #CurrentVariables.FireModes + 1
			RequestGUIUpdate()
		end
	end
end

function OnAlting()
	if Module.AltFire and #Setting:GetChildren() > 1 then
		if
			not CommonVariables.Reloading
			and not CommonVariables.Overheated
			and CommonVariables.ActuallyEquipped
			and CommonVariables.Enabled
			and not CommonVariables.HoldDown
			and not CommonVariables.Alting
			and not CommonVariables.Switching
		then
			CommonVariables.Alting = true
			SetAnimationTrack("InspectAnim", "Stop", nil, 0)
			SetADS(true)
			SetAnimationTrack("AltAnim", "Play", CurrentModule.AltAnimationSpeed)
			HandleToFire[CurrentFireMode].AltSound:Play()
			local Interrupted = false
			local StartTime = os.clock()
			repeat
				Thread:Wait()
				if
					not CommonVariables.ActuallyEquipped
					or CommonVariables.Reloading
					or CommonVariables.Overheated
					or not CommonVariables.Enabled
				then
					Interrupted = true
					break
				end
			until (os.clock() - StartTime) >= CurrentModule.AltTime
			if Interrupted then
				SetAnimationTrack("AltAnim", "Stop")
				HandleToFire[CurrentFireMode].AltSound:Stop()
			end
			CommonVariables.Alting = false
			if
				CommonVariables.ActuallyEquipped
				and not CommonVariables.Reloading
				and not CommonVariables.Overheated
				and CommonVariables.Enabled
			then
				RemoveStuff()
				HandleToFire = Tool:FindFirstChild(CurrentModule.Handles[1], true)
				CommonVariables.CurrentRate = 0
				CommonVariables.LastRate = 0
				CommonVariables.ElapsedTime = 0
				CurrentFireMode = CurrentFireMode % #Settings + 1
				CurrentModule = CommonVariables.SettingModules[CurrentFireMode]
				CurrentVariables = Variables[CurrentFireMode]
				CurrentAnimTable = CommonVariables.Animations[CurrentFireMode]
				CurrentCrosshair = GUI.Crosshair[CurrentFireMode]
				for i, v in pairs(GUI.Crosshair:GetChildren()) do
					if v:IsA("CanvasGroup") then
						v.Visible = (tonumber(v.Name) == CurrentFireMode)
					end
				end
				CommonVariables.ShootCounts = CurrentModule.ShootCounts
				if not Module.UniversalAmmoEnabled then
					UniversalTable = CurrentVariables
				end
				CurrentVariables.HandleIndex = 1
				HandleToFire = Tool:FindFirstChild(CurrentModule.Handles[CurrentVariables.HandleIndex], true)
				RefreshHandleCache()
				CurrentVariables.FireAnimIndex = 1
				CurrentVariables.LastFireAnimIndex = 1
				CurrentVariables.AimFireAnimIndex = 1
				CurrentVariables.AimLastFireAnimIndex = 1
				CurrentVariables.ShotgunPumpinAnimIndex = 1
				CurrentAimFireAnim = #CurrentAnimTable.AimFireAnims > 0 and CurrentAnimTable.AimFireAnims[1][1] or nil
				CurrentAimFireAnimationSpeed = #CurrentAnimTable.AimFireAnims > 0
					and CurrentAnimTable.AimFireAnims[1][2]
					or nil
				CurrentFireAnim = #CurrentAnimTable.FireAnims > 0 and CurrentAnimTable.FireAnims[1][1] or nil
				CurrentFireAnimationSpeed = #CurrentAnimTable.FireAnims > 0 and CurrentAnimTable.FireAnims[1][2] or nil
				CurrentAimLastFireAnim = #CurrentAnimTable.AimLastFireAnims > 0
					and CurrentAnimTable.AimLastFireAnims[1][1]
					or nil
				CurrentAimLastFireAnimationSpeed = #CurrentAnimTable.AimLastFireAnims > 0
					and CurrentAnimTable.AimLastFireAnims[1][2]
					or nil
				CurrentLastFireAnim = #CurrentAnimTable.LastFireAnims > 0 and CurrentAnimTable.LastFireAnims[1][1]
					or nil
				CurrentLastFireAnimationSpeed = #CurrentAnimTable.LastFireAnims > 0
					and CurrentAnimTable.LastFireAnims[1][2]
					or nil
				CurrentShotgunPumpinAnim = #CurrentAnimTable.ShotgunPumpinAnims > 0
					and CurrentAnimTable.ShotgunPumpinAnims[1][1]
					or nil
				CurrentShotgunPumpinAnimationSpeed = #CurrentAnimTable.ShotgunPumpinAnims > 0
					and CurrentAnimTable.ShotgunPumpinAnims[1][2]
					or nil
				Springs.Scope.s = CurrentModule.ScopeSwaySpeed
				Springs.Scope.d = CurrentModule.ScopeSwayDamper
				Springs.Knockback.s = CurrentModule.ScopeKnockbackSpeed
				Springs.Knockback.d = CurrentModule.ScopeKnockbackDamper
				Springs.CameraSpring.s = CurrentModule.RecoilSpeed
				Springs.CameraSpring.d = CurrentModule.RecoilDamper
				for i, v in pairs(BeamTable) do
					if v then
						v:Destroy()
					end
				end
				table.clear(BeamTable)
				CrosshairPointAttachment:ClearAllChildren()
				LaserBeamEffect = GunVisualEffects:FindFirstChild(CurrentModule.LaserBeamEffect)
				if LaserBeamEffect then
					for i, v in pairs(LaserBeamEffect.HitEffect:GetChildren()) do
						if v.ClassName == "ParticleEmitter" then
							local particle = v:Clone()
							particle.Enabled = true
							particle.Parent = CrosshairPointAttachment
						end
					end
					for i, v in pairs(LaserBeamEffect.LaserBeams:GetChildren()) do
						if v.ClassName == "Beam" then
							local beam = v:Clone()
							table.insert(BeamTable, beam)
						end
					end
				end
				table.clear(CommonVariables.Keyframes)
				for _, a in pairs(CurrentAnimTable) do
					if typeof(a) == "table" then
						for _, a2 in pairs(a) do
							FindAnimationNameForKeyframe(a2[1])
						end
					else
						FindAnimationNameForKeyframe(a)
					end
				end
				for _, v in pairs(CommonVariables.Keyframes) do
					table.insert(
						CommonVariables.KeyframeConnections,
						v[1]:GetMarkerReachedSignal("AnimationEvents"):Connect(function(keyframeName)
							if v[2][keyframeName] then
								v[2][keyframeName](keyframeName, Tool)
							end
						end)
					)
				end
				BuildMagCartridgeIcons(CurrentVariables.Mag)
				CommonVariables.Radar = Scanners.Radars[CurrentModule.Radar]:Clone()
				CommonVariables.Radar.Name = "Scanner"
				CommonVariables.Radar.Parent = GUI
				SmokeTrail:StopEmission()
				if CurrentModule.ProjectileMotion then
					local MotionBeam = GunVisualEffects:FindFirstChild(CurrentModule.MotionBeam)
					if MotionBeam then
						CommonVariables.Beam, CommonVariables.Attach0, CommonVariables.Attach1 =
							ProjectileMotion.ShowProjectilePath(
								MotionBeam,
								(CurrentFirePoint and CurrentFirePoint.WorldPosition) or Head.Position,
								Vector3.new(),
								3,
								AddressTableValue("Acceleration", CurrentModule)
							)
					end
				end
				if CurrentAnimTable.EmptyIdleAnim and CurrentVariables.Mag <= 0 then
					SetAnimationTrack("EmptyIdleAnim", "Play", CurrentModule.EmptyIdleAnimationSpeed)
				else
					SetAnimationTrack("IdleAnim", "Play", CurrentModule.IdleAnimationSpeed)
				end
				RequestGUIUpdate()
				SetCrossSettings(CurrentModule.CrossSize, CurrentModule.CrossSpeed, CurrentModule.CrossDamper)
				if CommonVariables.ActuallyEquipped and Module.AutoReload and CurrentVariables.Mag <= 0 then
					Reload()
				end
			end
		end
	end
end

-- ============================================================
-- FIRING (unchanged logic, all paths preserved)
-- ============================================================
function OnFiring()
	if CurrentModule.LaserBeam then
		CommonVariables.Down = true
		if CanBeginFiring(CurrentModule.AmmoCost) then
			if Module.CancelReload then
				if CommonVariables.Reloading and not CommonVariables.CanCancelReload then
					CommonVariables.CanCancelReload = true
				end
			else
				if CommonVariables.Reloading then
					return
				end
			end
			CommonVariables.Enabled = false
			SetAnimationTrack("InspectAnim", "Stop", nil, 0)
			if CurrentModule.LaserBeamStartupDelay > 0 then
				SetAnimationTrack("LaserBeamStartupAnim", "Play", CurrentModule.LaserBeamStartupAnimationSpeed)
				if CommonVariables.ActuallyEquipped then
					PlayCurrentModeSound("BeamStartupSound")
				end
				local completedStartup = WaitWhileEquipped(CurrentModule.LaserBeamStartupDelay)
				if not completedStartup then
					SetAnimationTrack("LaserBeamStartupAnim", "Stop")
					StopCurrentModeSound("BeamStartupSound")
				end
			end
			local Start = false
			local MuzzlePoint = CurrentMuzzlePoint
			local FirePoint = CurrentFirePoint
			while CanContinueFiring(CurrentModule.AmmoCost) do
				SetAnimationTrack(
					"LaserBeamLoopAnim",
					"Play",
					CurrentModule.LaserBeamLoopAnimationSpeed,
					nil,
					"IsNotPlaying"
				)
				if not IsCurrentModeSoundPlayingLooped("BeamLoopSound") then
					PlayCurrentModeSound("BeamLoopSound")
				end
				local FireDirection = (Get3DPosition2() - FirePoint.WorldPosition).Unit
				local Hit, Pos, Normal, Material = CastRay(
					"Beam",
					FirePoint.WorldPosition,
					FireDirection,
					CurrentModule.LaserBeamRange,
					IgnoreList,
					true
				)
				if not Start then
					Start = true
					PlayCurrentModeSound("BeamFireSound")
					VisibleMuzz(MuzzlePoint, true)
					VisibleMuzzle:FireServer(MuzzlePoint, true)
					for i, v in pairs(BeamTable) do
						if v then
							v.Parent = HandleToFire
							v.Attachment0 = FirePoint
							v.Attachment1 = CrosshairPointAttachment
						end
					end
					if CurrentModule.LaserTrailEnabled then
						CommonVariables.LaserTrail = Miscs[CurrentModule.LaserTrailShape .. "Segment"]:Clone()
						CommonVariables.LaserTrail.CastShadow = false
						if CurrentModule.RandomizeLaserColorIn == "None" then
							CommonVariables.LaserTrail.Color = CurrentModule.LaserTrailColor
						end
						CommonVariables.LaserTrail.Material = CurrentModule.LaserTrailMaterial
						CommonVariables.LaserTrail.Reflectance = CurrentModule.LaserTrailReflectance
						CommonVariables.LaserTrail.Transparency = CurrentModule.LaserTrailTransparency
						CommonVariables.LaserTrail.Size = CurrentModule.LaserTrailShape == "Cone"
							and Vector3.new(
								CurrentModule.LaserTrailWidth,
								(FirePoint.WorldPosition - Pos).Magnitude,
								CurrentModule.LaserTrailHeight
							)
							or Vector3.new(
								(FirePoint.WorldPosition - Pos).Magnitude,
								CurrentModule.LaserTrailHeight,
								CurrentModule.LaserTrailWidth
							)
						CommonVariables.LaserTrail.CFrame = CFrame.new((FirePoint.WorldPosition + Pos) * 0.5, Pos)
							* (
								CurrentModule.LaserTrailShape == "Cone" and CFrame.Angles(math.pi / 2, 0, 0)
								or CFrame.Angles(0, math.pi / 2, 0)
							)
						CommonVariables.LaserTrail.Parent = Camera
					end
				end
				if CommonVariables.LaserTrail then
					if CurrentModule.RandomizeLaserColorIn ~= "None" then
						local Hue = os.clock() % CurrentModule.LaserColorCycleTime / CurrentModule.LaserColorCycleTime
						CommonVariables.LaserTrail.Color = Color3.fromHSV(Hue, 1, 1)
					end
					CommonVariables.LaserTrail.Size = CurrentModule.LaserTrailShape == "Cone"
						and Vector3.new(
							CurrentModule.LaserTrailWidth,
							(FirePoint.WorldPosition - Pos).Magnitude,
							CurrentModule.LaserTrailHeight
						)
						or Vector3.new(
							(FirePoint.WorldPosition - Pos).Magnitude,
							CurrentModule.LaserTrailHeight,
							CurrentModule.LaserTrailWidth
						)
					CommonVariables.LaserTrail.CFrame = CFrame.new((FirePoint.WorldPosition + Pos) * 0.5, Pos)
						* (
							CurrentModule.LaserTrailShape == "Cone" and CFrame.Angles(math.pi / 2, 0, 0)
							or CFrame.Angles(0, math.pi / 2, 0)
						)
				end
				CrosshairPointAttachment.Parent = Workspace.Terrain
				CrosshairPointAttachment.WorldCFrame = CFrame.new(Pos)
				if CurrentModule.LookAtInput then
					MuzzlePoint.CFrame =
						MuzzlePoint.Parent.CFrame:toObjectSpace(CFrame.lookAt(MuzzlePoint.WorldPosition, Pos))
					CrosshairPointAttachment.WorldCFrame = CFrame.new(Pos, FireDirection)
				end
				CommonVariables.Misc =
					{ ChargeLevel = CurrentVariables.ChargeLevel, ModuleName = CurrentModule.ModuleName }
				local lastUpdate = CommonVariables.LastUpdate or 0
				local now = os.clock()
				if (now - lastUpdate) > 0.1 then
					CommonVariables.LastUpdate = now
					VisualizeBeam:FireServer(true, {
						Id = GUID,
						Tool = Tool,
						ModuleName = CurrentModule.ModuleName,
						CrosshairPosition = Pos,
						Handle = HandleToFire,
						MuzzlePoint = MuzzlePoint,
						FirePoint = FirePoint,
					})
				end
				local lastUpdate2 = CommonVariables.LastUpdate2 or 0
				local now2 = os.clock()
				local ShouldCheckLaserTrailDamage = false
				if (now2 - lastUpdate2) > CurrentModule.LaserTrailDamageRate then
					CommonVariables.LastUpdate2 = now2
					ShouldCheckLaserTrailDamage = true
					if Hit then
						if Hit.Name == "_glass" and CurrentModule.CanBreakGlass then
							ShatterGlass:FireServer(Hit, Pos, FireDirection)
						else
							local Target = Hit:FindFirstAncestorOfClass("Model")
							local TargetHumanoid = Target and Target:FindFirstChildOfClass("Humanoid")
							local TargetTorso = Target
								and (Target:FindFirstChild("HumanoidRootPart") or Target:FindFirstChild("Head"))
							if TargetHumanoid and TargetHumanoid.Health > 0 and TargetTorso then
								Thread:Spawn(function()
									local TempMisc = CloneTable(CommonVariables.Misc)
									TempMisc["ClientHitSize"] = Hit.Size
									InflictTarget:FireServer("GunLaser", Tool, Hit, CreatePacket(TempMisc))
								end)
								MarkHit(CurrentModule)
							end
						end
					end
					if CurrentModule.BatteryEnabled then
						CurrentVariables.ShotsForDepletion = CurrentVariables.ShotsForDepletion + 1
						if CurrentVariables.ShotsForDepletion >= CurrentModule.ShotsForDepletion then
							CurrentVariables.ShotsForDepletion = 0
							UniversalTable.Ammo = math.clamp(
								UniversalTable.Ammo
								- RNG:NextInteger(CurrentModule.MinDepletion, CurrentModule.MaxDepletion),
								0,
								UniversalTable.MaxAmmo
							)
						end
						CurrentVariables.Heat = math.clamp(
							CurrentVariables.Heat
								+ RNG:NextInteger(CurrentModule.HeatPerFireMin, CurrentModule.HeatPerFireMax),
							0,
							CurrentModule.MaxHeat
						)
					else
						local LastMag = CurrentVariables.Mag
						CurrentVariables.Mag =
							math.clamp(CurrentVariables.Mag - CurrentModule.AmmoCost, 0, CurrentModule.AmmoPerMag)
						if
							Module.MagCartridge
							and not CurrentModule.BatteryEnabled
							and CurrentModule.AmmoPerMag ~= math.huge
						then
							for i = 0, (LastMag - CurrentVariables.Mag) - 1 do
								local Bullet = GetMagCartridgeIcon(LastMag - i)
								if Bullet then
									if Module.Ejection then
										local Vel = Random2DDirection(
											Module.Velocity,
											math.random(Module.XMin, Module.XMax),
											math.random(Module.YMin, Module.YMax)
										) * (math.random() ^ 0.5)
										CreateCasing(
											Bullet.Rotation,
											Bullet.AbsolutePosition,
											Bullet.AbsoluteSize,
											Vel,
											"Shell",
											Module.Shockwave
										)
									end
									Bullet.Visible = false
								end
							end
						end
					end
					ChangeMagAndAmmo:FireServer(CurrentFireMode, CurrentVariables.Mag, UniversalTable.Ammo)
					CommonVariables.ShootCounts = CommonVariables.ShootCounts - 1
					if CommonVariables.ShootCounts <= 0 then
						CommonVariables.ShootCounts = CurrentModule.ShootCounts
					end
					CurrentVariables.ShotID = CurrentVariables.ShotID + 1
					local LastShotID = CurrentVariables.ShotID
					Thread:Spawn(function()
						CommonVariables.CanBeCooledDown = false
						local StartTime = os.clock()
						repeat
							Thread:Wait()
							if LastShotID ~= CurrentVariables.ShotID then
								break
							end
						until (os.clock() - StartTime) >= CurrentModule.TimeBeforeCooldown
						if LastShotID == CurrentVariables.ShotID then
							CommonVariables.CanBeCooledDown = true
						end
					end)
					RequestGUIUpdate()
				end
				if
					ShouldCheckLaserTrailDamage
					and CommonVariables.LaserTrail
					and CurrentModule.DamageableLaserTrail
				then
					local TouchingParts = Workspace:GetPartsInPart(CommonVariables.LaserTrail, RegionParams)
					for _, part in pairs(TouchingParts) do
						if part and part.Parent then
							local Target = part:FindFirstAncestorOfClass("Model")
							local TargetHumanoid = Target and Target:FindFirstChildOfClass("Humanoid")
							local TargetTorso = Target
								and (Target:FindFirstChild("HumanoidRootPart") or part.Parent:FindFirstChild("Head"))
							if
								TargetHumanoid
								and TargetHumanoid.Health > 0
								and TargetHumanoid.Parent ~= Character
								and TargetTorso
							then
								if TrackOnce(CommonVariables.HitHumanoidSet, TargetHumanoid) then
									table.insert(CommonVariables.HitHumanoids, TargetHumanoid)
									Thread:Spawn(function()
										local TempMisc = CloneTable(CommonVariables.Misc)
										TempMisc["ClientHitSize"] = part.Size
										InflictTarget:FireServer("GunLaser", Tool, part, CreatePacket(TempMisc))
									end)
									MarkHit(CurrentModule)
									if CurrentModule.LaserTrailConstantDamage then
										Thread:Delay(CurrentModule.LaserTrailDamageRate, function()
											Untrack(CommonVariables.HitHumanoidSet, TargetHumanoid)
											local Index = table.find(CommonVariables.HitHumanoids, TargetHumanoid)
											if Index then
												table.remove(CommonVariables.HitHumanoids, Index)
											end
										end)
									end
								end
							end
						end
					end
				end
				CommonVariables.CurrentRate = CommonVariables.CurrentRate + CurrentModule.SmokeTrailRateIncrement
				Thread:Wait()
			end
			if CommonVariables.Misc then
				VisualizeBeam:FireServer(false, { Id = GUID, Tool = Tool, ModuleName = CurrentModule.ModuleName })
				CommonVariables.Misc = nil
			end
			for i, v in pairs(BeamTable) do
				if v then
					v.Attachment0 = nil
					v.Attachment1 = nil
					v.Parent = nil
				end
			end
			if CommonVariables.LaserTrail then
				Thread:Spawn(function()
					local LastLaserTrail = CommonVariables.LaserTrail
					if CurrentModule.LaserTrailFadeTime > 0 then
						local DesiredSize = LastLaserTrail.Size
							* (
								CurrentModule.ScaleLaserTrail
								and Vector3.new(
									1,
									CurrentModule.LaserTrailScaleMultiplier,
									CurrentModule.LaserTrailScaleMultiplier
								)
								or Vector3.new(1, 1, 1)
							)
						local Tween = TweenService:Create(
							LastLaserTrail,
							TweenInfo.new(
								CurrentModule.LaserTrailFadeTime,
								Enum.EasingStyle.Linear,
								Enum.EasingDirection.Out
							),
							{ Transparency = 1, Size = DesiredSize }
						)
						Tween:Play()
						Tween.Completed:Wait()
						LastLaserTrail:Destroy()
					else
						LastLaserTrail:Destroy()
					end
				end)
				CommonVariables.LaserTrail = nil
			end
			if CrosshairPointAttachment then
				CrosshairPointAttachment.Parent = nil
			end
			VisibleMuzz(MuzzlePoint, false)
			VisibleMuzzle:FireServer(MuzzlePoint, false)
			if
				CurrentModule.BatteryEnabled and CurrentVariables.Heat >= CurrentModule.MaxHeat
				or CurrentVariables.Mag <= 0
			then
				if CommonVariables.CurrentRate >= CurrentModule.MaximumRate and CurrentModule.SmokeTrailEnabled then
					Thread:Spawn(function()
						SmokeTrail:StopEmission()
						SmokeTrail:EmitSmokeTrail(CurrentSmokeTrailPoint, CurrentModule.MaximumTime)
					end)
				end
			end
			if IsCurrentModeSoundPlayingLooped("BeamLoopSound") then
				StopCurrentModeSound("BeamLoopSound")
			end
			SetAnimationTrack("LaserBeamLoopAnim", "Stop")
			SetAnimationTrack("LaserBeamStartupAnim", "Stop")
			StopCurrentModeSound("BeamFireSound")
			if CommonVariables.ActuallyEquipped then
				PlayCurrentModeSound("BeamEndSound")
			end
			local Overheated = false
			if
				CommonVariables.ActuallyEquipped
				and CurrentModule.BatteryEnabled
				and CurrentVariables.Heat >= CurrentModule.MaxHeat
			then
				Overheated = true
				CommonVariables.Enabled = true
				Thread:Spawn(Overheat)
			end
			if not Overheated then
				if CommonVariables.ActuallyEquipped then
					SetAnimationTrack("LaserBeamStopAnim", "Play", CurrentModule.LaserBeamStopAnimationSpeed)
				end
				Thread:Wait(CurrentModule.LaserBeamStopDelay)
				CommonVariables.Enabled = true
				if CommonVariables.ActuallyEquipped and Module.AutoReload and CurrentVariables.Mag <= 0 then
					Reload()
				end
			end
		end
	else
		if CurrentModule.ChargedShotAdvanceEnabled then
			CommonVariables.Charging = true
			if
				CommonVariables.ActuallyEquipped
				and CommonVariables.Enabled
				and CommonVariables.Charging
				and not CommonVariables.Overheated
				and not CommonVariables.HoldDown
				and not CommonVariables.Switching
				and not CommonVariables.Alting
				and CurrentVariables.Mag >= CurrentModule.AmmoCost
				and CurrentVariables.Heat < CurrentModule.MaxHeat
				and Humanoid.Health > 0
				and CanShoot()
			then
				if Module.CancelReload then
					if CommonVariables.Reloading and not CommonVariables.CanCancelReload then
						CommonVariables.CanCancelReload = true
					end
				else
					if CommonVariables.Reloading then
						return
					end
				end
				CommonVariables.Enabled = false
				SetAnimationTrack("InspectAnim", "Stop", nil, 0)
				local ChargingSound = GetCurrentModeChild("ChargingSound")
				local StartTime = os.clock()
				local StartTime2
				local Start = false
				local ChargeTime = CurrentModule.AdvancedChargingTime
				if CurrentVariables.ChargeLevelCap == 1 then
					ChargeTime = CurrentModule.Level1ChargingTime
				elseif CurrentVariables.ChargeLevelCap == 2 then
					ChargeTime = CurrentModule.Level2ChargingTime
				end
				while true do
					local DeltaTime = os.clock() - StartTime
					if DeltaTime >= CurrentModule.TimeBeforeAdvancedCharging then
						if not Start then
							Start = true
							StartTime2 = os.clock()
							SetAnimationTrack(
								"ChargingAnim",
								"Play",
								CurrentModule.ChargingAnimationSpeed,
								CurrentModule.ChargingAnimationFadeTime,
								"IsNotPlaying"
							)
							SetAnimationTrack(
								"AimChargingAnim",
								"Play",
								CurrentModule.AimChargingAnimationSpeed,
								CurrentModule.AimChargingAnimationFadeTime,
								"IsNotPlaying"
							)
							gunEvent:Fire(
								"VisualizeCharge",
								CurrentModule.ChargeEffect,
								"Begin",
								Character,
								Tool,
								HandleToFire,
								CurrentVariables.ChargeLevel,
								true
							)
						end
						local DeltaTime2 = os.clock() - StartTime2
						if CurrentVariables.ChargeLevel == 0 and DeltaTime2 >= CurrentModule.Level1ChargingTime then
							CurrentVariables.ChargeLevel = 1
							SetChargeEffect(1, CurrentModule.ChargeEffect)
						end
						if
							CurrentVariables.ChargeLevel == 1
							and DeltaTime2 >= CurrentModule.Level2ChargingTime
							and CurrentVariables.ChargeLevelCap >= 2
						then
							CurrentVariables.ChargeLevel = 2
							SetChargeEffect(2, CurrentModule.ChargeEffect)
						end
						if
							CurrentVariables.ChargeLevel == 2
							and DeltaTime2 >= CurrentModule.AdvancedChargingTime
							and CurrentVariables.ChargeLevelCap == 3
						then
							CurrentVariables.ChargeLevel = 3
							SetChargeEffect(3, CurrentModule.ChargeEffect)
						end
						local ChargePercent = math.min(DeltaTime2 / ChargeTime, 1)
						GUI.ChargeBar.Fill.BackgroundColor3 = ChargePercent < 0.5
							and Color3.new(1, ChargePercent * 2, 0)
							or Color3.new(1 - ((ChargePercent - 0.5) / 0.5), 1, 0)
						GUI.ChargeBar.Fill.Size = UDim2.new(ChargePercent, 0, 1, 0)
						if ChargingSound then
							if not ChargingSound.Playing then
								ChargingSound:Play()
							end
							if CurrentModule.ChargingSoundIncreasePitch then
								ChargingSound.PlaybackSpeed = CurrentModule.ChargingSoundPitchRange[1]
									+ (
										ChargePercent
										* (
											CurrentModule.ChargingSoundPitchRange[2]
											- CurrentModule.ChargingSoundPitchRange[1]
										)
									)
							end
						end
					end
					Thread:Wait()
					if not CommonVariables.ActuallyEquipped or not CommonVariables.Charging then
						break
					end
				end
				SetAnimationTrack("ChargingAnim", "Stop")
				SetAnimationTrack("AimChargingAnim", "Stop")
				GUI.ChargeBar.Fill.Size = UDim2.new(0, 0, 1, 0)
				if ChargingSound then
					if ChargingSound.Playing then
						ChargingSound:Stop()
					end
					if CurrentModule.ChargingSoundIncreasePitch then
						ChargingSound.PlaybackSpeed = CurrentModule.ChargingSoundPitchRange[1]
					end
				end
				if
					not CommonVariables.ActuallyEquipped or (not CurrentModule.ShouldFireBeforeCharging and not Start)
				then
					CurrentVariables.ChargeLevel = 0
					CommonVariables.Enabled = true
				end
				if Start then
					gunEvent:Fire(
						"VisualizeCharge",
						CurrentModule.ChargeEffect,
						"End",
						Character,
						Tool,
						HandleToFire,
						nil,
						true
					)
				end
				if not CurrentModule.ShouldFireBeforeCharging and not Start then
					return
				end
				if
					CommonVariables.ActuallyEquipped
					and not CommonVariables.Enabled
					and not CommonVariables.Charging
					and not CommonVariables.Overheated
					and not CommonVariables.HoldDown
					and not CommonVariables.Switching
					and not CommonVariables.Alting
					and CurrentVariables.Mag >= CurrentModule.AmmoCost
					and CurrentVariables.Heat < CurrentModule.MaxHeat
					and Humanoid.Health > 0
					and CanShoot()
				then
					local ModNames
					local TempModule = CurrentModule
					TempModule, ModNames = ApplyConditionModifiers(TempModule, "Conditions", ModNames)
					local DidShoot = false
					local Playing = false
					local AudioId = NewAudioId()
					for i = 1, (TempModule.BurstFireEnabled and AddressTableValue("BulletPerBurst", TempModule) or 1) do
						if not CommonVariables.ActuallyEquipped then
							break
						end
						if ModNames and ModNames["ConditionsInIndividualShot"] then
							ModNames["ConditionsInIndividualShot"] = nil
						end
						local TempModule2 = TempModule
						TempModule2, ModNames =
							ApplyConditionModifiers(TempModule2, "ConditionsInIndividualShot", ModNames)
						if not CanShoot() then
							break
						end
						if TempModule2.BatteryEnabled then
							if CurrentVariables.Heat >= TempModule2.MaxHeat then
								break
							end
						else
							if CurrentVariables.Mag < TempModule2.AmmoCost then
								break
							end
						end
						if not Playing then
							Playing = true
							SetFireSoundLoopEnabled(AudioId, true)
						end
						local Directions = {}
						if not TempModule2.ShotgunPump then
							Thread:Spawn(function()
								if WaitWhileEquipped(TempModule2.BulletShellDelay) then
									EjectShell(HandleToFire, TempModule2)
								end
							end)
						end
						CommonVariables.CurrentRate = CommonVariables.CurrentRate + TempModule2.SmokeTrailRateIncrement
						local Position = Get3DPosition2()
						if ModNames and ModNames["ConditionsInIndividualBullet"] then
							ModNames["ConditionsInIndividualBullet"] = nil
						end
						for ii = 1, (TempModule2.ShotgunEnabled and AddressTableValue("BulletPerShot", TempModule2) or 1) do
							local BulletId = NewBulletId()
							local TempModule3 = TempModule2
							TempModule3, ModNames =
								ApplyConditionModifiers(TempModule3, "ConditionsInIndividualBullet", ModNames, BulletId)
							local Spread = AddressTableValue("Spread", TempModule3)
							if TempModule3.MovementSpreadEnabled then
								local character = game.Players.LocalPlayer.Character
								local root = character and character:FindFirstChild("HumanoidRootPart")
								if root then
									local v = root.Velocity.Magnitude
									local mv = TempModule3.MovementVelocity
									local ms = TempModule3.MovementSpread
									if v < mv.Idle then
										Spread += ms.Idle
									elseif v < mv.Walk then
										Spread += ms.Walk
									elseif v < mv.Run then
										Spread += ms.Run
									else
										Spread += ms.Air
									end
								end
							end
							local CurrentSpread = Spread
								* 10
								* (CommonVariables.AimDown and 1 - TempModule3.ADSSpreadRedution or 1)
							local cframe = CFrame.new(
								(CurrentFirePoint and CurrentFirePoint.WorldPosition) or Head.Position,
								Position
							)
							local SpreadPattern = AddressTableValue("SpreadPattern", TempModule3)
							if AddressTableValue("ShotgunPattern", TempModule3) and #SpreadPattern > 0 then
								local X, Y = SpreadPattern[ii][1], SpreadPattern[ii][2]
								cframe = cframe
									* CFrame.Angles(
										math.rad(CurrentSpread * Y / 50),
										math.rad(CurrentSpread * X / 50),
										0
									)
							else
								cframe = cframe
									* CFrame.Angles(
										math.rad(math.random(-CurrentSpread, CurrentSpread) / 50),
										math.rad(math.random(-CurrentSpread, CurrentSpread) / 50),
										0
									)
							end
							table.insert(Directions, { cframe.LookVector, BulletId })
						end
						Fire(HandleToFire, Position, Directions, TempModule2, ModNames)
						if TempModule2.BurstFireEnabled then
							if AddressTableValue("CycleHandles", TempModule2) then
								CycleHandles()
							end
							local ST = os.clock()
							repeat
								Thread:Wait()
								if not CommonVariables.ActuallyEquipped then
									break
								end
							until (os.clock() - ST) >= AddressTableValue("BurstRate", TempModule2)
						end
						DidShoot = true
					end
					if CurrentFireAnim and CurrentFireAnim.Looped then
						SetAnimationTrack("FireAnim", "Stop")
					end
					if CurrentAimFireAnim and CurrentAimFireAnim.Looped then
						SetAnimationTrack("AimFireAnim", "Stop")
					end
					if Playing then
						Playing = false
						SetFireSoundLoopEnabled(AudioId, false)
					end
					if
						DidShoot
						and not TempModule.ShotgunPump
						and not (TempModule.BurstFireEnabled and AddressTableValue("CycleHandles", TempModule))
					then
						CycleHandles()
					end
					if
						TempModule.BatteryEnabled and CurrentVariables.Heat >= TempModule.MaxHeat
						or CurrentVariables.Mag <= 0
					then
						if CommonVariables.CurrentRate >= TempModule.MaximumRate and TempModule.SmokeTrailEnabled then
							Thread:Spawn(function()
								SmokeTrail:StopEmission()
								SmokeTrail:EmitSmokeTrail(CurrentSmokeTrailPoint, TempModule.MaximumTime)
							end)
						end
					end
					local Overheated = false
					if
						CommonVariables.ActuallyEquipped
						and TempModule.BatteryEnabled
						and CurrentVariables.Heat >= TempModule.MaxHeat
					then
						Overheated = true
						CurrentVariables.ChargeLevel = 0
						CommonVariables.Enabled = true
						Thread:Spawn(Overheat)
					end
					if not Overheated then
						if DidShoot then
							Thread:Wait(AddressTableValue("FireRate", TempModule))
							if TempModule.ShotgunPump then
								if CommonVariables.ActuallyEquipped then
									SetAnimationTrack("ShotgunPumpinAnim", "Play", CurrentShotgunPumpinAnimationSpeed)
									PlayCurrentModeSound("PumpSound")
									Thread:Spawn(function()
										local ST = os.clock()
										repeat
											Thread:Wait()
											if not CommonVariables.ActuallyEquipped then
												break
											end
										until (os.clock() - ST) >= TempModule.BulletShellDelay
										if CommonVariables.ActuallyEquipped then
											EjectShell(HandleToFire, TempModule)
										end
									end)
								end
								if
									not (TempModule.BurstFireEnabled and AddressTableValue("CycleHandles", TempModule))
								then
									CycleHandles()
								end
								Thread:Wait(TempModule.ShotgunPumpinSpeed)
							end
						end
						CurrentVariables.ChargeLevel = 0
						CommonVariables.Enabled = true
						if CommonVariables.ActuallyEquipped and Module.AutoReload and CurrentVariables.Mag <= 0 then
							Reload()
						end
					end
				end
			end
		elseif CurrentModule.HoldAndReleaseEnabled and not CurrentModule.SelectiveFireEnabled then
			CommonVariables.Charging = true
			if
				CommonVariables.ActuallyEquipped
				and CommonVariables.Enabled
				and CommonVariables.Charging
				and not CommonVariables.Overheated
				and not CommonVariables.HoldDown
				and not CommonVariables.Switching
				and not CommonVariables.Alting
				and CurrentVariables.Mag >= CurrentModule.AmmoCost
				and CurrentVariables.Heat < CurrentModule.MaxHeat
				and Humanoid.Health > 0
				and CanShoot()
			then
				if Module.CancelReload then
					if CommonVariables.Reloading and not CommonVariables.CanCancelReload then
						CommonVariables.CanCancelReload = true
					end
				else
					if CommonVariables.Reloading then
						return
					end
				end
				CommonVariables.Enabled = false
				SetAnimationTrack("InspectAnim", "Stop", nil, 0)
				local ChargingSound = GetCurrentModeChild("ChargingSound")
				local StartTime = os.clock()
				local StartTime2
				local Start = false
				local LockedOnTargets = {}
				local TargetCounts = 0
				local ScanInterval = CurrentModule.ScanRate
				while true do
					if not CurrentModule.LockOnScan then
						local DeltaTime = os.clock() - StartTime
						if DeltaTime >= CurrentModule.TimeBeforeHolding then
							if not Start then
								Start = true
								StartTime2 = os.clock()
								SetAnimationTrack(
									"ChargingAnim",
									"Play",
									CurrentModule.ChargingAnimationSpeed,
									CurrentModule.ChargingAnimationFadeTime,
									"IsNotPlaying"
								)
								SetAnimationTrack(
									"AimChargingAnim",
									"Play",
									CurrentModule.AimChargingAnimationSpeed,
									CurrentModule.AimChargingAnimationFadeTime,
									"IsNotPlaying"
								)
								gunEvent:Fire(
									"VisualizeCharge",
									CurrentModule.HoldChargeEffect,
									"Begin",
									Character,
									Tool,
									HandleToFire,
									0,
									true
								)
							end
							local DeltaTime2 = os.clock() - StartTime2
							if not CommonVariables.Charged and DeltaTime2 >= CurrentModule.HoldingTime then
								CommonVariables.Charged = true
								SetChargeEffect(3, CurrentModule.HoldChargeEffect)
							end
							local ChargePercent = math.min(DeltaTime2 / CurrentModule.HoldingTime, 1)
							GUI.ChargeBar.Fill.BackgroundColor3 = ChargePercent < 0.5
								and Color3.new(1, ChargePercent * 2, 0)
								or Color3.new(1 - ((ChargePercent - 0.5) / 0.5), 1, 0)
							GUI.ChargeBar.Fill.Size = UDim2.new(ChargePercent, 0, 1, 0)
							if ChargingSound then
								if not ChargingSound.Playing then
									ChargingSound:Play()
								end
								if CurrentModule.ChargingSoundIncreasePitch then
									ChargingSound.PlaybackSpeed = CurrentModule.ChargingSoundPitchRange[1]
										+ (
											ChargePercent
											* (
												CurrentModule.ChargingSoundPitchRange[2]
												- CurrentModule.ChargingSoundPitchRange[1]
											)
										)
								end
							end
						end
					else
						CommonVariables.Charged = true
						local DeltaTime = os.clock() - StartTime
						if DeltaTime >= CurrentModule.TimeBeforeScan then
							if not Start then
								Start = true
								StartTime2 = os.clock()
								CurrentModule.OnScannerToggle(CommonVariables.Radar, CurrentModule.MaximumTargets, true)
							end
							local DeltaTime2 = os.clock() - StartTime2
							if DeltaTime2 >= ScanInterval then
								StartTime2 = os.clock()
								local TargetEntity, TargetHumanoid, TargetTorso, AlreadyLocked =
									FindNearestEntity(LockedOnTargets)
								if TargetEntity and TargetHumanoid and TargetTorso then
									if TargetCounts < CurrentModule.MaximumTargets then
										TargetCounts = TargetCounts + 1
										ScanInterval = AlreadyLocked and CurrentModule.ScanRateOnLockedTarget
											or CurrentModule.ScanRate
										CurrentModule.OnScannerUpdate(
											CommonVariables.Radar,
											TargetCounts,
											CurrentModule.MaximumTargets,
											AlreadyLocked,
											true
										)
										local TMC = Scanners.Markers[CurrentModule.Marker]:Clone()
										TMC.Name = "TargetMarker"
										TMC.Parent = GUI
										TMC.Adornee = TargetTorso
										TMC.Enabled = true
										CurrentModule.OnTrackingTarget(TMC)
										table.insert(LockedOnTargets, {
											TargetEntity = TargetEntity,
											TargetTorso = TargetTorso,
											TargetMarker = TMC,
										})
									end
								end
							end
							if CurrentModule.RemoveTargetsWhenOutbound then
								for i = #LockedOnTargets, 1, -1 do
									if LockedOnTargets[i].TargetEntity and LockedOnTargets[i].TargetTorso then
										if not CheckPartInScanner(LockedOnTargets[i].TargetTorso) then
											TargetCounts = TargetCounts - 1
											CurrentModule.OnScannerUpdate(
												CommonVariables.Radar,
												TargetCounts,
												CurrentModule.MaximumTargets
											)
											if LockedOnTargets[i].TargetMarker then
												LockedOnTargets[i].TargetMarker:Destroy()
											end
											table.remove(LockedOnTargets, i)
										end
									else
										TargetCounts = TargetCounts - 1
										CurrentModule.OnScannerUpdate(
											CommonVariables.Radar,
											TargetCounts,
											CurrentModule.MaximumTargets
										)
										if LockedOnTargets[i].TargetMarker then
											LockedOnTargets[i].TargetMarker:Destroy()
										end
										table.remove(LockedOnTargets, i)
									end
								end
							end
						end
					end
					Thread:Wait()
					if not CommonVariables.ActuallyEquipped or not CommonVariables.Charging then
						break
					end
				end
				SetAnimationTrack("ChargingAnim", "Stop")
				SetAnimationTrack("AimChargingAnim", "Stop")
				if not CurrentModule.LockOnScan then
					GUI.ChargeBar.Fill.Size = UDim2.new(0, 0, 1, 0)
					if ChargingSound then
						if ChargingSound.Playing then
							ChargingSound:Stop()
						end
						if CurrentModule.ChargingSoundIncreasePitch then
							ChargingSound.PlaybackSpeed = CurrentModule.ChargingSoundPitchRange[1]
						end
					end
					if Start then
						gunEvent:Fire(
							"VisualizeCharge",
							CurrentModule.HoldChargeEffect,
							"End",
							Character,
							Tool,
							HandleToFire,
							nil,
							true
						)
					end
				else
					if CommonVariables.Radar then
						CurrentModule.OnScannerToggle(CommonVariables.Radar, CurrentModule.MaximumTargets, false)
					end
					for i, v in pairs(LockedOnTargets) do
						if v.TargetMarker then
							v.TargetMarker:Destroy()
						end
					end
				end
				if
					not CommonVariables.ActuallyEquipped
					or (CurrentModule.ShouldFireWhenTheresTarget and #LockedOnTargets <= 0)
				then
					CommonVariables.Charged = false
					CommonVariables.Enabled = true
				end
				if CurrentModule.ShouldFireWhenTheresTarget and #LockedOnTargets <= 0 then
					return
				end
				if
					CommonVariables.ActuallyEquipped
					and not CommonVariables.Enabled
					and not CommonVariables.Charging
					and CommonVariables.Charged
					and not CommonVariables.Overheated
					and not CommonVariables.HoldDown
					and not CommonVariables.Switching
					and not CommonVariables.Alting
					and CurrentVariables.Mag >= CurrentModule.AmmoCost
					and CurrentVariables.Heat < CurrentModule.MaxHeat
					and Humanoid.Health > 0
					and CanShoot()
				then
					CommonVariables.Charged = false
					local ModNames
					local TempModule = CurrentModule
					TempModule, ModNames = ApplyConditionModifiers(TempModule, "Conditions", ModNames)
					local DidShoot = false
					local Playing = false
					local AudioId = NewAudioId()
					for i = 1, TempModule.LockOnScan and (TargetCounts > 0 and TargetCounts or 1) or (TempModule.BurstFireEnabled and TempModule.BulletPerBurst or 1) do
						if not CommonVariables.ActuallyEquipped then
							break
						end
						if ModNames and ModNames["ConditionsInIndividualShot"] then
							ModNames["ConditionsInIndividualShot"] = nil
						end
						local TempModule2 = TempModule
						TempModule2, ModNames =
							ApplyConditionModifiers(TempModule2, "ConditionsInIndividualShot", ModNames)
						if not CanShoot() then
							break
						end
						if TempModule2.BatteryEnabled then
							if CurrentVariables.Heat >= TempModule2.MaxHeat then
								break
							end
						else
							if CurrentVariables.Mag < TempModule2.AmmoCost then
								break
							end
						end
						if not Playing then
							Playing = true
							SetFireSoundLoopEnabled(AudioId, true)
						end
						local FirstShot = TempModule2.LockOnScan and TempModule2.InstaBurst and i == 1 or nil
						local Directions = {}
						if not TempModule2.ShotgunPump then
							Thread:Spawn(function()
								local CanEject = not (TempModule2.LockOnScan and TempModule2.InstaBurst) or (i == 1)
								if not CanEject then
									return
								end
								if WaitWhileEquipped(TempModule2.BulletShellDelay) then
									EjectShell(HandleToFire, TempModule2)
								end
							end)
						end
						CommonVariables.CurrentRate = CommonVariables.CurrentRate + TempModule2.SmokeTrailRateIncrement
						local Position = (TempModule2.LockOnScan and #LockedOnTargets > 0)
							and (LockedOnTargets[i] and LockedOnTargets[i].TargetTorso and LockedOnTargets[i].TargetTorso.Position or Get3DPosition2())
							or Get3DPosition2()
						if ModNames and ModNames["ConditionsInIndividualBullet"] then
							ModNames["ConditionsInIndividualBullet"] = nil
						end
						for ii = 1, (TempModule2.ShotgunEnabled and TempModule2.BulletPerShot or 1) do
							local BulletId = NewBulletId()
							local TempModule3 = TempModule2
							TempModule3, ModNames =
								ApplyConditionModifiers(TempModule3, "ConditionsInIndividualBullet", ModNames, BulletId)
							local Spread = TempModule3.Spread
							if TempModule3.MovementSpreadEnabled then
								local character = game.Players.LocalPlayer.Character
								local root = character and character:FindFirstChild("HumanoidRootPart")
								if root then
									local v = root.Velocity.Magnitude
									local mv = TempModule3.MovementVelocity
									local ms = TempModule3.MovementSpread
									if v < mv.Idle then
										Spread += ms.Idle
									elseif v < mv.Walk then
										Spread += ms.Walk
									elseif v < mv.Run then
										Spread += ms.Run
									else
										Spread += ms.Air
									end
								end
							end
							Spread = Spread * 10 * (CommonVariables.AimDown and 1 - TempModule3.ADSSpreadRedution or 1)
							local cframe = CFrame.new(
								(CurrentFirePoint and CurrentFirePoint.WorldPosition) or Head.Position,
								Position
							)
							if TempModule3.ShotgunPattern and #TempModule3.SpreadPattern > 0 then
								local X, Y = TempModule3.SpreadPattern[ii][1], TempModule3.SpreadPattern[ii][2]
								cframe = cframe * CFrame.Angles(math.rad(Spread * Y / 50), math.rad(Spread * X / 50), 0)
							else
								cframe = cframe
									* CFrame.Angles(
										math.rad(math.random(-Spread, Spread) / 50),
										math.rad(math.random(-Spread, Spread) / 50),
										0
									)
							end
							table.insert(Directions, { cframe.LookVector, BulletId })
						end
						Fire(
							HandleToFire,
							Position,
							Directions,
							TempModule2,
							ModNames,
							(TempModule2.LockOnScan and #LockedOnTargets > 0)
								and (LockedOnTargets[i] and LockedOnTargets[i].TargetEntity or nil)
								or nil,
							FirstShot
						)
						if TempModule2.LockOnScan then
							local CanCycle = not TempModule2.InstaBurst or not TempModule2.TriggerOnce or (i == 1)
							if TempModule2.CycleHandles and CanCycle then
								CycleHandles()
							end
							if not TempModule2.InstaBurst then
								local ST = os.clock()
								repeat
									Thread:Wait()
									if not CommonVariables.ActuallyEquipped then
										break
									end
								until (os.clock() - ST) >= TempModule2.LockOnScanBurstRate
							end
						else
							if TempModule2.BurstFireEnabled then
								if TempModule2.CycleHandles then
									CycleHandles()
								end
								local ST = os.clock()
								repeat
									Thread:Wait()
									if not CommonVariables.ActuallyEquipped then
										break
									end
								until (os.clock() - ST) >= TempModule2.BurstRate
							end
						end
						DidShoot = true
					end
					if CurrentFireAnim and CurrentFireAnim.Looped then
						SetAnimationTrack("FireAnim", "Stop")
					end
					if CurrentAimFireAnim and CurrentAimFireAnim.Looped then
						SetAnimationTrack("AimFireAnim", "Stop")
					end
					if Playing then
						Playing = false
						SetFireSoundLoopEnabled(AudioId, false)
					end
					if
						DidShoot
						and not TempModule.ShotgunPump
						and not ((TempModule.LockOnScan or TempModule.BurstFireEnabled) and TempModule.CycleHandles)
					then
						CycleHandles()
					end
					if
						TempModule.BatteryEnabled and CurrentVariables.Heat >= TempModule.MaxHeat
						or CurrentVariables.Mag <= 0
					then
						if CommonVariables.CurrentRate >= TempModule.MaximumRate and TempModule.SmokeTrailEnabled then
							Thread:Spawn(function()
								SmokeTrail:StopEmission()
								SmokeTrail:EmitSmokeTrail(CurrentSmokeTrailPoint, TempModule.MaximumTime)
							end)
						end
					end
					local Overheated = false
					if
						CommonVariables.ActuallyEquipped
						and TempModule.BatteryEnabled
						and CurrentVariables.Heat >= TempModule.MaxHeat
					then
						Overheated = true
						CommonVariables.Enabled = true
						Thread:Spawn(Overheat)
					end
					if not Overheated then
						if DidShoot then
							Thread:Wait(TempModule.FireRate)
							if TempModule.ShotgunPump then
								if CommonVariables.ActuallyEquipped then
									SetAnimationTrack("ShotgunPumpinAnim", "Play", CurrentShotgunPumpinAnimationSpeed)
									PlayCurrentModeSound("PumpSound")
									Thread:Spawn(function()
										local ST = os.clock()
										repeat
											Thread:Wait()
											if not CommonVariables.ActuallyEquipped then
												break
											end
										until (os.clock() - ST) >= TempModule.BulletShellDelay
										if CommonVariables.ActuallyEquipped then
											EjectShell(HandleToFire, TempModule)
										end
									end)
								end
								if
									not (
										(TempModule.LockOnScan or TempModule.BurstFireEnabled)
											and TempModule.CycleHandles
									)
								then
									CycleHandles()
								end
								Thread:Wait(TempModule.ShotgunPumpinSpeed)
							end
						end
						CommonVariables.Enabled = true
						if CommonVariables.ActuallyEquipped and Module.AutoReload and CurrentVariables.Mag <= 0 then
							Reload()
						end
					end
				end
			end
		else
			CommonVariables.Down = true
			if
				CommonVariables.ActuallyEquipped
				and CommonVariables.Enabled
				and CommonVariables.Down
				and not CommonVariables.Overheated
				and not CommonVariables.HoldDown
				and not CommonVariables.Switching
				and not CommonVariables.Alting
				and CurrentVariables.Mag >= CurrentModule.AmmoCost
				and CurrentVariables.Heat < CurrentModule.MaxHeat
				and Humanoid.Health > 0
				and CanShoot()
			then
				if Module.CancelReload then
					if CommonVariables.Reloading and not CommonVariables.CanCancelReload then
						CommonVariables.CanCancelReload = true
					end
				else
					if CommonVariables.Reloading then
						return
					end
				end
				CommonVariables.Enabled = false
				SetAnimationTrack("InspectAnim", "Stop", nil, 0)
				if CurrentModule.MinigunEnabled then
					SetAnimationTrack("MinigunRevUpAnim", "Play", CurrentModule.MinigunRevUpAnimationSpeed)
					if CommonVariables.ActuallyEquipped then
						PlayCurrentModeSound("WindUp")
					end
					local Interrupted = false
					local StartTime = os.clock()
					repeat
						Thread:Wait()
						if not CommonVariables.ActuallyEquipped then
							Interrupted = true
							break
						end
					until (os.clock() - StartTime) >= CurrentModule.DelayBeforeFiring
					if Interrupted then
						SetAnimationTrack("MinigunRevUpAnim", "Stop")
						StopCurrentModeSound("WindUp")
					end
				end
				CommonVariables.CurrentFireRate = CurrentModule.FireRate
				local DidShoot = false
				local Playing = false
				local AudioId = NewAudioId()
				while
					CommonVariables.ActuallyEquipped
					and not CommonVariables.Overheated
					and CommonVariables.Down
					and not CommonVariables.HoldDown
					and not CommonVariables.Switching
					and not CommonVariables.Alting
					and CurrentVariables.Mag >= CurrentModule.AmmoCost
					and CurrentVariables.Heat < CurrentModule.MaxHeat
					and Humanoid.Health > 0
					and CanShoot()
				do
					local IsChargedShot = false
					if CurrentModule.ChargedShotEnabled then
						if CommonVariables.ActuallyEquipped then
							PlayCurrentModeSound("ChargeSound")
						end
						local Interrupted = false
						local StartTime = os.clock()
						repeat
							Thread:Wait()
							if not CommonVariables.ActuallyEquipped then
								Interrupted = true
								break
							end
						until (os.clock() - StartTime) >= CurrentModule.ChargingTime
						if Interrupted then
							StopCurrentModeSound("ChargeSound")
						else
							IsChargedShot = true
						end
						if not IsChargedShot then
							break
						end
					end
					local ModNames
					local TempModule = CurrentModule
					TempModule, ModNames = ApplyConditionModifiers(TempModule, "Conditions", ModNames)
					for i = 1, ((TempModule.SelectiveFireEnabled and (CurrentVariables.FireModes[CurrentVariables.FireMode] ~= true and CurrentVariables.FireModes[CurrentVariables.FireMode] or 1)) or (TempModule.BurstFireEnabled and TempModule.BulletPerBurst) or 1) do
						if not CommonVariables.ActuallyEquipped then
							break
						end
						if ModNames and ModNames["ConditionsInIndividualShot"] then
							ModNames["ConditionsInIndividualShot"] = nil
						end
						local TempModule2 = TempModule
						TempModule2, ModNames =
							ApplyConditionModifiers(TempModule2, "ConditionsInIndividualShot", ModNames)
						if not CanShoot() then
							break
						end
						if TempModule2.BatteryEnabled then
							if CurrentVariables.Heat >= TempModule2.MaxHeat then
								break
							end
						else
							if CurrentVariables.Mag < TempModule2.AmmoCost then
								break
							end
						end
						if not Playing then
							Playing = true
							SetFireSoundLoopEnabled(AudioId, true)
						end
						local Directions = {}
						if not TempModule2.ShotgunPump then
							Thread:Spawn(function()
								if WaitWhileEquipped(TempModule2.BulletShellDelay) then
									EjectShell(HandleToFire, TempModule2)
								end
							end)
						end
						CommonVariables.CurrentRate = CommonVariables.CurrentRate + TempModule2.SmokeTrailRateIncrement
						local Position = Get3DPosition2()
						if ModNames and ModNames["ConditionsInIndividualBullet"] then
							ModNames["ConditionsInIndividualBullet"] = nil
						end
						for ii = 1, (TempModule2.ShotgunEnabled and TempModule2.BulletPerShot or 1) do
							local BulletId = NewBulletId()
							local TempModule3 = TempModule2
							TempModule3, ModNames =
								ApplyConditionModifiers(TempModule3, "ConditionsInIndividualBullet", ModNames, BulletId)
							local Spread = TempModule3.Spread
							if TempModule3.MovementSpreadEnabled then
								local character = game.Players.LocalPlayer.Character
								local root = character and character:FindFirstChild("HumanoidRootPart")
								if root then
									local v = root.Velocity.Magnitude
									local mv = TempModule3.MovementVelocity
									local ms = TempModule3.MovementSpread
									if v < mv.Idle then
										Spread += ms.Idle
									elseif v < mv.Walk then
										Spread += ms.Walk
									elseif v < mv.Run then
										Spread += ms.Run
									else
										Spread += ms.Air
									end
								end
							end
							Spread = Spread * 10 * (CommonVariables.AimDown and 1 - TempModule3.ADSSpreadRedution or 1)
							local cframe = CFrame.new(
								(CurrentFirePoint and CurrentFirePoint.WorldPosition) or Head.Position,
								Position
							)
							if TempModule3.ShotgunPattern and #TempModule3.SpreadPattern > 0 then
								local X, Y = TempModule3.SpreadPattern[ii][1], TempModule3.SpreadPattern[ii][2]
								cframe = cframe * CFrame.Angles(math.rad(Spread * Y / 50), math.rad(Spread * X / 50), 0)
							else
								cframe = cframe
									* CFrame.Angles(
										math.rad(math.random(-Spread, Spread) / 50),
										math.rad(math.random(-Spread, Spread) / 50),
										0
									)
							end
							table.insert(Directions, { cframe.LookVector, BulletId })
						end
						Fire(HandleToFire, Position, Directions, TempModule2, ModNames)
						if TempModule2.BurstFireEnabled or TempModule2.SelectiveFireEnabled then
							if TempModule2.CycleHandles then
								CycleHandles()
							end
							local ST = os.clock()
							repeat
								Thread:Wait()
								if not CommonVariables.ActuallyEquipped then
									break
								end
							until (os.clock() - ST)
								>= (
									TempModule2.SelectiveFireEnabled
									and TempModule2.BurstRates[CurrentVariables.FireMode]
									or TempModule2.BurstRate
								)
						end
						DidShoot = true
					end
					if
						DidShoot
						and not TempModule.ShotgunPump
						and not (
							(TempModule.SelectiveFireEnabled or TempModule.BurstFireEnabled) and TempModule.CycleHandles
						)
					then
						CycleHandles()
					end
					if
						TempModule.BatteryEnabled and CurrentVariables.Heat >= TempModule.MaxHeat
						or CurrentVariables.Mag <= 0
					then
						if CommonVariables.CurrentRate >= TempModule.MaximumRate and TempModule.SmokeTrailEnabled then
							Thread:Spawn(function()
								SmokeTrail:StopEmission()
								SmokeTrail:EmitSmokeTrail(CurrentSmokeTrailPoint, TempModule.MaximumTime)
							end)
						end
					end
					if TempModule.BatteryEnabled and CurrentVariables.Heat >= TempModule.MaxHeat then
						break
					end
					if DidShoot then
						Thread:Wait(
							TempModule.SelectiveFireEnabled and TempModule.FireRates[CurrentVariables.FireMode]
								or (
									(TempModule.Auto and TempModule.GainFireRateAsAutoFire)
									and CommonVariables.CurrentFireRate
									or TempModule.FireRate
								)
						)
						if TempModule.SelectiveFireEnabled then
							if CurrentVariables.FireModes[CurrentVariables.FireMode] ~= true then
								break
							end
						else
							if not TempModule.Auto then
								break
							else
								if TempModule.GainFireRateAsAutoFire then
									CommonVariables.CurrentFireRate = math.clamp(
										CommonVariables.CurrentFireRate - TempModule.FireRateIncrement,
										TempModule.MaximumFireRate,
										TempModule.FireRate
									)
								end
							end
						end
					else
						break
					end
				end
				if CurrentFireAnim and CurrentFireAnim.Looped then
					SetAnimationTrack("FireAnim", "Stop")
				end
				if CurrentAimFireAnim and CurrentAimFireAnim.Looped then
					SetAnimationTrack("AimFireAnim", "Stop")
				end
				if Playing then
					Playing = false
					SetFireSoundLoopEnabled(AudioId, false)
				end
				if CurrentModule.MinigunEnabled and CommonVariables.ActuallyEquipped then
					PlayCurrentModeSound("WindDown")
				end
				local Overheated = false
				if
					CommonVariables.ActuallyEquipped
					and CurrentModule.BatteryEnabled
					and CurrentVariables.Heat >= CurrentModule.MaxHeat
				then
					Overheated = true
					CommonVariables.Enabled = true
					Thread:Spawn(Overheat)
				end
				if not Overheated then
					if CurrentModule.MinigunEnabled then
						if CommonVariables.ActuallyEquipped then
							SetAnimationTrack("MinigunRevDownAnim", "Play", CurrentModule.MinigunRevDownAnimationSpeed)
						end
						SetAnimationTrack("MinigunRevUpAnim", "Stop")
						Thread:Wait(CurrentModule.DelayAfterFiring)
					end
					if DidShoot then
						if CurrentModule.ShotgunPump then
							if CommonVariables.ActuallyEquipped then
								SetAnimationTrack("ShotgunPumpinAnim", "Play", CurrentShotgunPumpinAnimationSpeed)
								PlayCurrentModeSound("PumpSound")
								Thread:Spawn(function()
									local ST = os.clock()
									repeat
										Thread:Wait()
										if not CommonVariables.ActuallyEquipped then
											break
										end
									until (os.clock() - ST) >= CurrentModule.BulletShellDelay
									if CommonVariables.ActuallyEquipped then
										EjectShell(HandleToFire, CurrentModule)
									end
								end)
							end
							if not (CurrentModule.BurstFireEnabled and CurrentModule.CycleHandles) then
								CycleHandles()
							end
							Thread:Wait(CurrentModule.ShotgunPumpinSpeed)
						end
					end
					CommonVariables.Enabled = true
					if CommonVariables.ActuallyEquipped and Module.AutoReload and CurrentVariables.Mag <= 0 then
						Reload()
					end
				end
			end
		end
	end
end

function OnStoppingFiring()
	CommonVariables.Down = false
	if CurrentModule.ChargedShotAdvanceEnabled or CurrentModule.HoldAndReleaseEnabled then
		CommonVariables.Charging = false
	end
	if CurrentModule.HoldAndReleaseEnabled and not CommonVariables.Charged then
		CommonVariables.Enabled = true
	end
end

function OnMeleeHit(Hit, RegionalHitbox, RaycastHitboxTable)
	if Hit.Name == "_glass" and CurrentModule.MeleeCanBreakGlass then
		if not CommonVariables.AlreadyHit then
			CommonVariables.AlreadyHit = true
			ShatterGlass:FireServer(
				Hit,
				RegionalHitbox and Hit.Position or RaycastHitboxTable[2],
				(Hit.Position - HumanoidRootPart.Position).Unit
			)
			if not CurrentModule.TriggerEffectOnce then
				Thread:Delay(CurrentModule.EffectDelay, function()
					CommonVariables.AlreadyHit = false
				end)
			end
		end
	else
		local Target = Hit:FindFirstAncestorOfClass("Model")
		local CanBlock
		local TargetHumanoid
		local TargetTorso
		local TargetTorso2
		if Target then
			CanBlock = Target:FindFirstChild("CanBlock")
			TargetHumanoid = Target:FindFirstChildOfClass("Humanoid")
			TargetTorso = Target:FindFirstChild("HumanoidRootPart") or Target:FindFirstChild("Head")
			TargetTorso2 = Target:FindFirstChild("HumanoidRootPart") or Target:FindFirstChild("Torso")
		end
		local Misc = {
			Tool = Tool,
			ModuleName = CurrentModule.ModuleName,
			Direction = ((TargetTorso and TargetTorso.Position or Hit.Position) - HumanoidRootPart.Position).Unit,
			Blocked = false,
		}
		local ShouldBlock = false
		local TEAM = Character:FindFirstChild("TEAM")
		if CanBlock and CurrentModule.BlockMelee then
			if TEAM and CanBlock:FindFirstChild("TEAM") then
				if CanBlock.TEAM.Value ~= TEAM.Value then
					ShouldBlock = true
					Misc.Blocked = true
				end
			else
				ShouldBlock = true
				Misc.Blocked = true
			end
		end
		local Pos = RegionalHitbox and Hit.Position or RaycastHitboxTable[2]
		local Normal = RegionalHitbox and Vector3.new(0, 0, 0) or RaycastHitboxTable[3]
		local Material = RegionalHitbox and Hit.Material or RaycastHitboxTable[4]
		if TargetHumanoid and TargetTorso then
			Pos = RegionalHitbox and TargetTorso2.Position or RaycastHitboxTable[2]
			if ShouldBlock then
				if TrackOnce(CommonVariables.BlockedModelSet, Target) then
					table.insert(CommonVariables.BlockedModels, Target)
					if not RegionalHitbox and CurrentModule.BlockDelay ~= math.huge then
						Thread:Delay(CurrentModule.BlockDelay, function()
							Untrack(CommonVariables.BlockedModelSet, Target)
							local i = table.find(CommonVariables.BlockedModels, Target)
							if i then
								table.remove(CommonVariables.BlockedModels, i)
							end
						end)
					end
					gunEvent:Fire("VisualizeHitEffect", "Normal", Hit, Pos, Normal, Material, Misc, true)
				end
				return
			end
			if TargetHumanoid.Health > 0 and DamageModule.CanDamage(Target, Character, CurrentModule.FriendlyFire) then
				if not CommonVariables.BlockedModelSet[Target] and TrackMeleeHumanoid(TargetHumanoid) then
					table.insert(CommonVariables.MeleeHitHumanoids, TargetHumanoid)
					if not RegionalHitbox and CurrentModule.HitIgnoreDelay ~= math.huge then
						Thread:Delay(CurrentModule.HitIgnoreDelay, function()
							UntrackMeleeHumanoid(TargetHumanoid)
							local i = table.find(CommonVariables.MeleeHitHumanoids, TargetHumanoid)
							if i then
								table.remove(CommonVariables.MeleeHitHumanoids, i)
							end
						end)
					end
					gunEvent:Fire("VisualizeHitEffect", "Blood", Hit, Pos, Normal, Material, Misc, true)
					Thread:Spawn(function()
						InflictTarget:FireServer("GunMelee", Tool, Hit, Hit.Size, CurrentModule.ModuleName)
					end)
					MarkHit(CurrentModule, Hit.Name == "Head" and CurrentModule.MeleeHeadshotHitmarker)
				end
			end
		else
			if ShouldBlock then
				if TrackOnce(CommonVariables.BlockedModelSet, Target) then
					table.insert(CommonVariables.BlockedModels, Target)
					if not RegionalHitbox and CurrentModule.BlockDelay ~= math.huge then
						Thread:Delay(CurrentModule.BlockDelay, function()
							Untrack(CommonVariables.BlockedModelSet, Target)
							local i = table.find(CommonVariables.BlockedModels, Target)
							if i then
								table.remove(CommonVariables.BlockedModels, i)
							end
						end)
					end
					gunEvent:Fire("VisualizeHitEffect", "Normal", Hit, Pos, Normal, Material, Misc, true)
				end
			else
				if not CommonVariables.AlreadyHit then
					CommonVariables.AlreadyHit = true
					gunEvent:Fire("VisualizeHitEffect", "Normal", Hit, Pos, Normal, Material, Misc, true)
					if not CurrentModule.TriggerEffectOnce then
						Thread:Delay(CurrentModule.EffectDelay, function()
							CommonVariables.AlreadyHit = false
						end)
					end
				end
			end
		end
	end
end

function OnMeleeAttacking()
	if CurrentModule.MeleeAttackEnabled then
		if CurrentAnimTable.MeleeAttackAnim and CurrentAnimTable.MeleeAttackAnim.Length > 0 then
			local Connection
			local Connection2
			if
				CommonVariables.ActuallyEquipped
				and CommonVariables.Enabled
				and not CommonVariables.Overheated
				and not CommonVariables.Switching
				and not CommonVariables.Alting
				and not CommonVariables.AimDown
				and Humanoid.Health > 0
				and CanShoot()
			then
				if Module.CancelReload then
					if CommonVariables.Reloading and not CommonVariables.CanCancelReload then
						CommonVariables.CanCancelReload = true
					end
				else
					if CommonVariables.Reloading then
						return
					end
				end
				CommonVariables.Enabled = false
				SetAnimationTrack("InspectAnim", "Stop", nil, 0)
				SetAnimationTrack("MeleeAttackAnim", "Play", CurrentModule.MeleeAttackAnimationSpeed, 0.05)
				if CommonVariables.ActuallyEquipped then
					PlayCurrentModeSound("MeleeSwingSound")
				end
				Connection = CurrentAnimTable.MeleeAttackAnim
					:GetMarkerReachedSignal("MeleeDamageSequence")
					:Connect(function(ParamString)
						table.clear(CommonVariables.BlockedModels)
						table.clear(CommonVariables.BlockedModelSet)
						ClearMeleeTracking()
						if CurrentModule.HitboxType == "RotatedRegion" then
							local RH = Instance.new("Part")
							RH.CanCollide = false
							RH.CastShadow = false
							RH.Massless = true
							RH.Transparency = 1
							RH.Material = Enum.Material.SmoothPlastic
							RH.Shape = CurrentModule.HitboxShape
							RH.Size = CurrentModule.HitboxSize
							RH.Color = Color3.new(1, 0, 0)
							RH.CFrame = HumanoidRootPart.CFrame * CurrentModule.HitboxCFrame
							RH.Parent = Camera
							local W = Instance.new("WeldConstraint")
							W.Part0 = RH
							W.Part1 = HumanoidRootPart
							W.Parent = RH
							local Reg = RotatedRegion3.new(RH.CFrame, RH.Size)
							for _, v in
								pairs(Reg:FindPartsInRegion3WithIgnoreList(IgnoreList, CurrentModule.MaxPartsInRegion))
							do
								if v and v.Parent ~= nil then
									OnMeleeHit(v, RH, nil)
								end
							end
							Debris:AddItem(RH, 0.2)
						else
							if CurrentModule.TriggerEffectOnce then
								CommonVariables.AlreadyHit = false
							end
							local HBI = GetInstanceFromAncestor(CurrentModule.RaycastHitboxInstances[1])
							local HBI2 = CurrentModule.RaycastHitboxInstances[2]
							and GetInstanceFromAncestor(CurrentModule.RaycastHitboxInstances[2])
							or nil
							if HBI and HBI:FindFirstChild("DamagePoint", true) then
								if not CommonVariables.Hitbox then
									CommonVariables.Hitbox = RaycastHitbox.new(HBI)
									CommonVariables.Hitbox.RaycastParams = RayParams
									CommonVariables.Hitbox.DetectionMode = RaycastHitbox.DetectionMode.PartMode
									CommonVariables.Hitbox.OnHit:Connect(function(part, humanoid, raycastResult)
										if part and part.Parent ~= nil then
											OnMeleeHit(part, nil, {
												raycastResult.Instance,
												raycastResult.Position,
												raycastResult.Normal,
												raycastResult.Material,
											})
										end
									end)
									CommonVariables.Hitbox:HitStart()
								end
							end
							if HBI2 and HBI2:FindFirstChild("DamagePoint", true) then
								if not CommonVariables.Hitbox2 then
									CommonVariables.Hitbox2 = RaycastHitbox.new(HBI2)
									CommonVariables.Hitbox2.RaycastParams = RayParams
									CommonVariables.Hitbox2.DetectionMode = RaycastHitbox.DetectionMode.PartMode
									CommonVariables.Hitbox2.OnHit:Connect(function(part, humanoid, raycastResult)
										if part and part.Parent ~= nil then
											OnMeleeHit(part, nil, {
												raycastResult.Instance,
												raycastResult.Position,
												raycastResult.Normal,
												raycastResult.Material,
											})
										end
									end)
									CommonVariables.Hitbox2:HitStart()
								end
							end
						end
						if Connection then
							Connection:Disconnect()
							Connection = nil
						end
					end)
				Connection2 = CurrentAnimTable.MeleeAttackAnim
					:GetMarkerReachedSignal("MeleeDamageEndSequence")
					:Connect(function(ParamString)
						if CommonVariables.Hitbox then
							CommonVariables.Hitbox:HitStop()
							CommonVariables.Hitbox:Destroy()
							CommonVariables.Hitbox = nil
						end
						if CommonVariables.Hitbox2 then
							CommonVariables.Hitbox2:HitStop()
							CommonVariables.Hitbox2:Destroy()
							CommonVariables.Hitbox2 = nil
						end
						if Connection2 then
							Connection2:Disconnect()
							Connection2 = nil
						end
					end)
				CurrentAnimTable.MeleeAttackAnim.Stopped:Wait()
				if CommonVariables.Hitbox then
					CommonVariables.Hitbox:HitStop()
					CommonVariables.Hitbox:Destroy()
					CommonVariables.Hitbox = nil
				end
				if CommonVariables.Hitbox2 then
					CommonVariables.Hitbox2:HitStop()
					CommonVariables.Hitbox2:Destroy()
					CommonVariables.Hitbox2 = nil
				end
				CommonVariables.Enabled = true
			end
		end
	end
end

function OnUnequipping(Remove)
	CommonVariables.Equipped = false
	CommonVariables.ActuallyEquipped = false
	CommonVariables.Down = false
	CommonVariables.HoldDown = false
	GuiUpdateQueued = false
	HardHideMobileControls()

	UserInputService.MouseIconEnabled = true
	Mouse.Icon = ""
	if Module.CustomGripEnabled and not Tool.RequiresHandle then
		SetCustomGrip(false)
	end
	if Module.DualWeldEnabled and not Module.CustomGripEnabled and Tool.RequiresHandle then
		if CommonVariables.Grip2 then
			CommonVariables.Grip2:Destroy()
			CommonVariables.Grip2 = nil
		end
	end
	if CurrentModule.ChargedShotAdvanceEnabled then
		CommonVariables.Charging = false
	end
	if CurrentModule.HoldAndReleaseEnabled then
		CommonVariables.Charged = false
	end
	HardHideMobileControls()
	GUI.Parent = script
	RunService:UnbindFromRenderStep(BindToStepName)
	RemoveStuff(true)
	if CurrentModule.BatteryEnabled then
		gunEvent:Fire("VisualizeOverheat", CurrentModule.OverheatEffect, "End", Character, Tool, HandleToFire, true)
	end
	if Remove then
		if CurrentModule.LaserBeam then
			if CurrentMuzzlePoint then
				VisibleMuzz(CurrentMuzzlePoint, false)
				VisibleMuzzle:FireServer(CurrentMuzzlePoint, false)
			end
			gunEvent:Fire(
				"RemoveBeam",
				GUID,
				Tool,
				CurrentModule.ModuleName,
				BeamTable,
				CommonVariables.LaserTrail,
				CommonVariables.BoltSegments,
				CrosshairPointAttachment
			)
		end
	end
	SetADS(true)
	CommonVariables.RestoreADSCameraMode()
end

-- ============================================================
-- MOBILE / CONSOLE BUTTON CONNECTIONS
-- ============================================================
MobileButtons.AimButton.MouseButton1Click:Connect(SetADS)
MobileButtons.HoldDownButton.MouseButton1Click:Connect(OnHoldingDown)
MobileButtons.InspectButton.MouseButton1Click:Connect(OnInspecting)
MobileButtons.SwitchButton.MouseButton1Click:Connect(OnSwitching)
MobileButtons.ReloadButton.MouseButton1Click:Connect(Reload)
MobileButtons.FireButton.MouseButton1Down:Connect(OnFiring)
MobileButtons.FireButton.MouseButton1Up:Connect(OnStoppingFiring)
MobileButtons.SubFireButton.MouseButton1Down:Connect(OnFiring)
MobileButtons.SubFireButton.MouseButton1Up:Connect(OnStoppingFiring)
MobileButtons.MeleeButton.MouseButton1Click:Connect(OnMeleeAttacking)
MobileButtons.AltButton.MouseButton1Click:Connect(OnAlting)

-- ============================================================
-- KEYBOARD & MOUSE INPUT
-- ============================================================
UserInputService.InputBegan:Connect(function(Input, GameProcessed)
	local IsController = Input.UserInputType == Enum.UserInputType.Gamepad1
	if GameProcessed and not IsController then
		return
	end

	local InputType
	if Input.UserInputType == Enum.UserInputType.Keyboard then
		InputType = "Keyboard"
	elseif IsController then
		InputType = "Controller"
	end

	if not IsConsoleOrTouch() then
		-- Mouse + keyboard
		local CanADS = (Camera.Focus.Position - Camera.CFrame.Position).Magnitude <= 1
		if Module.ThirdPersonADS then
			CanADS = CanADS or (UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter)
		end

		if Input.UserInputType == Enum.UserInputType.MouseButton1 then
			OnFiring()
		elseif Input.UserInputType == Enum.UserInputType.MouseButton2 and CanADS then
			SetADS()
		end
		if InputType == "Keyboard" then
			if Input.KeyCode == Module.Keyboard.Reload then
				Reload()
			elseif Input.KeyCode == Module.Keyboard.HoldDown then
				OnHoldingDown()
			elseif Input.KeyCode == Module.Keyboard.Inspect then
				OnInspecting()
			elseif Input.KeyCode == Module.Keyboard.Switch then
				OnSwitching()
			elseif Input.KeyCode == Module.Keyboard.ToogleAim then
				SetADS()
			elseif Input.KeyCode == Module.Keyboard.Melee then
				OnMeleeAttacking()
			elseif Input.KeyCode == Module.Keyboard.AltFire then
				OnAlting()
			end
		end
	end

	-- Controller bindings (always active when a gamepad input comes in)
	if IsController and InputType == "Controller" then
		if Input.KeyCode == Module.Controller.Fire then
			OnFiring()
		elseif Input.KeyCode == Module.Controller.Reload then
			Reload()
		elseif Input.KeyCode == Module.Controller.HoldDown then
			OnHoldingDown()
		elseif Input.KeyCode == Module.Controller.Inspect then
			OnInspecting()
		elseif Input.KeyCode == Module.Controller.Switch then
			OnSwitching()
		elseif Input.KeyCode == Module.Controller.ToogleAim then
			SetADS()
		elseif Input.KeyCode == Module.Controller.Melee then
			OnMeleeAttacking()
		elseif Input.KeyCode == Module.Controller.AltFire then
			OnAlting()
		end
	end
end)

UserInputService.InputEnded:Connect(function(Input, GameProcessed)
	local IsController = Input.UserInputType == Enum.UserInputType.Gamepad1
	if GameProcessed and not IsController then
		return
	end

	if not IsConsoleOrTouch() then
		if Input.UserInputType == Enum.UserInputType.MouseButton1 then
			OnStoppingFiring()
		elseif Input.UserInputType == Enum.UserInputType.MouseButton2 then
			local CanADS = (Camera.Focus.Position - Camera.CFrame.Position).Magnitude <= 1
			if Module.ThirdPersonADS then
				CanADS = CanADS or (UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter)
			end
			if CanADS then
				SetADS(true)
			end
		end
	end

	if IsController then
		if Input.KeyCode == Module.Controller.Fire then
			OnStoppingFiring()
		end
	end
end)

MarkerEvent.Event:Connect(MarkHit)

ChangeMagAndAmmo.OnClientEvent:Connect(function(Values, Ammo)
	for i, v in ipairs(Values) do
		Variables[v.Id].Mag = v.Mag
		if not Module.UniversalAmmoEnabled then
			Variables[v.Id].Ammo = v.Ammo
		end
		Variables[v.Id].Heat = v.Heat
	end
	if Module.UniversalAmmoEnabled then
		UniversalTable.Ammo = Ammo
	end
	RequestGUIUpdate()
end)

-- ============================================================
-- EQUIP / UNEQUIP
-- ============================================================
Tool.Equipped:Connect(function()
	UserInputService.MouseIconEnabled = false
	if Module.CustomGripEnabled and not Tool.RequiresHandle then
		task.spawn(function()
			SetCustomGrip(true)
		end)
	end
	if Module.DualWeldEnabled and not Module.CustomGripEnabled and Tool.RequiresHandle then
		task.spawn(function()
			if RightArm then
				local Grip = RightArm:WaitForChild("RightGrip", 0.01)
				if Grip then
					CommonVariables.Grip2 = Grip:Clone()
					CommonVariables.Grip2.Name = "LeftGrip"
					CommonVariables.Grip2.Part0 = LeftArm
					CommonVariables.Grip2.Part1 = CommonVariables.Handle2
					CommonVariables.Grip2.Parent = LeftArm
				end
			end
		end)
	end

	CommonVariables.Equipped = true
	CommonVariables.ActuallyEquipped = false
	CommonVariables.Down = false

	GUI.Parent = Player.PlayerGui
	if GUI:IsA("ScreenGui") then
		GUI.Enabled = true
	end

	-- Restore first so every button starts from a known state before being moved.
	-- UpdateGUI is called immediately instead of being deferred, because the old
	-- RequestGUIUpdate path waited for ActuallyEquipped and could skip the first
	-- button-visibility pass during equip.
	RestoreMobileButtons()
	SetAllMobileButtonsVisible(false)
	UpdateGUI()

	local buttonParent = GetButtonParent()
	if buttonParent then
		MobileButtons.AimButton.Parent = buttonParent
		MobileButtons.FireButton.Parent = buttonParent
		MobileButtons.HoldDownButton.Parent = buttonParent
		MobileButtons.InspectButton.Parent = buttonParent
		MobileButtons.ReloadButton.Parent = buttonParent
		MobileButtons.SwitchButton.Parent = buttonParent
		MobileButtons.AltButton.Parent = buttonParent
		MobileButtons.MeleeButton.Parent = buttonParent
		-- Do not parent SubFireButton into the mobile host. It is the tiny duplicate
		-- fire button; FireButton is the only fire control we want on mobile.
		MobileButtons.SubFireButton.Parent = GUI
		MobileButtons.SubFireButton.Visible = false
	end
	ApplyGunGuiLayering()
	UpdateGUI()
	SetCrossSettings(CurrentModule.CrossSize, CurrentModule.CrossSpeed, CurrentModule.CrossDamper)

	if CommonVariables.Radar == nil then
		CommonVariables.Radar = Scanners.Radars[CurrentModule.Radar]:Clone()
		CommonVariables.Radar.Name = "Scanner"
		CommonVariables.Radar.Parent = GUI
	end

	if CurrentModule.ProjectileMotion then
		local MotionBeam = GunVisualEffects:FindFirstChild(CurrentModule.MotionBeam)
		if MotionBeam then
			CommonVariables.Beam, CommonVariables.Attach0, CommonVariables.Attach1 =
				ProjectileMotion.ShowProjectilePath(
					MotionBeam,
					(CurrentFirePoint and CurrentFirePoint.WorldPosition) or Head.Position,
					Vector3.new(),
					3,
					AddressTableValue("Acceleration", CurrentModule)
				)
		end
	end

	RunService:BindToRenderStep(BindToStepName, Enum.RenderPriority.Camera.Value, Render)

	for _, v in pairs(CommonVariables.Keyframes) do
		table.insert(
			CommonVariables.KeyframeConnections,
			v[1]:GetMarkerReachedSignal("AnimationEvents"):Connect(function(keyframeName)
				if v[2][keyframeName] then
					v[2][keyframeName](keyframeName, Tool)
				end
			end)
		)
	end

	if CurrentAnimTable.EmptyEquippedAnim and CurrentVariables.Mag <= 0 then
		SetAnimationTrack("EmptyEquippedAnim", "Play", CurrentModule.EmptyEquippedAnimationSpeed)
		HandleToFire[CurrentFireMode].EmptyEquippedSound:Play()
	else
		SetAnimationTrack("EquippedAnim", "Play", CurrentModule.EquippedAnimationSpeed)
		HandleToFire[CurrentFireMode].EquippedSound:Play()
	end

	if CurrentAnimTable.EmptyIdleAnim and CurrentVariables.Mag <= 0 then
		SetAnimationTrack("EmptyIdleAnim", "Play", CurrentModule.EmptyIdleAnimationSpeed)
	else
		SetAnimationTrack("IdleAnim", "Play", CurrentModule.IdleAnimationSpeed)
	end

	local StartTime = os.clock()
	repeat
		Thread:Wait()
		if not CommonVariables.Equipped then
			break
		end
	until (os.clock() - StartTime)
		>= ((CurrentVariables.Mag <= 0) and CurrentModule.EmptyEquipTime or CurrentModule.EquipTime)
	if CommonVariables.Equipped then
		CommonVariables.ActuallyEquipped = true
		UpdateGUI()
	end
	if CommonVariables.ActuallyEquipped and Module.AutoReload and CurrentVariables.Mag <= 0 then
		Reload()
	end
end)

Tool.Unequipped:Connect(function()
	OnUnequipping(Tool.Parent == Workspace)
end)

CommonVariables.HumanoidDiedConnection = nil
CommonVariables.CleanupInProgress = false

function CleanupControlsForDeathOrRemoval()
	if CommonVariables.CleanupInProgress then
		return
	end
	CommonVariables.CleanupInProgress = true

	HardHideMobileControls()
	SetADSSensitivityEnabled(false)
	UserInputService.MouseIconEnabled = true
	Mouse.Icon = ""

	pcall(function()
		ResetSens:Fire({
			Sensitivity = CommonVariables.InitialSensitivity,
			FOV = 70,
			MouseIconEnabled = true,
		})
	end)

	if CommonVariables.Equipped or GUI.Parent ~= script then
		local ok, err = pcall(OnUnequipping, true)
		if not ok then
			warn("[GunClient] OnUnequipping cleanup failed:", err)
			HardHideMobileControls()
			GUI.Parent = script
		end
	else
		HardHideMobileControls()
		GUI.Parent = script
	end

	CommonVariables.CleanupInProgress = false
end

function ConnectHumanoidDeath(humanoid)
	if CommonVariables.HumanoidDiedConnection then
		CommonVariables.HumanoidDiedConnection:Disconnect()
		CommonVariables.HumanoidDiedConnection = nil
	end

	if humanoid then
		CommonVariables.HumanoidDiedConnection = humanoid.Died:Connect(CleanupControlsForDeathOrRemoval)
	end
end

ConnectHumanoidDeath(Humanoid)

Tool.AncestryChanged:Connect(function()
	if not Tool:IsDescendantOf(game) then
		CleanupControlsForDeathOrRemoval()
	end
end)

Player.CharacterRemoving:Connect(function(removingCharacter)
	if removingCharacter == Character then
		CleanupControlsForDeathOrRemoval()
	end
end)

function DestroyDetachedGunGUI()
	-- Last-resort guard for the exact death case where the Tool/LocalScript is
	-- destroyed while the HUD has been moved to PlayerGui. Destroying the HUD is
	-- safe here because this script is going away too.
	pcall(HardHideMobileControls)
	if GUI and GUI.Parent and GUI.Parent ~= script then
		GUI:Destroy()
	end
end

script.Destroying:Connect(DestroyDetachedGunGUI)
Tool.Destroying:Connect(DestroyDetachedGunGUI)

Player.CharacterAdded:Connect(function(newCharacter)
	UserInputService.MouseIconEnabled = true

	-- Keep these references fresh if this tool LocalScript survives a respawn.
	-- This is mainly for cleanup/mobile-control safety; animation tracks are still
	-- loaded during the original script startup like the rest of this gun system.
	Character = newCharacter
	Humanoid = Character:WaitForChild("Humanoid")
	HumanoidRootPart = Character:WaitForChild("HumanoidRootPart")
	Head = Character:WaitForChild("Head")
	Torso = Character:FindFirstChild("Torso")
	LeftArm = Character:FindFirstChild("Left Arm")
	RightArm = Character:FindFirstChild("Right Arm")

	IgnoreList = { Camera, Tool, Character }
	RegionParams.FilterDescendantsInstances = IgnoreList
	RayParams.FilterDescendantsInstances = IgnoreList

	ConnectHumanoidDeath(Humanoid)
	HardHideMobileControls()
	GUI.Parent = script
end)
