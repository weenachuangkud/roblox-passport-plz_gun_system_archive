local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Camera = Workspace.CurrentCamera

local Events = ReplicatedStorage:WaitForChild("Gun"):WaitForChild("Events")
local Remotes = ReplicatedStorage:WaitForChild("Gun"):WaitForChild("Remotes")
local Modules = ReplicatedStorage:WaitForChild("Gun"):WaitForChild("Modules")
local Miscs = ReplicatedStorage:WaitForChild("Gun"):WaitForChild("Miscs")

local gunEvent = Events.gunEvent
local gunFunction = Events.gunFunction

local PlayAudio = Remotes.PlayAudio
local VisualizeBullet = Remotes.VisualizeBullet
local VisualizeHitEffect = Remotes.VisualizeHitEffect
local VisualizeBeam = Remotes.VisualizeBeam
local VisibleMuzzle = Remotes.VisibleMuzzle
local VisualizeCharge = Remotes.VisualizeCharge
local VisualizeOverheat = Remotes.VisualizeOverheat

local AudioHandler = require(Modules.AudioHandler)
local ProjectileHandler = require(Modules.ProjectileHandler)
local Utilities = require(Modules.Utilities)
local GetSetting = require(Modules.GetSetting)
local PartCache = require(Modules.PartCache)
local Thread = Utilities.Thread

local GunVisualEffects = Miscs.GunVisualEffects

-- ============================================================
-- PART CACHES — reuse bolt segments instead of cloning per frame
-- ============================================================
local BOLT_CACHE_SIZE = 48

local BoltContainers = {
	Block = Instance.new("Folder"),
	Cylinder = Instance.new("Folder"),
	Cone = Instance.new("Folder"),
}
BoltContainers.Block.Name = "VFX_BoltBlock"
BoltContainers.Cylinder.Name = "VFX_BoltCylinder"
BoltContainers.Cone.Name = "VFX_BoltCone"
BoltContainers.Block.Parent = Camera
BoltContainers.Cylinder.Parent = Camera
BoltContainers.Cone.Parent = Camera

local BoltCaches = {
	Block = PartCache.new(Miscs.BlockSegment, BOLT_CACHE_SIZE, BoltContainers.Block),
	Cylinder = PartCache.new(Miscs.CylinderSegment, BOLT_CACHE_SIZE, BoltContainers.Cylinder),
	Cone = PartCache.new(Miscs.ConeSegment, BOLT_CACHE_SIZE, BoltContainers.Cone),
}

-- Maximum number of lightning bolt emitters rendered simultaneously.
-- With 50 shooters this keeps GPU/CPU load bounded.
local MAX_ACTIVE_BOLTS = 14
local LIGHTNING_BOLT_UPDATE_INTERVAL = 1 / 30

-- Pending bolt-segment fades: { seg, cache, returnAt }
-- Processed in Heartbeat to avoid stacking thousands of Thread:Delay calls.
local PendingBoltFades = {}

-- ============================================================

local Container = {}
local LaserTrailContainer = {}
local LightningBoltContainer = {}
local ChargeEffectModules = {}
local OverheatEffectModules = {}
local function GetChargeEffectModule(Effect)
	if not ChargeEffectModules[Effect] then
		if Modules.ChargeFolder:FindFirstChild(Effect) then
			ChargeEffectModules[Effect] = require(Modules.ChargeFolder[Effect])
		end
	end
	return ChargeEffectModules[Effect] or nil
end

local function GetOverheatEffectModule(Effect)
	if not OverheatEffectModules[Effect] then
		if Modules.OverheatFolder:FindFirstChild(Effect) then
			OverheatEffectModules[Effect] = require(Modules.OverheatFolder[Effect])
		end
	end
	return OverheatEffectModules[Effect] or nil
end

local function FindExistingId(Dictionary)
	for _, v in pairs(Container) do
		if v.Main.Id == Dictionary.Id then
			return true
		end
	end
	return false
end

function RemoveExistingBeam(Id, Tool, ModuleName, BeamTable, LaserTrail, BoltSegments, CrosshairPointAttachment)
	VisualizeBeam:FireServer(false, {
		Id = Id,
		Tool = Tool,
		ModuleName = ModuleName,
	})
	if BeamTable then
		for i, v in pairs(BeamTable) do
			if v then
				v:Destroy()
			end
		end
		table.clear(BeamTable)
	end
	local Module = GetSetting(Tool, { ModuleName = ModuleName })
	if LaserTrail then
		Thread:Spawn(function()
			if Module.LaserTrailFadeTime > 0 then
				local DesiredSize = LaserTrail.Size
					* (
						Module.ScaleLaserTrail
							and Vector3.new(1, Module.LaserTrailScaleMultiplier, Module.LaserTrailScaleMultiplier)
						or Vector3.new(1, 1, 1)
					)
				local Tween = TweenService:Create(
					LaserTrail,
					TweenInfo.new(Module.LaserTrailFadeTime, Enum.EasingStyle.Linear, Enum.EasingDirection.Out),
					{ Transparency = 1, Size = DesiredSize }
				)
				Tween:Play()
				Tween.Completed:Wait()
				LaserTrail:Destroy()
			else
				LaserTrail:Destroy()
			end
		end)
	end
	if BoltSegments then
		for i, v in pairs(BoltSegments) do
			local segment = v
			Thread:Delay(Module.BoltVisibleTime, function()
				if Module.BoltFadeTime > 0 then
					local DesiredSize = segment.Size
						* (
							Module.ScaleBolt
								and Vector3.new(1, Module.BoltScaleMultiplier, Module.BoltScaleMultiplier)
							or Vector3.new(1, 1, 1)
						)
					local Tween = TweenService:Create(
						segment,
						TweenInfo.new(Module.BoltFadeTime, Enum.EasingStyle.Linear, Enum.EasingDirection.Out),
						{ Transparency = 1, Size = DesiredSize }
					)
					Tween:Play()
					Tween.Completed:Wait()
					segment:Destroy()
				else
					segment:Destroy()
				end
			end)
		end
		table.clear(BoltSegments)
	end
	if CrosshairPointAttachment then
		CrosshairPointAttachment:Destroy()
	end
end

function PlayReplicatedAudio(Audio, LowAmmoAudio, Replicate)
	AudioHandler:PlayAudio(Audio, LowAmmoAudio, Replicate)
end

function SimulateReplicatedProjectile(Tool, Handle, Directions, FirePointObject, MuzzlePointObject, Misc, Replicate)
	ProjectileHandler:SimulateProjectile(Tool, Handle, Directions, FirePointObject, MuzzlePointObject, Misc, Replicate)
end

function VisualizeReplicatedHitEffect(Type, Hit, Position, Normal, Material, Misc, Replicate)
	ProjectileHandler:VisualizeHitEffect(Type, Hit, Position, Normal, Material, Misc, Replicate)
end

function VisualizeReplicatedBeam(Enabled, Dictionary)
	if Enabled then
		if not FindExistingId(Dictionary) then
			table.insert(Container, { Main = Dictionary })
		else
			local Main
			for _, v in pairs(Container) do
				if v.Main.Id == Dictionary.Id then
					Main = v.Main
					break
				end
			end
			local Module = GetSetting(Main.Tool, { ModuleName = Main.ModuleName })
			local LaserBeamEffect = GunVisualEffects:FindFirstChild(Module.LaserBeamEffect)
			if not Main.CrosshairPointAttachment then
				Main.CrosshairPointAttachment = Instance.new("Attachment")
				Main.CrosshairPointAttachment.Name = "CrosshairPointAttachment"
				if LaserBeamEffect then
					for i, v in pairs(LaserBeamEffect.HitEffect:GetChildren()) do
						if v.ClassName == "ParticleEmitter" then
							local particle = v:Clone()
							particle.Enabled = true
							particle.Parent = Main.CrosshairPointAttachment
						end
					end
				end
			end
			if not Main.LaserBeamContainer then
				Main.LaserBeamContainer = {}
				if LaserBeamEffect then
					for i, v in pairs(LaserBeamEffect.LaserBeams:GetChildren()) do
						if v.ClassName == "Beam" then
							local beam = v:Clone()
							table.insert(Main.LaserBeamContainer, beam)
						end
					end
				end
				for i, v in pairs(Main.LaserBeamContainer) do
					if v then
						v.Parent = Main.Handle
						v.Attachment0 = Main.FirePoint
						v.Attachment1 = Main.CrosshairPointAttachment
					end
				end
			end
			if Module.LaserTrailEnabled and not Main.LaserTrailData then
				Main.LaserTrailData = {}
				Main.LaserTrailData.Id = Main.Id
				Main.LaserTrailData.Setting = Module
				Main.LaserTrailData.FirePoint = Main.FirePoint
				Main.LaserTrailData.CrosshairPointAttachment = Main.CrosshairPointAttachment

				Main.LaserTrailData.LaserTrail = Miscs[Module.LaserTrailShape .. "Segment"]:Clone()
				Main.LaserTrailData.LaserTrail.CastShadow = false
				Main.LaserTrailData.LaserTrail.CanQuery = false
				Main.LaserTrailData.LaserTrail.CanTouch = false
				if Module.RandomizeLaserColorIn == "None" then
					Main.LaserTrailData.LaserTrail.Color = Module.LaserTrailColor
				end
				Main.LaserTrailData.LaserTrail.Material = Module.LaserTrailMaterial
				Main.LaserTrailData.LaserTrail.Reflectance = Module.LaserTrailReflectance
				Main.LaserTrailData.LaserTrail.Transparency = Module.LaserTrailTransparency
				Main.LaserTrailData.LaserTrail.Size = Module.LaserTrailShape == "Cone"
						and Vector3.new(
							Module.LaserTrailWidth,
							(Main.FirePoint.WorldPosition - Main.CrosshairPointAttachment.WorldPosition).Magnitude,
							Module.LaserTrailHeight
						)
					or Vector3.new(
						(Main.FirePoint.WorldPosition - Main.CrosshairPointAttachment.WorldPosition).Magnitude,
						Module.LaserTrailHeight,
						Module.LaserTrailWidth
					)
				Main.LaserTrailData.LaserTrail.CFrame = CFrame.new(
					(Main.FirePoint.WorldPosition + Main.CrosshairPointAttachment.WorldPosition) * 0.5,
					Main.CrosshairPointAttachment.WorldPosition
				) * (Module.LaserTrailShape == "Cone" and CFrame.Angles(math.pi / 2, 0, 0) or CFrame.Angles(
					0,
					math.pi / 2,
					0
				))
				Main.LaserTrailData.LaserTrail.Parent = Camera

				table.insert(LaserTrailContainer, Main.LaserTrailData)
			end
			if Module.LightningBoltEnabled and not Main.LightningBoltData then
				Main.LightningBoltData = {}
				Main.LightningBoltData.Id = Main.Id
				Main.LightningBoltData.Setting = Module
				Main.LightningBoltData.FirePoint = Main.FirePoint
				Main.LightningBoltData.CrosshairPointAttachment = Main.CrosshairPointAttachment
				table.insert(LightningBoltContainer, Main.LightningBoltData)
			end
			Main.CrosshairPointAttachment.Parent = Workspace.Terrain
			Main.CrosshairPointAttachment.WorldCFrame = CFrame.new(Dictionary.CrosshairPosition)
			if Module.LookAtInput then
				local FireDirection = (Main.CrosshairPointAttachment.WorldPosition - Main.FirePoint.WorldPosition).Unit
				Main.MuzzlePoint.CFrame = Main.MuzzlePoint.Parent.CFrame:toObjectSpace(
					CFrame.lookAt(Main.MuzzlePoint.WorldPosition, Dictionary.CrosshairPosition)
				)
				Main.CrosshairPointAttachment.WorldCFrame = CFrame.new(Dictionary.CrosshairPosition, FireDirection)
			end
		end
	else
		for i, v in pairs(Container) do
			if v.Main.Id == Dictionary.Id then
				if v.Main.CrosshairPointAttachment then
					v.Main.CrosshairPointAttachment:Destroy()
				end
				if v.Main.LaserBeamContainer then
					for ii, vv in pairs(v.Main.LaserBeamContainer) do
						if vv then
							vv:Destroy()
						end
					end
					table.clear(v.Main.LaserBeamContainer)
				end
				if v.Main.LaserTrailData then
					for ii, vv in pairs(LaserTrailContainer) do
						if vv.Id == v.Main.LaserTrailData.Id then
							vv.Terminate = true
							break
						end
					end
				end
				if v.Main.LightningBoltData then
					for ii, vv in pairs(LightningBoltContainer) do
						if vv.Id == v.Main.LightningBoltData.Id then
							vv.Terminate = true
							break
						end
					end
				end
				table.remove(Container, i)
				break
			end
		end
	end
end

function VisibleReplicatedMuzzle(MuzzlePointObject, Enabled)
	if MuzzlePointObject then
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
end

function Charge(EffectName, State, Character, Tool, Handle, ChargeLevel, Replicate)
	if EffectName == "None" then
		return
	end
	local Effect = GetChargeEffectModule(EffectName)
	if Effect == nil then
		return
	end
	if State == "Begin" then
		Effect:BeginCharge(Character, Tool, Handle, ChargeLevel)
	elseif State == "End" then
		Effect:EndCharge(Character, Tool, Handle)
	end
	if Replicate then
		VisualizeCharge:FireServer(EffectName, State, Character, Tool, Handle, ChargeLevel)
	end
end

function Overheat(EffectName, State, Character, Tool, Handle, Replicate)
	if EffectName == "None" then
		return
	end
	local Effect = GetOverheatEffectModule(EffectName)
	if Effect == nil then
		return
	end
	if State == "Begin" then
		Effect:BeginOverheat(Character, Tool, Handle)
	elseif State == "End" then
		Effect:EndOverheat(Character, Tool, Handle)
	end
	if Replicate then
		VisualizeOverheat:FireServer(EffectName, State, Character, Tool, Handle)
	end
end

-- ============================================================
-- EVENT CONNECTIONS
-- ============================================================
gunEvent.Event:Connect(function(EventName, ...)
	if EventName == "VisualizeBullet" then
		SimulateReplicatedProjectile(...)
	elseif EventName == "VisualizeHitEffect" then
		VisualizeReplicatedHitEffect(...)
	elseif EventName == "RemoveBeam" then
		RemoveExistingBeam(...)
	elseif EventName == "PlayAudio" then
		PlayReplicatedAudio(...)
	elseif EventName == "VisualizeCharge" then
		Charge(...)
	elseif EventName == "VisualizeOverheat" then
		Overheat(...)
	end
end)

gunFunction.OnInvoke = function(EventName, ...)
	return nil
end

local function connectStreamingSafe(remoteEvent, handler, eventName)
	remoteEvent.OnClientEvent:Connect(function(...)
		local ok, err = pcall(handler, ...)
		if not ok then
			warn(("[Streaming] skipped %s replication for unavailable instances: %s"):format(eventName, tostring(err)))
		end
	end)
end

connectStreamingSafe(PlayAudio, PlayReplicatedAudio, "audio")
connectStreamingSafe(VisualizeBullet, SimulateReplicatedProjectile, "bullet")
connectStreamingSafe(VisualizeHitEffect, VisualizeReplicatedHitEffect, "hit effect")
connectStreamingSafe(VisualizeBeam, VisualizeReplicatedBeam, "beam")
connectStreamingSafe(VisibleMuzzle, VisibleReplicatedMuzzle, "muzzle")
connectStreamingSafe(VisualizeCharge, Charge, "charge")
connectStreamingSafe(VisualizeOverheat, Overheat, "overheat")

RunService.RenderStepped:Connect(function(dt)
	for i, v in next, LaserTrailContainer, nil do
		if not (v.LaserTrail and v.LaserTrail.Parent and v.FirePoint and v.FirePoint.Parent and v.CrosshairPointAttachment and v.CrosshairPointAttachment.Parent) then
			table.remove(LaserTrailContainer, i)
			continue
		end
		if v.Terminate then
			v.Terminate = false
			local LaserTrail = v.LaserTrail
			local Module = v.Setting
			if LaserTrail then
				Thread:Spawn(function()
					if Module.LaserTrailFadeTime > 0 then
						local DesiredSize = LaserTrail.Size
							* (
								Module.ScaleLaserTrail
									and Vector3.new(
										1,
										Module.LaserTrailScaleMultiplier,
										Module.LaserTrailScaleMultiplier
									)
								or Vector3.new(1, 1, 1)
							)
						local Tween = TweenService:Create(
							LaserTrail,
							TweenInfo.new(Module.LaserTrailFadeTime, Enum.EasingStyle.Linear, Enum.EasingDirection.Out),
							{ Transparency = 1, Size = DesiredSize }
						)
						Tween:Play()
						Tween.Completed:Wait()
						LaserTrail:Destroy()
					else
						LaserTrail:Destroy()
					end
				end)
			end
			table.remove(LaserTrailContainer, i)
		else
			if v.Setting.RandomizeLaserColorIn ~= "None" then
				local Hue = os.clock() % v.Setting.LaserColorCycleTime / v.Setting.LaserColorCycleTime
				v.LaserTrail.Color = Color3.fromHSV(Hue, 1, 1)
			end
			v.LaserTrail.Size = v.Setting.LaserTrailShape == "Cone"
					and Vector3.new(
						v.Setting.LaserTrailWidth,
						(v.FirePoint.WorldPosition - v.CrosshairPointAttachment.WorldPosition).Magnitude,
						v.Setting.LaserTrailHeight
					)
				or Vector3.new(
					(v.FirePoint.WorldPosition - v.CrosshairPointAttachment.WorldPosition).Magnitude,
					v.Setting.LaserTrailHeight,
					v.Setting.LaserTrailWidth
				)
			v.LaserTrail.CFrame = CFrame.new(
				(v.FirePoint.WorldPosition + v.CrosshairPointAttachment.WorldPosition) * 0.5,
				v.CrosshairPointAttachment.WorldPosition
			) * (v.Setting.LaserTrailShape == "Cone" and CFrame.Angles(math.pi / 2, 0, 0) or CFrame.Angles(
				0,
				math.pi / 2,
				0
			))
		end
	end
end)

local lightningBoltElapsed = 0

RunService.Heartbeat:Connect(function(dt)
	local now = os.clock()
	for i = #PendingBoltFades, 1, -1 do
		local entry = PendingBoltFades[i]
		if now >= entry.returnAt then
			local seg = entry.seg
			local cache = entry.cache
			if seg and cache then
				if entry.fadeTime > 0 then
					Thread:Spawn(function()
						local DesiredSize = seg.Size
							* (
								entry.scaleBolt and Vector3.new(1, entry.scaleMultiplier, entry.scaleMultiplier)
								or Vector3.new(1, 1, 1)
							)
						local Tween = TweenService:Create(
							seg,
							TweenInfo.new(entry.fadeTime, Enum.EasingStyle.Linear, Enum.EasingDirection.Out),
							{ Transparency = 1, Size = DesiredSize }
						)
						Tween:Play()
						Tween.Completed:Wait()

						seg.Transparency = entry.originalTransparency
						seg.Size = entry.originalSize
						cache:ReturnPart(seg)
					end)
				else
					seg.Transparency = entry.originalTransparency
					seg.Size = entry.originalSize
					cache:ReturnPart(seg)
				end
			end
			table.remove(PendingBoltFades, i)
		end
	end

	lightningBoltElapsed += dt
	if lightningBoltElapsed < LIGHTNING_BOLT_UPDATE_INTERVAL then
		return
	end
	lightningBoltElapsed %= LIGHTNING_BOLT_UPDATE_INTERVAL

	local activeBoltCount = 0

	for i, v in next, LightningBoltContainer, nil do
		if not (v.FirePoint and v.FirePoint.Parent and v.CrosshairPointAttachment and v.CrosshairPointAttachment.Parent) then
			table.remove(LightningBoltContainer, i)
			continue
		end
		if v.Terminate then
			v.Terminate = false
			table.remove(LightningBoltContainer, i)
		else
			activeBoltCount += 1

			if activeBoltCount > MAX_ACTIVE_BOLTS then
				continue
			end

			local BoltRadius = v.Setting.BoltRadius
			for ii = 1, v.Setting.BoltCount do
				local offsetCFrame
				if ii == 1 then
					offsetCFrame = CFrame.new(0, 0, 0)
				else
					offsetCFrame =
						CFrame.new(math.random(-BoltRadius, BoltRadius), math.random(-BoltRadius, BoltRadius), 0)
				end

				local FireDirection = (v.CrosshairPointAttachment.WorldPosition - v.FirePoint.WorldPosition).Unit
				local firePointPosition = v.FirePoint.WorldPosition
				local crosshairPosition = v.CrosshairPointAttachment.WorldPosition
				local Start = (CFrame.new(firePointPosition, firePointPosition + FireDirection) * offsetCFrame).p
				local End = (CFrame.new(crosshairPosition, crosshairPosition + FireDirection) * offsetCFrame).p
				local Distance = (End - Start).Magnitude
				local LastPos = Start
				local RandomBoltColor = Color3.new(math.random(), math.random(), math.random())

				local cache = BoltCaches[v.Setting.BoltShape]
				if not cache then
					continue
				end

				for ii = 0, Distance, 10 do
					local FakeDistance = CFrame.new(Start, End)
						* CFrame.new(0, 0, -ii - 10)
						* CFrame.new(
							-2 + (math.random() * v.Setting.BoltWideness),
							-2 + (math.random() * v.Setting.BoltWideness),
							-2 + (math.random() * v.Setting.BoltWideness)
						)

					local BoltSegment = cache:GetPart()
					BoltSegment.CastShadow = false
					BoltSegment.CanQuery = false
					BoltSegment.CanTouch = false

					if v.Setting.RandomizeBoltColorIn ~= "None" then
						if v.Setting.RandomizeBoltColorIn == "Whole" then
							BoltSegment.Color = RandomBoltColor
						elseif v.Setting.RandomizeBoltColorIn == "Segment" then
							BoltSegment.Color = Color3.new(math.random(), math.random(), math.random())
						end
					else
						BoltSegment.Color = v.Setting.BoltColor
					end
					BoltSegment.Material = v.Setting.BoltMaterial
					BoltSegment.Reflectance = v.Setting.BoltReflectance

					local segTransparency = v.Setting.BoltTransparency
					BoltSegment.Transparency = segTransparency

					local segSize
					if ii + 10 > Distance then
						BoltSegment.CFrame = CFrame.new(LastPos, End)
							* CFrame.new(0, 0, -(LastPos - End).Magnitude / 2)
							* (
								v.Setting.BoltShape == "Cone" and CFrame.Angles(math.pi / 2, 0, 0)
								or CFrame.Angles(0, math.pi / 2, 0)
							)
						segSize = v.Setting.BoltShape == "Cone"
								and Vector3.new(v.Setting.BoltWidth, (LastPos - End).Magnitude, v.Setting.BoltHeight)
							or Vector3.new((LastPos - End).Magnitude, v.Setting.BoltHeight, v.Setting.BoltWidth)
					else
						BoltSegment.CFrame = CFrame.new(LastPos, FakeDistance.p)
							* CFrame.new(0, 0, -(LastPos - FakeDistance.p).Magnitude / 2)
							* (
								v.Setting.BoltShape == "Cone" and CFrame.Angles(math.pi / 2, 0, 0)
								or CFrame.Angles(0, math.pi / 2, 0)
							)
						segSize = v.Setting.BoltShape == "Cone"
								and Vector3.new(
									v.Setting.BoltWidth,
									(LastPos - FakeDistance.p).Magnitude,
									v.Setting.BoltHeight
								)
							or Vector3.new(
								(LastPos - FakeDistance.p).Magnitude,
								v.Setting.BoltHeight,
								v.Setting.BoltWidth
							)
					end
					BoltSegment.Size = segSize

					table.insert(PendingBoltFades, {
						seg = BoltSegment,
						cache = cache,
						returnAt = now + v.Setting.BoltVisibleTime,
						fadeTime = v.Setting.BoltFadeTime,
						scaleBolt = v.Setting.ScaleBolt,
						scaleMultiplier = v.Setting.BoltScaleMultiplier,
						originalTransparency = segTransparency,
						originalSize = segSize,
					})

					LastPos = FakeDistance.p
				end
			end
		end
	end
end)
