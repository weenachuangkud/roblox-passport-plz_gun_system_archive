local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local Debris = game:GetService("Debris")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Miscs = ReplicatedStorage:WaitForChild("Gun"):WaitForChild("Miscs")
local Modules = ReplicatedStorage:WaitForChild("Gun"):WaitForChild("Modules")
local Events = ReplicatedStorage:WaitForChild("Gun"):WaitForChild("Events")
local Remotes = ReplicatedStorage:WaitForChild("Gun"):WaitForChild("Remotes")

-- ============================================================
-- RATE LIMITING
-- ============================================================
local SOUND_RATE_LIMIT = 45
local SOUND_RATE_WINDOW = 1
local INFLICT_RATE_LIMIT = 20 -- max damage events per window per player
local INFLICT_RATE_WINDOW = 1

local playerSoundCounts = {}
local playerInflictCounts = {}

local AUDIO_VISUAL_DISTANCE = 500
local BULLET_VISUAL_DISTANCE = 1000
local HIT_EFFECT_VISUAL_DISTANCE = 750
local BEAM_VISUAL_DISTANCE = 1000
local MUZZLE_VISUAL_DISTANCE = 700
local STATUS_VISUAL_DISTANCE = 700

local beamVisualRecipients = {}
local muzzleVisualRecipients = setmetatable({}, { __mode = "k" })

-- Tracks server-registered bullet IDs so we can verify
-- that a bullet actually existed before dealing damage.
-- Structure: playerBulletRegistry[player][bulletId] = { origin, direction, timestamp, tool }
local playerBulletRegistry = {}

local function getPlayerPosition(player)
	local character = player.Character
	if not character then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart") or character:FindFirstChild("Torso")
	return root and root.Position or nil
end

local function getWorldPosition(value)
	local valueType = typeof(value)
	if valueType == "Vector3" then
		return value
	elseif valueType == "CFrame" then
		return value.Position
	elseif valueType == "Instance" then
		if value:IsA("Attachment") then
			return value.WorldPosition
		elseif value:IsA("BasePart") then
			return value.Position
		elseif value:IsA("Model") then
			local root = value.PrimaryPart
				or value:FindFirstChild("HumanoidRootPart")
				or value:FindFirstChildWhichIsA("BasePart")
			return root and root.Position or nil
		end
	end
	return nil
end

local function isNearAnyPosition(receiverPosition, maxDistanceSquared, ...)
	for i = 1, select("#", ...) do
		local position = select(i, ...)
		if position then
			local offset = receiverPosition - position
			if offset:Dot(offset) <= maxDistanceSquared then
				return true
			end
		end
	end
	return false
end

local function forNearbyPlayers(sourcePlayer, maxDistance, callback, ...)
	local sourcePosition = sourcePlayer and getPlayerPosition(sourcePlayer) or nil
	local maxDistanceSquared = maxDistance * maxDistance
	for _, player in next, Players:GetPlayers() do
		if player ~= sourcePlayer then
			local receiverPosition = getPlayerPosition(player)
			if receiverPosition and isNearAnyPosition(receiverPosition, maxDistanceSquared, sourcePosition, ...) then
				callback(player)
			end
		end
	end
end

local function rememberBeamRecipient(sourcePlayer, beamId, recipient)
	if beamId == nil then
		return
	end
	local playerBeams = beamVisualRecipients[sourcePlayer]
	if not playerBeams then
		playerBeams = {}
		beamVisualRecipients[sourcePlayer] = playerBeams
	end
	local recipients = playerBeams[beamId]
	if not recipients then
		recipients = {}
		playerBeams[beamId] = recipients
	end
	recipients[recipient] = true
end

local function takeBeamRecipients(sourcePlayer, beamId)
	if beamId == nil then
		return nil
	end
	local playerBeams = beamVisualRecipients[sourcePlayer]
	if not playerBeams then
		return nil
	end
	local recipients = playerBeams[beamId]
	playerBeams[beamId] = nil
	if next(playerBeams) == nil then
		beamVisualRecipients[sourcePlayer] = nil
	end
	return recipients
end

local function rememberMuzzleRecipient(muzzlePoint, recipient)
	if typeof(muzzlePoint) ~= "Instance" then
		return
	end
	local recipients = muzzleVisualRecipients[muzzlePoint]
	if not recipients then
		recipients = {}
		muzzleVisualRecipients[muzzlePoint] = recipients
	end
	recipients[recipient] = true
end

local function takeMuzzleRecipients(muzzlePoint)
	if typeof(muzzlePoint) ~= "Instance" then
		return nil
	end
	local recipients = muzzleVisualRecipients[muzzlePoint]
	muzzleVisualRecipients[muzzlePoint] = nil
	return recipients
end

local function getBackpack(player)
	return player:FindFirstChildOfClass("Backpack")
end

local function isAllowedSoundInstance(player, instance)
	if typeof(instance) ~= "Instance" or not instance:IsA("Sound") then
		return false
	end
	local character = player.Character
	if character and instance:IsDescendantOf(character) then
		return true
	end
	local backpack = getBackpack(player)
	if backpack and instance:IsDescendantOf(backpack) then
		return true
	end
	return instance:IsDescendantOf(ReplicatedStorage)
end

local function isValidOrigin(origin)
	return typeof(origin) == "Instance" and (origin:IsA("BasePart") or origin:IsA("Attachment"))
end

local function isValidAudioPacket(player, audio)
	if type(audio) ~= "table" then
		return false
	end
	if not isAllowedSoundInstance(player, audio.Instance) then
		return false
	end
	return isValidOrigin(audio.Origin)
end

local function isValidLowAmmoPacket(player, audio)
	if audio == nil then
		return true
	end
	if type(audio) ~= "table" then
		return false
	end
	return isAllowedSoundInstance(player, audio.Instance)
end

local function canProcessSound(player)
	local now = os.clock()
	local record = playerSoundCounts[player]
	if not record or now - record.Time > SOUND_RATE_WINDOW then
		record = { Count = 0, Time = now }
		playerSoundCounts[player] = record
	end
	if record.Count >= SOUND_RATE_LIMIT then
		return false
	end
	record.Count += 1
	record.Time = now
	return true
end

local function canProcessInflict(player)
	local now = os.clock()
	local record = playerInflictCounts[player]
	if not record or now - record.Time > INFLICT_RATE_WINDOW then
		record = { Count = 0, Time = now }
		playerInflictCounts[player] = record
	end
	if record.Count >= INFLICT_RATE_LIMIT then
		warn("InflictTarget rate limit exceeded by", player.Name)
		return false
	end
	record.Count += 1
	return true
end

-- Register a bullet on the server so InflictTarget can verify it actually fired
local BULLET_REGISTRY_MAX_AGE = 10 -- seconds before a bullet entry expires
local BULLET_REGISTRY_MAX = 200 -- max stored bullets per player

local function registerBullet(player, bulletId, tool, chargeLevel, moduleName, modNames)
	if not playerBulletRegistry[player] then
		playerBulletRegistry[player] = {}
	end
	local reg = playerBulletRegistry[player]

	-- Evict old entries to prevent memory growth
	local now = os.clock()
	for id, entry in pairs(reg) do
		if now - entry.Time > BULLET_REGISTRY_MAX_AGE then
			reg[id] = nil
		end
	end

	-- Hard cap
	local count = 0
	for _ in pairs(reg) do
		count += 1
	end
	if count >= BULLET_REGISTRY_MAX then
		warn("Bullet registry full for", player.Name)
		return false
	end

	reg[bulletId] = {
		Time = now,
		Tool = tool,
		ChargeLevel = chargeLevel,
		ModuleName = moduleName,
		ModNames = modNames,
	}
	return true
end

local function consumeBullet(player, bulletId)
	local reg = playerBulletRegistry[player]
	if not reg then
		return nil
	end
	local entry = reg[bulletId]
	if not entry then
		return nil
	end
	-- Do NOT delete — a single bullet can hit multiple targets (penetration/explosion).
	-- It will expire naturally via BULLET_REGISTRY_MAX_AGE.
	-- But we do check age here.
	if os.clock() - entry.Time > BULLET_REGISTRY_MAX_AGE then
		reg[bulletId] = nil
		return nil
	end
	return entry
end

Players.PlayerRemoving:Connect(function(player)
	playerSoundCounts[player] = nil
	playerInflictCounts[player] = nil
	playerBulletRegistry[player] = nil
	beamVisualRecipients[player] = nil
	for _, playerBeams in pairs(beamVisualRecipients) do
		for _, recipients in pairs(playerBeams) do
			recipients[player] = nil
		end
	end
	for _, recipients in pairs(muzzleVisualRecipients) do
		recipients[player] = nil
	end
end)

-- ============================================================
-- MODULE LOADING
-- ============================================================
local RayUpdateFolder = Modules.RayUpdateFolder
local GlassShattering = require(Modules.GlassShattering)
local DamageModule = require(Modules.DamageModule)
local GetSetting = require(Modules.GetSetting)
local FastCast = require(Modules.FastCastRedux)
local Utilities = require(Modules.Utilities)
local Math = Utilities.Math
local DirectionPredictor = Utilities.DirectionPredictor
local CloneTable = Utilities.CloneTable
local CreatePacket, DecodePacket = unpack(Utilities.DataPacket)

local CustomShots = {}
local OnHitEvents = {}
local OnShootEvents = {}
_G.TempBannedPlayers = {}

local PhysicEffect = true

-- ============================================================
-- HELPERS
-- ============================================================
local function AddressTableValue(Level, ValueName, Setting)
	if Setting.ChargedShotAdvanceEnabled and Setting.ChargeAlterTable then
		local AlterTable = Setting.ChargeAlterTable[ValueName]
		return AlterTable
				and ((Level == 1 and AlterTable.Level1) or (Level == 2 and AlterTable.Level2) or (Level == 3 and AlterTable.Level3) or Setting[ValueName])
			or Setting[ValueName]
	else
		return Setting[ValueName]
	end
end

local function CalculateDamage(Damage, TravelDistance, ZeroDamageDistance, FullDamageDistance)
	ZeroDamageDistance = ZeroDamageDistance or 10000
	FullDamageDistance = FullDamageDistance or 1000
	local DistRange = ZeroDamageDistance - FullDamageDistance
	local FallOff = math.clamp(1 - (math.max(0, TravelDistance - FullDamageDistance) / math.max(1, DistRange)), 0, 1)
	return math.max(Damage * FallOff, 0)
end

-- Validates that the player's character is alive
local function playerIsAlive(player)
	local char = player.Character
	if not char then
		return false
	end
	local hum = char:FindFirstChildOfClass("Humanoid")
	return hum and hum.Health > 0
end

-- Sanity-checks a ChargeLevel value
local function isValidChargeLevel(cl)
	return type(cl) == "number" and cl >= 0 and cl <= 3
end

-- ============================================================
-- CUSTOM EVENT DISPATCHERS
-- ============================================================
function ShootCustom(CustomShotName, CustomShotData, Tool, Handle, Directions, FirePointObject, Misc)
	if not CustomShots[CustomShotName] then
		if script.CustomShotModules:FindFirstChild(CustomShotName) then
			CustomShots[CustomShotName] = require(script.CustomShotModules[CustomShotName])
		end
	end
	if CustomShots[CustomShotName] then
		CustomShots[CustomShotName](CustomShotData, Tool, Handle, Directions, FirePointObject, Misc)
	end
end

function FireOnHitEvent(
	OnHitEventName,
	OnHitEventData,
	TaggerCharacter,
	TargetHumanoid,
	Damage,
	IsHeadshot,
	IsCritical,
	Tool
)
	if not OnHitEvents[OnHitEventName] then
		if script.OnHitEventModules:FindFirstChild(OnHitEventName) then
			OnHitEvents[OnHitEventName] = require(script.OnHitEventModules[OnHitEventName])
		end
	end
	if OnHitEvents[OnHitEventName] then
		OnHitEvents[OnHitEventName](
			OnHitEventData,
			TaggerCharacter,
			TargetHumanoid,
			Damage,
			IsHeadshot,
			IsCritical,
			Tool
		)
	end
end

function FireOnShootEvent(OnShootEventName, OnShootEventData, Tool, Handle, Directions, FirePointObject, Misc)
	if not OnShootEvents[OnShootEventName] then
		if script.OnShootEventModules:FindFirstChild(OnShootEventName) then
			OnShootEvents[OnShootEventName] = require(script.OnShootEventModules[OnShootEventName])
		end
	end
	if OnShootEvents[OnShootEventName] then
		OnShootEvents[OnShootEventName](OnShootEventData, Tool, Handle, Directions, FirePointObject, Misc)
	end
end

-- ============================================================
-- REMOTES: Audio / Visual (no damage)
-- ============================================================
Remotes.PlayAudio.OnServerEvent:Connect(function(Player, Audio, LowAmmoAudio)
	local ok, err = pcall(function()
		Audio = DecodePacket(Audio)
		if not Audio or not isValidAudioPacket(Player, Audio) then
			return
		end
		if LowAmmoAudio then
			LowAmmoAudio = DecodePacket(LowAmmoAudio)
			if not isValidLowAmmoPacket(Player, LowAmmoAudio) then
				return
			end
		end
		if not canProcessSound(Player) then
			return
		end
		local audioPacket = CreatePacket(Audio)
		local lowAmmoPacket = LowAmmoAudio ~= nil and CreatePacket(LowAmmoAudio) or nil
		forNearbyPlayers(Player, AUDIO_VISUAL_DISTANCE, function(plr)
			Remotes.PlayAudio:FireClient(plr, audioPacket, lowAmmoPacket)
		end, getWorldPosition(Audio.Origin))
	end)
	if not ok then
		warn("PlayAudio error from", Player.Name, err)
	end
end)

Remotes.VisualizeHitEffect.OnServerEvent:Connect(function(Player, Type, Hit, Position, Normal, Material, Misc)
	local ok, err = pcall(function()
		if Type ~= "Normal" and Type ~= "Blood" then
			return
		end
		if not Hit or not Hit:IsDescendantOf(Workspace) then
			return
		end
		if typeof(Position) ~= "Vector3" then
			return
		end
		if typeof(Normal) ~= "Vector3" then
			return
		end
		if math.abs(Normal.Magnitude - 1) > 0.1 then
			return
		end

		local hrp = Player.Character and Player.Character:FindFirstChild("HumanoidRootPart")
		if not hrp then
			return
		end
		-- Tighter distance check: bullet range is at most a few thousand studs
		if (hrp.Position - Position).Magnitude > 3000 then
			return
		end

		forNearbyPlayers(Player, HIT_EFFECT_VISUAL_DISTANCE, function(plr)
			Remotes.VisualizeHitEffect:FireClient(plr, Type, Hit, Position, Normal, Material, Misc)
		end, Position)
	end)
	if not ok then
		warn("VisualizeHitEffect error from", Player.Name, err)
	end
end)

-- ============================================================
-- VisualizeBullet — registers bullets server-side
-- ============================================================
Remotes.VisualizeBullet.OnServerEvent:Connect(
	function(Player, Tool, Handle, Directions, FirePointObject, MuzzlePointObject, Misc)
		local ok, err = pcall(function()
			if not Tool or Tool.Parent ~= Player.Character then
				return
			end
			if not Handle or not Handle:IsDescendantOf(Tool) then
				return
			end
			if
				not FirePointObject
				or (not FirePointObject:IsDescendantOf(Workspace) and not FirePointObject:IsDescendantOf(Tool))
			then
				return
			end

			Directions = DecodePacket(Directions)
			Misc = DecodePacket(Misc)

			if type(Directions) ~= "table" then
				return
			end
			if type(Misc) ~= "table" then
				return
			end
			if #Directions > 50 then
				warn("VisualizeBullet: excessive directions from", Player.Name)
				return
			end
			if not isValidChargeLevel(Misc.ChargeLevel) then
				return
			end

			for _, dir in ipairs(Directions) do
				if type(dir) ~= "table" then
					return
				end
				if typeof(dir[1]) ~= "Vector3" then
					return
				end
				if dir[1].Magnitude > 0 and math.abs(dir[1].Magnitude - 1) > 0.1 then
					return
				end
			end

			if not playerIsAlive(Player) then
				return
			end

			local Module = GetSetting(Tool, { ModuleName = Misc.ModuleName, ModNames = Misc.ModNames })
			if not Module then
				return
			end

			-- Register every bullet direction so InflictTarget can verify them later
			for _, dir in ipairs(Directions) do
				local bulletId = dir[2]
				if bulletId then
					registerBullet(Player, bulletId, Tool, Misc.ChargeLevel, Misc.ModuleName, Misc.ModNames)
				end
			end

			if AddressTableValue(Misc.ChargeLevel, "ShootType", Module) == "Custom" then
				ShootCustom(
					AddressTableValue(Misc.ChargeLevel, "CustomShotName", Module),
					AddressTableValue(Misc.ChargeLevel, "CustomShotData", Module),
					Tool,
					Handle,
					Directions,
					FirePointObject,
					Misc
				)
			end
			if AddressTableValue(Misc.ChargeLevel, "OnShootEventName", Module) ~= "None" then
				FireOnShootEvent(
					AddressTableValue(Misc.ChargeLevel, "OnShootEventName", Module),
					AddressTableValue(Misc.ChargeLevel, "OnShootEventData", Module),
					Tool,
					Handle,
					Directions,
					FirePointObject,
					Misc
				)
			end
			local directionsPacket = CreatePacket(Directions)
			local miscPacket = CreatePacket(Misc)
			forNearbyPlayers(Player, BULLET_VISUAL_DISTANCE, function(plr)
				Remotes.VisualizeBullet:FireClient(
					plr,
					Tool,
					Handle,
					directionsPacket,
					FirePointObject,
					MuzzlePointObject,
					miscPacket
				)
			end, getWorldPosition(FirePointObject), getWorldPosition(MuzzlePointObject))
		end)
		if not ok then
			warn("VisualizeBullet error from", Player.Name, err)
		end
	end
)

Remotes.VisualizeBeam.OnServerEvent:Connect(function(Player, Enabled, Dictionary)
	local ok, err = pcall(function()
		if typeof(Enabled) ~= "boolean" then
			return
		end
		if Dictionary ~= nil then
			if type(Dictionary) ~= "table" then
				return
			end
			-- Validate CrosshairPosition if present
			if Dictionary.CrosshairPosition ~= nil then
				if typeof(Dictionary.CrosshairPosition) ~= "Vector3" then
					return
				end
				local hrp = Player.Character and Player.Character:FindFirstChild("HumanoidRootPart")
				if hrp and (hrp.Position - Dictionary.CrosshairPosition).Magnitude > 3000 then
					return
				end
			end
		end
		local character = Player.Character
		if not character then
			return
		end
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if not humanoid or humanoid.Health <= 0 then
			return
		end
		local beamId = Dictionary and Dictionary.Id
		if Enabled then
			forNearbyPlayers(
				Player,
				BEAM_VISUAL_DISTANCE,
				function(plr)
					rememberBeamRecipient(Player, beamId, plr)
					Remotes.VisualizeBeam:FireClient(plr, Enabled, Dictionary)
				end,
				getWorldPosition(Dictionary and Dictionary.FirePoint),
				getWorldPosition(Dictionary and Dictionary.MuzzlePoint),
				Dictionary and Dictionary.CrosshairPosition
			)
		else
			local sent = {}
			local recipients = takeBeamRecipients(Player, beamId)
			if recipients then
				for plr in pairs(recipients) do
					if plr.Parent == Players then
						sent[plr] = true
						Remotes.VisualizeBeam:FireClient(plr, Enabled, Dictionary)
					end
				end
			end
			forNearbyPlayers(Player, BEAM_VISUAL_DISTANCE, function(plr)
				if not sent[plr] then
					Remotes.VisualizeBeam:FireClient(plr, Enabled, Dictionary)
				end
			end, Dictionary and Dictionary.CrosshairPosition)
		end
	end)
	if not ok then
		warn("VisualizeBeam error from", Player.Name, err)
	end
end)

Remotes.VisibleMuzzle.OnServerEvent:Connect(function(Player, MuzzlePointObject, Enabled)
	local ok, err = pcall(function()
		if typeof(Enabled) ~= "boolean" then
			return
		end
		if
			not MuzzlePointObject
			or (
				not MuzzlePointObject:IsDescendantOf(Workspace)
				and not MuzzlePointObject:IsDescendantOf(Player.Character or game)
			)
		then
			return
		end
		if Enabled then
			forNearbyPlayers(Player, MUZZLE_VISUAL_DISTANCE, function(plr)
				rememberMuzzleRecipient(MuzzlePointObject, plr)
				Remotes.VisibleMuzzle:FireClient(plr, MuzzlePointObject, Enabled)
			end, getWorldPosition(MuzzlePointObject))
		else
			local sent = {}
			local recipients = takeMuzzleRecipients(MuzzlePointObject)
			if recipients then
				for plr in pairs(recipients) do
					if plr.Parent == Players then
						sent[plr] = true
						Remotes.VisibleMuzzle:FireClient(plr, MuzzlePointObject, Enabled)
					end
				end
			end
			forNearbyPlayers(Player, MUZZLE_VISUAL_DISTANCE, function(plr)
				if not sent[plr] then
					Remotes.VisibleMuzzle:FireClient(plr, MuzzlePointObject, Enabled)
				end
			end, getWorldPosition(MuzzlePointObject))
		end
	end)
	if not ok then
		warn("VisibleMuzzle error from", Player.Name, err)
	end
end)

Remotes.VisualizeCharge.OnServerEvent:Connect(function(Player, EffectName, State, Character, Tool, Handle, ChargeLevel)
	local ok, err = pcall(function()
		if typeof(EffectName) ~= "string" then
			return
		end
		if typeof(State) ~= "boolean" then
			return
		end
		if Character ~= Player.Character then
			return
		end
		if not Tool or Tool.Parent ~= Player.Character then
			return
		end
		if not Handle or not Handle:IsDescendantOf(Tool) then
			return
		end
		if not isValidChargeLevel(ChargeLevel) then
			return
		end
		if State then
			forNearbyPlayers(Player, STATUS_VISUAL_DISTANCE, function(plr)
				Remotes.VisualizeCharge:FireClient(plr, EffectName, State, Character, Tool, Handle, ChargeLevel)
			end, getWorldPosition(Handle))
		else
			for _, plr in next, Players:GetPlayers() do
				if plr ~= Player then
					Remotes.VisualizeCharge:FireClient(plr, EffectName, State, Character, Tool, Handle, ChargeLevel)
				end
			end
		end
	end)
	if not ok then
		warn("VisualizeCharge error from", Player.Name, err)
	end
end)

Remotes.VisualizeOverheat.OnServerEvent:Connect(function(Player, EffectName, State, Character, Tool, Handle)
	local ok, err = pcall(function()
		if typeof(EffectName) ~= "string" then
			return
		end
		if typeof(State) ~= "boolean" then
			return
		end
		if Character ~= Player.Character then
			return
		end
		if not Tool or Tool.Parent ~= Player.Character then
			return
		end
		if not Handle or not Handle:IsDescendantOf(Tool) then
			return
		end
		if State then
			forNearbyPlayers(Player, STATUS_VISUAL_DISTANCE, function(plr)
				Remotes.VisualizeOverheat:FireClient(plr, EffectName, State, Character, Tool, Handle)
			end, getWorldPosition(Handle))
		else
			for _, plr in next, Players:GetPlayers() do
				if plr ~= Player then
					Remotes.VisualizeOverheat:FireClient(plr, EffectName, State, Character, Tool, Handle)
				end
			end
		end
	end)
	if not ok then
		warn("VisualizeOverheat error from", Player.Name, err)
	end
end)

Remotes.ShatterGlass.OnServerEvent:Connect(function(Player, Hit, Pos, Dir)
	local ok, err = pcall(function()
		if not Hit or not Hit.Parent then
			return
		end
		if Hit.Name ~= "_glass" then
			return
		end
		if not Hit:IsDescendantOf(Workspace) then
			return
		end
		if Hit.Transparency == 1 then
			return
		end
		local hrp = Player.Character and Player.Character:FindFirstChild("HumanoidRootPart")
		if not hrp then
			return
		end
		if (hrp.Position - Hit.Position).Magnitude > 150 then
			return
		end
		if typeof(Pos) ~= "Vector3" then
			return
		end
		if typeof(Dir) ~= "Vector3" then
			return
		end
		if Dir.Magnitude > 1000 then
			return
		end

		if PhysicEffect then
			local Sound = Instance.new("Sound")
			Sound.SoundId = "http://roblox.com/asset/?id=2978605361"
			Sound.TimePosition = 0.1
			Sound.Volume = 1
			Sound.Parent = Hit
			Sound:Play()
			Sound.Ended:Connect(function()
				Sound:Destroy()
			end)
			GlassShattering:Shatter(
				Hit,
				Pos,
				Dir + Vector3.new(math.random(-25, 25), math.random(-25, 25), math.random(-25, 25))
			)
		else
			local Sound = Instance.new("Sound")
			Sound.SoundId = "http://roblox.com/asset/?id=2978605361"
			Sound.TimePosition = 0.1
			Sound.Volume = 1
			Sound.Parent = Hit
			Sound:Play()
			Sound.Ended:Connect(function()
				Sound:Destroy()
			end)
			local Particle = script.Shatter:Clone()
			Particle.Color = ColorSequence.new(Hit.Color)
			Particle.Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, Hit.Transparency),
				NumberSequenceKeypoint.new(1, 1),
			})
			Particle.Parent = Hit
			task.delay(0.01, function()
				Particle:Emit(10 * math.abs(Hit.Size.magnitude))
				Debris:AddItem(Particle, Particle.Lifetime.Max)
			end)
			Hit.CanCollide = false
			Hit.Transparency = 1
		end
	end)
	if not ok then
		warn("ShatterGlass error from", Player.Name, err)
	end
end)

-- ============================================================
-- DAMAGE FUNCTIONS
-- ============================================================
function InflictGun(Player, Tool, Hit, Misc)
	Misc = DecodePacket(Misc)

	-- Basic hit validation
	if not Hit or not Misc.ClientHitSize or Hit.Size ~= Misc.ClientHitSize then
		warn("InflictGun: invalid hit from", Player.Name)
		return
	end

	-- Hit must belong to an actual character with a humanoid
	local Target = Hit:FindFirstAncestorOfClass("Model")
	if not Target then
		return
	end
	local TargetHumanoid = Target:FindFirstChildOfClass("Humanoid")
	if not TargetHumanoid then
		return
	end

	-- Server recalculates distance — never trust the client value
	local hrp = Player.Character and Player.Character:FindFirstChild("HumanoidRootPart")
	if not hrp then
		return
	end
	local targetTorso = Target:FindFirstChild("HumanoidRootPart") or Target:FindFirstChild("Head")
	if not targetTorso then
		return
	end
	Misc.Distance = (hrp.Position - targetTorso.Position).Magnitude

	local Module =
		GetSetting(Tool, { ModuleName = Misc.ModuleName, ModNames = Misc.ModNames, BulletId = Misc.BulletId })
	if not Module then
		return
	end

	-- Range check using server-side distance
	local MaxRange = AddressTableValue(Misc.ChargeLevel, "Range", Module)
	if Misc.Distance > MaxRange + 30 then
		warn("InflictGun: out of range from", Player.Name, Misc.Distance, ">", MaxRange)
		return
	end

	-- Validate ExplosionPos if explosive — must be near the player
	if Misc.ExplosionPos then
		if typeof(Misc.ExplosionPos) ~= "Vector3" then
			return
		end
		if (hrp.Position - Misc.ExplosionPos).Magnitude > MaxRange + 50 then
			warn("InflictGun: invalid ExplosionPos from", Player.Name)
			return
		end
	end

	local ModifiedSetting = {
		ExplosiveEnabled = AddressTableValue(Misc.ChargeLevel, "ExplosiveEnabled", Module),
		ExplosionRadius = AddressTableValue(Misc.ChargeLevel, "ExplosionRadius", Module),
		ExplosionKnockback = AddressTableValue(Misc.ChargeLevel, "ExplosionKnockback", Module),
		ExplosionKnockbackMultiplierOnTarget = AddressTableValue(
			Misc.ChargeLevel,
			"ExplosionKnockbackMultiplierOnTarget",
			Module
		),
		ExplosionKnockbackPower = AddressTableValue(Misc.ChargeLevel, "ExplosionKnockbackPower", Module),
		SelfDamage = AddressTableValue(Misc.ChargeLevel, "SelfDamage", Module),
		SelfDamageRedution = AddressTableValue(Misc.ChargeLevel, "SelfDamageRedution", Module),
		ReduceSelfDamageOnAirOnly = AddressTableValue(Misc.ChargeLevel, "ReduceSelfDamageOnAirOnly", Module),
		BaseDamage = AddressTableValue(Misc.ChargeLevel, "BaseDamage", Module),
		DamageMultipliers = AddressTableValue(Misc.ChargeLevel, "DamageMultipliers", Module),
		ZeroDamageDistance = AddressTableValue(Misc.ChargeLevel, "ZeroDamageDistance", Module),
		FullDamageDistance = AddressTableValue(Misc.ChargeLevel, "FullDamageDistance", Module),
		CriticalBaseChance = AddressTableValue(Misc.ChargeLevel, "CriticalBaseChance", Module),
		CriticalDamageMultiplier = AddressTableValue(Misc.ChargeLevel, "CriticalDamageMultiplier", Module),
		Knockback = AddressTableValue(Misc.ChargeLevel, "Knockback", Module),
		Lifesteal = AddressTableValue(Misc.ChargeLevel, "Lifesteal", Module),
		DebuffName = AddressTableValue(Misc.ChargeLevel, "DebuffName", Module),
		DebuffChance = AddressTableValue(Misc.ChargeLevel, "DebuffChance", Module),
		ApplyDebuffOnCritical = AddressTableValue(Misc.ChargeLevel, "ApplyDebuffOnCritical", Module),
		OnHitEventName = AddressTableValue(Misc.ChargeLevel, "OnHitEventName", Module),
		OnHitEventData = AddressTableValue(Misc.ChargeLevel, "OnHitEventData", Module),
		HeadshotHitmarker = AddressTableValue(Misc.ChargeLevel, "HeadshotHitmarker", Module),
	}

	local Character = Player.Character
	local Humanoid = Character:FindFirstChildOfClass("Humanoid")
	local IsHeadshot = (Hit and Hit.Name == "Head" and ModifiedSetting.HeadshotHitmarker)
	local TrueDamage

	if Misc.Distance and ModifiedSetting.ExplosiveEnabled then
		local DamageMultiplier = (1 - math.clamp((Misc.Distance / ModifiedSetting.ExplosionRadius), 0, 1))
		TrueDamage = Module.DamageBasedOnDistance
				and (ModifiedSetting.BaseDamage * (ModifiedSetting.DamageMultipliers[Hit.Name] or 1)) * DamageMultiplier
			or ModifiedSetting.BaseDamage * (ModifiedSetting.DamageMultipliers[Hit.Name] or 1)
	else
		TrueDamage = Module.DamageDropOffEnabled
				and CalculateDamage(
					ModifiedSetting.BaseDamage * (ModifiedSetting.DamageMultipliers[Hit.Name] or 1),
					Misc.Distance,
					ModifiedSetting.ZeroDamageDistance,
					ModifiedSetting.FullDamageDistance
				)
			or ModifiedSetting.BaseDamage * (ModifiedSetting.DamageMultipliers[Hit.Name] or 1)
	end

	if Player and Character and Humanoid then
		if TargetHumanoid and TargetHumanoid.Health ~= 0 and targetTorso then
			local GuaranteedDebuff = false
			local CanDamage = DamageModule.CanDamage(TargetHumanoid.Parent, Character, Module.FriendlyFire)
			local CanBlock = Target:FindFirstChild("CanBlock")
			if CanBlock then
				local shield = Target:FindFirstChild("Shield")
				if shield then
					local shooterHrp = Character:FindFirstChild("HumanoidRootPart")
					if shooterHrp then
						local params = RaycastParams.new()
						params.FilterType = Enum.RaycastFilterType.Include
						params.FilterDescendantsInstances = { shield, Target }
						local result =
							workspace:Raycast(shooterHrp.Position, targetTorso.Position - shooterHrp.Position, params)
						if result then
							local instance = result.Instance
							if instance == shield or instance:IsDescendantOf(shield) then
								return
							end
						end
					end
				end
			end
			if ModifiedSetting.ExplosiveEnabled and ModifiedSetting.SelfDamage then
				if TargetHumanoid.Parent.Name == Player.Name then
					CanDamage = (TargetHumanoid.Parent.Name == Player.Name)
					if ModifiedSetting.ReduceSelfDamageOnAirOnly then
						TrueDamage = TargetHumanoid:GetState() ~= Enum.HumanoidStateType.Freefall and TrueDamage
							or (TrueDamage * (1 - ModifiedSetting.SelfDamageRedution))
					else
						TrueDamage = TrueDamage * (1 - ModifiedSetting.SelfDamageRedution)
					end
				end
			end
			if not CanDamage then
				return
			end
			while TargetHumanoid:FindFirstChild("creator") do
				TargetHumanoid.creator:Destroy()
			end
			local Creator = Instance.new("ObjectValue")
			Creator.Name = "creator"
			Creator.Value = Player
			Creator.Parent = TargetHumanoid
			Debris:AddItem(Creator, 5)
			local IsCritical = Module.CriticalDamageEnabled
				and (Random.new():NextInteger(0, 100) <= ModifiedSetting.CriticalBaseChance)
			if IsCritical then
				TrueDamage = TrueDamage * ModifiedSetting.CriticalDamageMultiplier
				GuaranteedDebuff = ModifiedSetting.ApplyDebuffOnCritical
			end
			TrueDamage = math.max(0, TrueDamage)
			TargetHumanoid:TakeDamage(TrueDamage)
			if ModifiedSetting.ExplosiveEnabled and ModifiedSetting.ExplosionKnockback then
				if TargetHumanoid.Parent.Name ~= Player.Name then
					local VelocityMod = (targetTorso.Position - Misc.ExplosionPos).Unit
						* ModifiedSetting.ExplosionKnockbackPower
					local AirVelocity = targetTorso.Velocity
						- Vector3.new(0, targetTorso.Velocity.Y, 0)
						+ Vector3.new(VelocityMod.X, 0, VelocityMod.Z)
					local TorsoFly = Instance.new("BodyVelocity")
					TorsoFly.MaxForce = Vector3.new(math.huge, 0, math.huge)
					TorsoFly.Velocity = AirVelocity
					TorsoFly.Parent = targetTorso
					targetTorso.Velocity = targetTorso.Velocity
						+ Vector3.new(0, VelocityMod.Y * ModifiedSetting.ExplosionKnockbackMultiplierOnTarget, 0)
					Debris:AddItem(TorsoFly, 0.5)
				end
			else
				if ModifiedSetting.Knockback > 0 then
					local Shover = Character:FindFirstChild("HumanoidRootPart") or Character:FindFirstChild("Head")
					local Duration = 0.1
					local Speed = ModifiedSetting.Knockback / Duration
					local Velocity = (targetTorso.Position - Shover.Position).Unit * Speed
					local ShoveForce = Instance.new("BodyVelocity")
					ShoveForce.MaxForce = Vector3.new(1e9, 1e9, 1e9)
					ShoveForce.Velocity = Velocity
					ShoveForce.Parent = targetTorso
					Debris:AddItem(ShoveForce, Duration)
				end
			end
			if ModifiedSetting.Lifesteal > 0 and Humanoid.Health ~= 0 then
				Humanoid.Health = Humanoid.Health + TrueDamage * ModifiedSetting.Lifesteal
			end
			if Module.Debuff and ModifiedSetting.DebuffName ~= "" then
				local Roll = Random.new():NextInteger(0, 100)
				if Roll <= ModifiedSetting.DebuffChance or GuaranteedDebuff then
					if not TargetHumanoid.Parent:FindFirstChild(ModifiedSetting.DebuffName) then
						local Debuff = Miscs.Debuffs[ModifiedSetting.DebuffName]:Clone()
						Debuff.creator.Value = Creator.Value
						Debuff.Parent = TargetHumanoid.Parent
						Debuff.Disabled = false
					end
				end
			end
			if ModifiedSetting.OnHitEventName ~= "None" then
				FireOnHitEvent(
					ModifiedSetting.OnHitEventName,
					ModifiedSetting.OnHitEventData,
					Character,
					TargetHumanoid,
					TrueDamage,
					IsHeadshot,
					IsCritical,
					Tool
				)
			end
		end
	else
		warn("Unable to register damage because player is no longer existing here")
	end
end

function InflictGunMelee(Player, Tool, Hit, ClientHitSize, ModuleName)
	if not Hit or not ClientHitSize or Hit.Size ~= ClientHitSize then
		warn("InflictGunMelee: invalid hit from", Player.Name)
		return
	end
	local hrp = Player.Character and Player.Character:FindFirstChild("HumanoidRootPart")
	if not hrp then
		return
	end
	local Target = Hit:FindFirstAncestorOfClass("Model")
	local TargetTorso = Target and (Target:FindFirstChild("HumanoidRootPart") or Target:FindFirstChild("Head"))
	if not TargetTorso then
		return
	end
	if (hrp.Position - TargetTorso.Position).Magnitude > 20 then
		warn("InflictGunMelee: out of range from", Player.Name)
		return
	end
	local Module = GetSetting(Tool, { ModuleName = ModuleName })
	if not Module then
		return
	end
	local Character = Player.Character
	local Humanoid = Character:FindFirstChildOfClass("Humanoid")
	local IsHeadshot = (Hit and Hit.Name == "Head" and Module.MeleeHeadshotHitmarker)
	local TrueDamage = Module.MeleeDamage * (Module.MeleeDamageMultipliers[Hit.Name] or 1)
	if Player and Character and Humanoid then
		local TargetHumanoid = Target and Target:FindFirstChildOfClass("Humanoid")
		if TargetHumanoid and TargetHumanoid.Health ~= 0 and TargetTorso then
			local GuaranteedDebuff = false
			if not DamageModule.CanDamage(TargetHumanoid.Parent, Character, Module.FriendlyFire) then
				return
			end
			while TargetHumanoid:FindFirstChild("creator") do
				TargetHumanoid.creator:Destroy()
			end
			local Creator = Instance.new("ObjectValue")
			Creator.Name = "creator"
			Creator.Value = Player
			Creator.Parent = TargetHumanoid
			Debris:AddItem(Creator, 5)
			local IsCritical = Module.MeleeCriticalDamageEnabled
				and (Random.new():NextInteger(0, 100) <= Module.MeleeCriticalBaseChance)
			if IsCritical then
				TrueDamage = TrueDamage * Module.MeleeCriticalDamageMultiplier
				GuaranteedDebuff = Module.ApplyMeleeDebuffOnCritical
			end
			TrueDamage = math.max(0, TrueDamage)
			TargetHumanoid:TakeDamage(TrueDamage)
			if Module.MeleeKnockback > 0 then
				local Shover = Character:FindFirstChild("HumanoidRootPart") or Character:FindFirstChild("Head")
				local Duration = 0.1
				local Speed = Module.MeleeKnockback / Duration
				local Velocity = (TargetTorso.Position - Shover.Position).Unit * Speed
				local ShoveForce = Instance.new("BodyVelocity")
				ShoveForce.MaxForce = Vector3.new(1e9, 1e9, 1e9)
				ShoveForce.Velocity = Velocity
				ShoveForce.Parent = TargetTorso
				Debris:AddItem(ShoveForce, Duration)
			end
			if Module.MeleeLifesteal > 0 and Humanoid.Health ~= 0 then
				Humanoid.Health = Humanoid.Health + TrueDamage * Module.MeleeLifesteal
			end
			if Module.MeleeDebuff and Module.MeleeDebuffName ~= "" then
				local Roll = Random.new():NextInteger(0, 100)
				if Roll <= Module.MeleeDebuffChance or GuaranteedDebuff then
					if not TargetHumanoid.Parent:FindFirstChild(Module.MeleeDebuffName) then
						local Debuff = Miscs.Debuffs[Module.MeleeDebuffName]:Clone()
						Debuff.creator.Value = Creator.Value
						Debuff.Parent = TargetHumanoid.Parent
						Debuff.Disabled = false
					end
				end
			end
			if Module.OnMeleeHitEventName ~= "None" then
				FireOnHitEvent(
					Module.OnMeleeHitEventName,
					Module.OnMeleeHitEventData,
					Character,
					TargetHumanoid,
					TrueDamage,
					IsHeadshot,
					IsCritical,
					Tool
				)
			end
		end
	else
		warn("Unable to register damage because player/character is no longer existing here")
	end
end

function InflictGunLaser(Player, Tool, Hit, Misc)
	Misc = DecodePacket(Misc)
	if not Hit or not Misc.ClientHitSize or Hit.Size ~= Misc.ClientHitSize then
		warn("InflictGunLaser: invalid hit from", Player.Name)
		return
	end
	local hrp = Player.Character and Player.Character:FindFirstChild("HumanoidRootPart")
	if not hrp then
		return
	end

	-- Laser hit must still be within a sane distance of the player
	local Target = Hit:FindFirstAncestorOfClass("Model")
	if not Target then
		return
	end
	local TargetTorso = Target:FindFirstChild("HumanoidRootPart") or Target:FindFirstChild("Head")
	if not TargetTorso then
		return
	end

	local Module =
		GetSetting(Tool, { ModuleName = Misc.ModuleName, ModNames = Misc.ModNames, BulletId = Misc.BulletId })
	if not Module then
		return
	end

	local MaxRange = AddressTableValue(Misc.ChargeLevel, "Range", Module)
	if (hrp.Position - TargetTorso.Position).Magnitude > MaxRange + 30 then
		warn("InflictGunLaser: out of range from", Player.Name)
		return
	end

	local ModifiedSetting = {
		LaserTrailDamage = AddressTableValue(Misc.ChargeLevel, "LaserTrailDamage", Module),
		LaserTrailCriticalBaseChance = AddressTableValue(Misc.ChargeLevel, "LaserTrailCriticalBaseChance", Module),
		LaserTrailCriticalDamageMultiplier = AddressTableValue(
			Misc.ChargeLevel,
			"LaserTrailCriticalDamageMultiplier",
			Module
		),
		LaserTrailKnockback = AddressTableValue(Misc.ChargeLevel, "LaserTrailKnockback", Module),
		LaserTrailLifesteal = AddressTableValue(Misc.ChargeLevel, "LaserTrailLifesteal", Module),
		LaserTrailDebuffName = AddressTableValue(Misc.ChargeLevel, "LaserTrailDebuffName", Module),
		LaserTrailDebuffChance = AddressTableValue(Misc.ChargeLevel, "LaserTrailDebuffChance", Module),
		ApplyLaserTrailDebuffOnCritical = AddressTableValue(
			Misc.ChargeLevel,
			"ApplyLaserTrailDebuffOnCritical",
			Module
		),
		OnLaserHitEventName = AddressTableValue(Misc.ChargeLevel, "OnLaserHitEventName", Module),
		OnLaserHitEventData = AddressTableValue(Misc.ChargeLevel, "OnLaserHitEventData", Module),
	}
	local Character = Player.Character
	local Humanoid = Character:FindFirstChildOfClass("Humanoid")
	local TrueDamage = ModifiedSetting.LaserTrailDamage
	if Player and Character and Humanoid then
		local TargetHumanoid = Target:FindFirstChildOfClass("Humanoid")
		if TargetHumanoid and TargetHumanoid.Health ~= 0 and TargetTorso then
			local GuaranteedDebuff = false
			if not DamageModule.CanDamage(TargetHumanoid.Parent, Character, Module.FriendlyFire) then
				return
			end
			while TargetHumanoid:FindFirstChild("creator") do
				TargetHumanoid.creator:Destroy()
			end
			local Creator = Instance.new("ObjectValue")
			Creator.Name = "creator"
			Creator.Value = Player
			Creator.Parent = TargetHumanoid
			Debris:AddItem(Creator, 5)
			local IsCritical = Module.LaserTrailCriticalDamageEnabled
				and (Random.new():NextInteger(0, 100) <= ModifiedSetting.LaserTrailCriticalBaseChance)
			if IsCritical then
				TrueDamage = TrueDamage * ModifiedSetting.LaserTrailCriticalDamageMultiplier
				GuaranteedDebuff = ModifiedSetting.ApplyLaserTrailDebuffOnCritical
			end
			TrueDamage = math.max(0, TrueDamage)
			TargetHumanoid:TakeDamage(TrueDamage)
			if ModifiedSetting.LaserTrailKnockback > 0 then
				local Shover = Character:FindFirstChild("HumanoidRootPart") or Character:FindFirstChild("Head")
				local Duration = 0.1
				local Speed = ModifiedSetting.LaserTrailKnockback / Duration
				local Velocity = (TargetTorso.Position - Shover.Position).Unit * Speed
				local ShoveForce = Instance.new("BodyVelocity")
				ShoveForce.MaxForce = Vector3.new(1e9, 1e9, 1e9)
				ShoveForce.Velocity = Velocity
				ShoveForce.Parent = TargetTorso
				Debris:AddItem(ShoveForce, Duration)
			end
			if ModifiedSetting.LaserTrailLifesteal > 0 and Humanoid.Health ~= 0 then
				Humanoid.Health = Humanoid.Health + TrueDamage * ModifiedSetting.LaserTrailLifesteal
			end
			if Module.LaserTrailDebuff and ModifiedSetting.LaserTrailDebuffName ~= "" then
				local Roll = Random.new():NextInteger(0, 100)
				if Roll <= ModifiedSetting.LaserTrailDebuffChance or GuaranteedDebuff then
					if not TargetHumanoid.Parent:FindFirstChild(ModifiedSetting.LaserTrailDebuffName) then
						local Debuff = Miscs.Debuffs[ModifiedSetting.LaserTrailDebuffName]:Clone()
						Debuff.creator.Value = Creator.Value
						Debuff.Parent = TargetHumanoid.Parent
						Debuff.Disabled = false
					end
				end
			end
			if ModifiedSetting.OnLaserHitEventName ~= "None" then
				FireOnHitEvent(
					ModifiedSetting.OnLaserHitEventName,
					ModifiedSetting.OnLaserHitEventData,
					Character,
					TargetHumanoid,
					TrueDamage,
					false,
					IsCritical,
					Tool
				)
			end
		end
	else
		warn("Unable to register damage because player is no longer existing here")
	end
end

-- ============================================================
-- InflictTarget — the main gate. All damage flows through here.
-- ============================================================
Remotes.InflictTarget.OnServerEvent:Connect(function(Player, Type, Tool, Hit, Misc)
	local ok, err = pcall(function()
		-- 1. Player must be alive to deal damage
		if not playerIsAlive(Player) then
			return
		end

		-- 2. Per-player rate limit
		if not canProcessInflict(Player) then
			return
		end

		-- 3. Tool must be held by this player right now
		if not Tool or Tool.Parent ~= Player.Character then
			return
		end

		-- 4. Hit must exist in the world
		if not Hit or not Hit:IsDescendantOf(Workspace) then
			return
		end

		-- 5. Type whitelist
		if Type ~= "Gun" and Type ~= "GunMelee" and Type ~= "GunLaser" then
			warn("InflictTarget: invalid type from", Player.Name)
			return
		end

		-- 6. Target must be alive
		local Target = Hit:FindFirstAncestorOfClass("Model")
		local TargetHumanoid = Target and Target:FindFirstChildOfClass("Humanoid")
		if not TargetHumanoid or TargetHumanoid.Health <= 0 then
			return
		end

		-- 7. Basic geometry checks
		local hrp = Player.Character:FindFirstChild("HumanoidRootPart")
		local targetTorso = Target:FindFirstChild("HumanoidRootPart") or Target:FindFirstChild("Head")
		if not hrp or not targetTorso then
			return
		end

		-- 8. Decode and validate Misc
		local DecodedMisc = DecodePacket(Misc)
		if type(DecodedMisc) ~= "table" then
			return
		end

		-- 9. ChargeLevel must be a valid number
		if not isValidChargeLevel(DecodedMisc.ChargeLevel) then
			warn("InflictTarget: invalid ChargeLevel from", Player.Name)
			return
		end

		-- 10. Bullet-ID verification for Gun type:
		--     The bullet must have been registered via VisualizeBullet,
		--     proving the client actually fired a shot.
		if Type == "Gun" or Type == "GunLaser" then
			local bulletId = DecodedMisc.BulletId
			-- Melee and laser-beam (no BulletId) skip this check
			if bulletId ~= nil then
				local entry = consumeBullet(Player, bulletId)
				if not entry then
					warn("InflictTarget: unregistered or expired BulletId from", Player.Name, bulletId)
					return
				end
				-- Make sure the bullet's tool matches
				if entry.Tool ~= Tool then
					warn("InflictTarget: BulletId tool mismatch from", Player.Name)
					return
				end
			end
		end

		-- 11. Server-side range check (after bullet verification)
		local Module = GetSetting(Tool, {
			ModuleName = DecodedMisc.ModuleName,
			ModNames = DecodedMisc.ModNames,
			BulletId = DecodedMisc.BulletId,
		})
		if not Module then
			return
		end

		local MaxRange = AddressTableValue(DecodedMisc.ChargeLevel, "Range", Module)
		local serverDist = (hrp.Position - targetTorso.Position).Magnitude

		-- Melee uses its own tighter check inside InflictGunMelee (20 studs)
		if Type ~= "GunMelee" and serverDist > MaxRange + 30 then
			warn("InflictTarget: out of range from", Player.Name, serverDist, ">", MaxRange)
			return
		end

		-- 12. Dispatch
		if Type == "Gun" then
			InflictGun(Player, Tool, Hit, Misc)
		elseif Type == "GunMelee" then
			if not DecodedMisc.ClientHitSize then
				return
			end
			InflictGunMelee(Player, Tool, Hit, DecodedMisc.ClientHitSize, DecodedMisc.ModuleName)
		elseif Type == "GunLaser" then
			InflictGunLaser(Player, Tool, Hit, Misc)
		end
	end)
	if not ok then
		warn("InflictTarget error from", Player.Name, err)
	end
end)

-- ============================================================
-- NPC SECTION (unchanged logic, kept intact)
-- ============================================================
do
	local Caster = FastCast.new()
	local ShootId = 0
	local RayUpdaters = {}
	local IgnoreList = {}

	local function ClampMagnitude(Vector, Max)
		if Vector.Magnitude == 0 then
			return Vector3.new(0, 0, 0)
		end
		return Vector.Unit * math.min(Vector.Magnitude, Max)
	end

	local function CastRay(Cast, Origin, Direction, Blacklist, IgnoreWater, RealTargetHumanoid)
		debug.profilebegin("CastRay_(GunServerScript)")
		if RealTargetHumanoid then
			Blacklist = CloneTable(IgnoreList)
		end
		local Iterations = 0
		local NewRay = Ray.new(Origin, Direction)
		local HitPart, HitPoint, HitNormal, HitMaterial =
			nil, Origin + Direction, Vector3.new(0, 1, 0), Enum.Material.Air
		while Iterations < 20 do
			Iterations += 1
			HitPart, HitPoint, HitNormal, HitMaterial =
				Workspace:FindPartOnRayWithIgnoreList(NewRay, Blacklist, false, IgnoreWater)
			if HitPart then
				local Target = HitPart:FindFirstAncestorOfClass("Model")
				local TargetHumanoid = Target and Target:FindFirstChildOfClass("Humanoid")
				local CanBlock = Target and Target:FindFirstChild("CanBlock")
				local TargetTool = HitPart:FindFirstAncestorOfClass("Tool")
				local CanDamage =
					DamageModule.CanDamage(Target, Cast.UserData.Character, Cast.UserData.Setting.FriendlyFire)
				if
					RealTargetHumanoid
					and Cast.UserData.Setting.ExplosiveEnabled
					and Cast.UserData.Setting.SelfDamage
				then
					if Cast.UserData.Character and RealTargetHumanoid.Parent.Name == Cast.UserData.Character.Name then
						CanDamage = (RealTargetHumanoid.Parent.Name == Cast.UserData.Character.Name)
					end
				end
				if
					HitPart.Transparency > 0.75
					or HitPart.Name == "Handle"
					or (TargetHumanoid and (TargetHumanoid.Health <= 0 or not CanDamage or (Cast.UserData.BounceData and table.find(
						Cast.UserData.BounceData.BouncedHumanoids,
						TargetHumanoid
					)) or (RealTargetHumanoid and RealTargetHumanoid ~= TargetHumanoid)))
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
		debug.profileend()
		return HitPart, HitPoint, HitNormal, HitMaterial
	end

	local function PopulateHumanoids(Cast)
		for _, v in pairs(CollectionService:GetTagged("Humanoids")) do
			if
				v.Parent ~= Cast.UserData.Character
				and DamageModule.CanDamage(v.Parent, Cast.UserData.Character, Cast.UserData.Setting.FriendlyFire)
			then
				table.insert(Humanoids, v)
			end
		end
	end

	local function FindNearestEntity(Cast, Position)
		Humanoids = {}
		PopulateHumanoids(Cast)
		local Dist = Cast.UserData.HomeData.HomingDistance
		local TargetModel, TargetHumanoid, TargetTorso = nil, nil, nil
		for i, v in ipairs(Humanoids) do
			local torso = v.Parent:FindFirstChild("HumanoidRootPart") or v.Parent:FindFirstChild("Torso")
			if
				v
				and torso
				and (torso.Position - Position).Magnitude < (Dist + (torso.Size.Magnitude / 2.5))
				and v.Health > 0
			then
				local hit = not Cast.UserData.HomeData.HomeThroughWall
						and CastRay(
							Cast,
							Position,
							(torso.CFrame.p - Position).Unit * 999,
							Cast.UserData.IgnoreList,
							true
						)
					or nil
				local CanTrack = true
				if not Cast.UserData.HomeData.HomeThroughWall then
					CanTrack = (hit and hit:IsDescendantOf(v.Parent))
				end
				if
					CanTrack
					and DamageModule.CanDamage(v.Parent, Cast.UserData.Character, Cast.UserData.Setting.FriendlyFire)
				then
					TargetModel = v.Parent
					TargetHumanoid = v
					TargetTorso = torso
					Dist = (Position - torso.Position).Magnitude
				end
			end
		end
		return TargetModel, TargetHumanoid, TargetTorso
	end

	function InflictGunNPC(Tool, Setting, TargetHumanoid, TargetTorso, Hit, Misc, HitDist)
		local Character = Tool.Parent
		local Humanoid = Character:FindFirstChildOfClass("Humanoid")
		local IsHeadshot = (Hit and Hit.Name == "Head" and Setting.HeadshotHitmarker)
		local TrueDamage
		if HitDist and Setting.ExplosiveEnabled then
			local DamageMultiplier = (1 - math.clamp((HitDist / Setting.ExplosionRadius), 0, 1))
			TrueDamage = Setting.DamageBasedOnDistance
					and (Setting.BaseDamage * (Setting.DamageMultipliers[Hit.Name] or 1)) * DamageMultiplier
				or Setting.BaseDamage * (Setting.DamageMultipliers[Hit.Name] or 1)
		else
			TrueDamage = Setting.DamageDropOffEnabled
					and CalculateDamage(
						Setting.BaseDamage * (Setting.DamageMultipliers[Hit.Name] or 1),
						HitDist,
						Setting.ZeroDamageDistance,
						Setting.FullDamageDistance
					)
				or Setting.BaseDamage * (Setting.DamageMultipliers[Hit.Name] or 1)
		end
		if Character and Humanoid then
			if TargetHumanoid and TargetHumanoid.Health ~= 0 and TargetTorso then
				local GuaranteedDebuff = false
				local CanDamage = DamageModule.CanDamage(TargetHumanoid.Parent, Character, Setting.FriendlyFire)
				if Setting.ExplosiveEnabled and Setting.SelfDamage then
					if TargetHumanoid.Parent.Name == Character.Name then
						CanDamage = (TargetHumanoid.Parent.Name == Character.Name)
						if Setting.ReduceSelfDamageOnAirOnly then
							TrueDamage = TargetHumanoid:GetState() ~= Enum.HumanoidStateType.Freefall and TrueDamage
								or (TrueDamage * (1 - Setting.SelfDamageRedution))
						else
							TrueDamage = TrueDamage * (1 - Setting.SelfDamageRedution)
						end
					end
				end
				if not CanDamage then
					return
				end
				while TargetHumanoid:FindFirstChild("creator") do
					TargetHumanoid.creator:Destroy()
				end
				local Creator = Instance.new("ObjectValue")
				Creator.Name = "creator"
				Creator.Value = Tool.Parent
				Creator.Parent = TargetHumanoid
				Debris:AddItem(Creator, 5)
				local IsCritical = Setting.CriticalDamageEnabled
					and (Random.new():NextInteger(0, 100) <= Setting.CriticalBaseChance)
				if IsCritical then
					TrueDamage = TrueDamage * Setting.CriticalDamageMultiplier
					GuaranteedDebuff = Setting.ApplyDebuffOnCritical
				end
				TrueDamage = math.max(0, TrueDamage)
				TargetHumanoid:TakeDamage(TrueDamage)
				if Setting.Knockback > 0 and not (Setting.ExplosiveEnabled and Setting.ExplosionKnockback) then
					local Shover = Character:FindFirstChild("HumanoidRootPart") or Character:FindFirstChild("Head")
					local Duration = 0.1
					local Speed = Setting.Knockback / Duration
					local Velocity = (TargetTorso.Position - Shover.Position).Unit * Speed
					local ShoveForce = Instance.new("BodyVelocity")
					ShoveForce.MaxForce = Vector3.new(1e9, 1e9, 1e9)
					ShoveForce.Velocity = Velocity
					ShoveForce.Parent = TargetTorso
					Debris:AddItem(ShoveForce, Duration)
				end
				if Setting.Lifesteal > 0 and Humanoid.Health ~= 0 then
					Humanoid.Health = Humanoid.Health + TrueDamage * Setting.Lifesteal
				end
				if Setting.Debuff and Setting.DebuffName ~= "" then
					local Roll = Random.new():NextInteger(0, 100)
					if Roll <= Setting.DebuffChance or GuaranteedDebuff then
						if not TargetHumanoid.Parent:FindFirstChild(Setting.DebuffName) then
							local Debuff = Miscs.Debuffs[Setting.DebuffName]:Clone()
							Debuff.creator.Value = Creator.Value
							Debuff.Parent = TargetHumanoid.Parent
							Debuff.Disabled = false
						end
					end
				end
				if Setting.OnHitEventName ~= "None" then
					FireOnHitEvent(
						Setting.OnHitEventName,
						Setting.OnHitEventData,
						Character,
						TargetHumanoid,
						TrueDamage,
						IsHeadshot,
						IsCritical,
						Tool
					)
				end
			end
		else
			warn("Unable to register damage because npc is no longer existing here")
		end
	end

	function InflictTargetNPC(Type, ...)
		if Type == "Gun" then
			InflictGunNPC(...)
		end
	end

	function OnRayFinalHit(Cast, Origin, Direction, RaycastResult, SegmentVelocity, CosmeticBulletObject, Blocked)
		local EndPos = RaycastResult and RaycastResult.Position or Cast.UserData.SegmentOrigin
		if Blocked then
			return
		end
		if not Cast.UserData.Setting.ExplosiveEnabled then
			if not RaycastResult then
				return
			end
			if RaycastResult.Instance and RaycastResult.Instance.Parent then
				if not Cast.UserData.Setting.BlacklistParts[RaycastResult.Instance.Name] then
					local Distance = (RaycastResult.Position - Origin).Magnitude
					local Target = RaycastResult.Instance:FindFirstAncestorOfClass("Model")
					local TargetHumanoid = Target and Target:FindFirstChildOfClass("Humanoid")
					local TargetTorso = Target
						and (Target:FindFirstChild("HumanoidRootPart") or Target:FindFirstChild("Head"))
					if TargetHumanoid and TargetHumanoid.Health > 0 and TargetTorso then
						task.spawn(function()
							InflictTargetNPC(
								"Gun",
								Cast.UserData.Tool,
								Cast.UserData.Setting,
								TargetHumanoid,
								TargetTorso,
								RaycastResult.Instance,
								Cast.UserData.Misc,
								Distance
							)
						end)
					end
				end
			end
		else
			local Explosion = Instance.new("Explosion")
			Explosion.Name = "NoShake"
			Explosion.BlastRadius = Cast.UserData.Setting.ExplosionRadius
			Explosion.BlastPressure = 0
			Explosion.ExplosionType = Enum.ExplosionType.NoCraters
			Explosion.Position = EndPos
			Explosion.Visible = false
			Explosion.Parent = Workspace
			Explosion.DestroyJointRadiusPercent = 0
			local HitHumanoids = {}
			Explosion.Hit:Connect(function(HitPart, HitDist)
				if HitPart then
					local Target = HitPart:FindFirstAncestorOfClass("Model")
					local TargetHumanoid = Target and Target:FindFirstChildOfClass("Humanoid")
					local TargetTorso = Target
						and (Target:FindFirstChild("HumanoidRootPart") or Target:FindFirstChild("Head"))
					if TargetHumanoid and TargetHumanoid.Health > 0 and TargetTorso then
						if not HitHumanoids[TargetHumanoid] then
							HitHumanoids[TargetHumanoid] = true
							local DamageThroughWall = Cast.UserData.Setting.DamageThroughWall
							local Hit2 = not DamageThroughWall
									and CastRay(
										Cast,
										Explosion.Position,
										(TargetTorso.CFrame.p - Explosion.Position).Unit * 999,
										Cast.UserData.IgnoreList,
										true,
										TargetHumanoid
									)
								or nil
							local CanHit = true
							if not DamageThroughWall then
								CanHit = (Hit2 and Hit2:IsDescendantOf(Target))
							end
							if not CanHit then
								return
							end
							if Cast.UserData.Setting.ExplosionKnockback then
								local Multipler = Cast.UserData.Setting.ExplosionKnockbackMultiplierOnTarget
								local VelocityMod = (TargetTorso.Position - Explosion.Position).Unit
									* Cast.UserData.Setting.ExplosionKnockbackPower
								local AirVelocity = TargetTorso.Velocity
									- Vector3.new(0, TargetTorso.Velocity.Y, 0)
									+ Vector3.new(VelocityMod.X, 0, VelocityMod.Z)
								if
									DamageModule.CanDamage(
										Target,
										Cast.UserData.Character,
										Cast.UserData.Setting.FriendlyFire
									)
								then
									local TorsoFly = Instance.new("BodyVelocity")
									TorsoFly.MaxForce = Vector3.new(math.huge, 0, math.huge)
									TorsoFly.Velocity = AirVelocity
									TorsoFly.Parent = TargetTorso
									TargetTorso.Velocity = TargetTorso.Velocity
										+ Vector3.new(0, VelocityMod.Y * Multipler, 0)
									Debris:AddItem(TorsoFly, 0.5)
								else
									if TargetHumanoid.Parent.Name == Cast.UserData.Character.Name then
										Multipler = Cast.UserData.Setting.ExplosionKnockbackMultiplierOnPlayer
										local TorsoFly = Instance.new("BodyVelocity")
										TorsoFly.MaxForce = Vector3.new(math.huge, 0, math.huge)
										TorsoFly.Velocity = AirVelocity
										TorsoFly.Parent = TargetTorso
										TargetTorso.Velocity = TargetTorso.Velocity
											+ Vector3.new(0, VelocityMod.Y * Multipler, 0)
										Debris:AddItem(TorsoFly, 0.5)
									end
								end
							end
							task.spawn(function()
								InflictTargetNPC(
									"Gun",
									Cast.UserData.Tool,
									Cast.UserData.Setting,
									TargetHumanoid,
									TargetTorso,
									HitPart,
									Cast.UserData.Misc,
									HitDist
								)
							end)
						end
					end
				end
			end)
		end
	end

	function OnRayHit(Cast, Origin, Direction, RaycastResult, SegmentVelocity, CosmeticBulletObject, Reflected)
		local CanBounce = Cast.UserData.CastBehavior.Hitscan and true or false
		local CurrentPosition = Cast:GetPosition()
		local CurrentVelocity = Cast:GetVelocity()
		local Acceleration = Cast.UserData.CastBehavior.Acceleration
		local Position = Cast.RayInfo.RaycastHitbox and Cast.UserData.BounceData.CurrentAnchorPoint
			or RaycastResult.Position
		if Cast.RayInfo.ShapeCast then
			Position = Cast.UserData.BounceData.CurrentAnchorPoint + SegmentVelocity.Unit * RaycastResult.Distance
		end
		if Reflected then
			if not Cast.UserData.CastBehavior.Hitscan then
				if CurrentVelocity.Magnitude > 0 then
					local CurrentDirection = SegmentVelocity.Unit
					local NewDirection = CurrentDirection
						- (2 * CurrentDirection:Dot(RaycastResult.Normal) * RaycastResult.Normal)
					Cast:SetVelocity(NewDirection * SegmentVelocity.Magnitude)
					Cast:SetPosition(Position)
				end
			else
				local CurrentDirection = Cast.RayInfo.ModifiedDirection
				local NewDirection = CurrentDirection
					- (2 * CurrentDirection:Dot(RaycastResult.Normal) * RaycastResult.Normal)
				Cast.RayInfo.ModifiedDirection = NewDirection
			end
		else
			if not Cast.UserData.CastBehavior.Hitscan then
				Cast.UserData.SpinData.InitalTick = os.clock()
				Cast.UserData.SpinData.InitalAngularVelocity = RaycastResult.Normal:Cross(CurrentVelocity) / 0.2
				Cast.UserData.SpinData.InitalRotation = (Cast.RayInfo.CurrentCFrame - Cast.RayInfo.CurrentCFrame.p)
				Cast.UserData.SpinData.ProjectileOffset = 0.2 * RaycastResult.Normal
				if CurrentVelocity.Magnitude > 0 then
					local NormalizeBounce = false
					local Target = RaycastResult.Instance:FindFirstAncestorOfClass("Model")
					local TargetHumanoid = Target and Target:FindFirstChildOfClass("Humanoid")
					local TargetTorso = Target
						and (Target:FindFirstChild("HumanoidRootPart") or Target:FindFirstChild("Head"))
					if Cast.UserData.BounceData.BounceBetweenHumanoids then
						if TargetHumanoid and TargetHumanoid.Health > 0 and TargetTorso then
							if not table.find(Cast.UserData.BounceData.BouncedHumanoids, TargetHumanoid) then
								table.insert(Cast.UserData.BounceData.BouncedHumanoids, TargetHumanoid)
							end
						end
						local TrackedEntity, TrackedHumanoid, TrackedTorso = FindNearestEntity(Cast, Position)
						if TrackedEntity and TrackedHumanoid and TrackedTorso and TrackedHumanoid.Health > 0 then
							local DesiredVector = (TrackedTorso.Position - Position).Unit
							if Cast.UserData.BounceData.PredictDirection then
								local Pos, Vel = DirectionPredictor(
									Position,
									TrackedTorso.Position,
									Vector3.new(),
									TrackedTorso.Velocity,
									Acceleration,
									(2 * TrackedTorso.Velocity) / 3,
									SegmentVelocity.Magnitude
								)
								if Pos and Vel then
									DesiredVector = Vel.Unit
								end
							end
							Cast:SetVelocity(DesiredVector * SegmentVelocity.Magnitude)
							Cast:SetPosition(Position)
							if Cast.RayInfo.RaycastHitbox or Cast.RayInfo.ShapeCast then
								Cast.UserData.BounceData.LastBouncedObject = TargetHumanoid and TargetHumanoid.Parent
									or RaycastResult.Instance
								Cast.UserData.BounceData.BounceDeltaTime = 0
							end
						else
							NormalizeBounce = true
						end
					else
						NormalizeBounce = true
					end
					if NormalizeBounce then
						local Delta = Position - CurrentPosition
						local Fix = 1 - 0.001 / Delta.Magnitude
						Fix = Fix < 0 and 0 or Fix
						Cast:AddPosition(Fix * Delta + 0.05 * RaycastResult.Normal)
						local NewNormal = RaycastResult.Normal
						local NewVelocity = CurrentVelocity
						if
							Cast.UserData.BounceData.IgnoreSlope
							and (Acceleration ~= Vector3.new(0, 0, 0) and Acceleration.Y < 0)
						then
							local NewPosition = Cast:GetPosition()
							NewVelocity = Vector3.new(
								CurrentVelocity.X,
								-Cast.UserData.BounceData.BounceHeight,
								CurrentVelocity.Z
							)
							local Instance2, Position2, Normal2, Material2 =
								CastRay(Cast, NewPosition, Vector3.new(0, 1, 0), Cast.UserData.IgnoreList, true)
							if Instance2 then
								NewVelocity = Vector3.new(
									CurrentVelocity.X,
									Cast.UserData.BounceData.BounceHeight,
									CurrentVelocity.Z
								)
							end
							local SlopeAngle = Math.GetSlopeAngle(RaycastResult.Normal)
							NewNormal = SlopeAngle >= Cast.UserData.BounceData.SlopeAngle and RaycastResult.Normal
								or Vector3.new(0, RaycastResult.Normal.Y, 0)
						end
						local NormalVelocity = Vector3.new().Dot(NewNormal, NewVelocity) * NewNormal
						local TanVelocity = NewVelocity - NormalVelocity
						local D1 = -Vector3.new().Dot(NewNormal, Acceleration)
						local D2 = -(1 + Cast.UserData.BounceData.BounceElasticity)
							* Vector3.new().Dot(NewNormal, NewVelocity)
						local GeometricDeceleration = 1
							- Cast.UserData.BounceData.FrictionConstant
								* (10 * (D1 < 0 and 0 or D1) * Cast.StateInfo.Delta + (D2 < 0 and 0 or D2))
								/ TanVelocity.Magnitude
						Cast:SetVelocity(
							(GeometricDeceleration < 0 and 0 or GeometricDeceleration) * TanVelocity
								- Cast.UserData.BounceData.BounceElasticity * NormalVelocity
						)
						if Cast.RayInfo.RaycastHitbox or Cast.RayInfo.ShapeCast then
							Cast.UserData.BounceData.LastBouncedObject = TargetHumanoid and TargetHumanoid.Parent
								or RaycastResult.Instance
							Cast.UserData.BounceData.BounceDeltaTime = 0
						end
					end
					CanBounce = true
				end
			else
				local NormalizeBounce = false
				if Cast.UserData.BounceData.BounceBetweenHumanoids then
					local Target = RaycastResult.Instance:FindFirstAncestorOfClass("Model")
					local TargetHumanoid = Target and Target:FindFirstChildOfClass("Humanoid")
					local TargetTorso = Target
						and (Target:FindFirstChild("HumanoidRootPart") or Target:FindFirstChild("Head"))
					if TargetHumanoid and TargetHumanoid.Health > 0 and TargetTorso then
						if not table.find(Cast.UserData.BounceData.BouncedHumanoids, TargetHumanoid) then
							table.insert(Cast.UserData.BounceData.BouncedHumanoids, TargetHumanoid)
						end
					end
					local TrackedEntity, TrackedHumanoid, TrackedTorso = FindNearestEntity(Cast, RaycastResult.Position)
					if TrackedEntity and TrackedHumanoid and TrackedTorso and TrackedHumanoid.Health > 0 then
						Cast.RayInfo.ModifiedDirection = (TrackedTorso.Position - RaycastResult.Position).Unit
					else
						NormalizeBounce = true
					end
				else
					NormalizeBounce = true
				end
				if NormalizeBounce then
					local CurrentDirection = Cast.RayInfo.ModifiedDirection
					Cast.RayInfo.ModifiedDirection = CurrentDirection
						- (2 * CurrentDirection:Dot(RaycastResult.Normal) * RaycastResult.Normal)
				end
			end
			if CanBounce and Cast.UserData.BounceData.CurrentBounces > 0 then
				Cast.UserData.BounceData.CurrentBounces -= 1
				if Cast.UserData.BounceData.NoExplosionWhileBouncing then
					if not Cast.UserData.Setting.BlacklistParts[RaycastResult.Instance.Name] then
						local Target = RaycastResult.Instance:FindFirstAncestorOfClass("Model")
						local TargetHumanoid = Target and Target:FindFirstChildOfClass("Humanoid")
						local Distance = (RaycastResult.Position - Origin).Magnitude
						local TargetTorso = Target
							and (Target:FindFirstChild("HumanoidRootPart") or Target:FindFirstChild("Head"))
						if TargetHumanoid and TargetHumanoid.Health > 0 and TargetTorso then
							task.spawn(function()
								InflictTargetNPC(
									"Gun",
									Cast.UserData.Tool,
									Cast.UserData.Setting,
									TargetHumanoid,
									TargetTorso,
									RaycastResult.Instance,
									Cast.UserData.Misc,
									Distance
								)
							end)
						end
					end
				else
					OnRayFinalHit(Cast, Origin, Direction, RaycastResult, SegmentVelocity, CosmeticBulletObject)
				end
			end
		end
	end

	local function CanRayHit(Cast, Origin, Direction, RaycastResult, SegmentVelocity, CosmeticBulletObject)
		local Target = RaycastResult.Instance:FindFirstAncestorOfClass("Model")
		if Cast.UserData.Setting.BlacklistParts[RaycastResult.Instance.Name] then
			if Cast.UserData.BounceData.StopBouncingOn == "Object" then
				return false
			end
		else
			local TargetHumanoid = Target and Target:FindFirstChildOfClass("Humanoid")
			local TargetTorso = Target and (Target:FindFirstChild("HumanoidRootPart") or Target:FindFirstChild("Head"))
			if TargetHumanoid and TargetHumanoid.Health > 0 and TargetTorso then
				if Cast.UserData.BounceData.StopBouncingOn == "Humanoid" then
					return false
				end
			else
				if Cast.UserData.BounceData.StopBouncingOn == "Object" then
					return false
				end
			end
		end
		local CanBlock = Target and Target:FindFirstChild("CanBlock")
		if Cast.UserData.Setting.BlockBullet and CanBlock then
			if Cast.UserData.Setting.ReflectBullet and CanBlock:FindFirstChild("CanReflect") then
				Cast.UserData.LastReflectingModel = Target
				return "Reflected"
			else
				return "Blocked"
			end
		else
			local Density = RaycastResult.Instance:GetMass()
				/ (RaycastResult.Instance.Size.X * RaycastResult.Instance.Size.Y * RaycastResult.Instance.Size.Z)
			local Dot = RaycastResult.Normal:Dot(SegmentVelocity.Unit)
			Dot = Dot
				* (Cast.UserData.BounceData.UsePartDensity and (10 / Density) or 1)
				* (Cast.UserData.BounceData.UseBulletSpeed and (SegmentVelocity.Magnitude / 2400) or 1)
			if not Cast.UserData.CastBehavior.Hitscan and Cast.UserData.BounceData.SuperBounce then
				return true
			else
				if
					(math.abs(Dot) <= math.cos(math.rad(math.clamp(Cast.UserData.BounceData.MaxBounceAngle, 0, 90))))
					and Cast.UserData.BounceData.CurrentBounces > 0
				then
					return true
				end
			end
		end
		return false
	end

	local function CanRayPenetrate(Cast, Origin, Direction, RaycastResult, SegmentVelocity, CosmeticBulletObject)
		if RaycastResult.Instance and RaycastResult.Instance.Parent then
			if
				Cast.UserData.Setting.IgnoreBlacklistedParts
				and Cast.UserData.Setting.BlacklistParts[RaycastResult.Instance.Name]
			then
				return true
			else
				local Target = RaycastResult.Instance:FindFirstAncestorOfClass("Model")
				local TargetHumanoid = Target and Target:FindFirstChildOfClass("Humanoid")
				local CanBlock = Target and Target:FindFirstChild("CanBlock")
				local TargetTool = RaycastResult.Instance:FindFirstAncestorOfClass("Tool")
				local TEAM = Cast.UserData.Character:FindFirstChild("TEAM")
				if
					RaycastResult.Instance.Transparency > 0.75
					or RaycastResult.Instance.Name == "Handle"
					or (TargetHumanoid and (TargetHumanoid.Health <= 0 or not DamageModule.CanDamage(
						Target,
						Cast.UserData.Character,
						Cast.UserData.Setting.FriendlyFire
					) or (Cast.UserData.PenetrationData and table.find(
						Cast.UserData.PenetrationData.HitHumanoids,
						TargetHumanoid
					)) or (Cast.UserData.BounceData and table.find(
						Cast.UserData.BounceData.BouncedHumanoids,
						TargetHumanoid
					))))
					or (CanBlock and ((TEAM and CanBlock:FindFirstChild("TEAM")) and CanBlock.TEAM.Value == TEAM.Value))
					or TargetTool
				then
					return true
				else
					if Cast.UserData.LastReflectingModel and Cast.UserData.LastReflectingModel == Target then
						return true
					end
					if Cast.UserData.PenetrationData then
						local Density = RaycastResult.Instance:GetMass()
							/ (
								RaycastResult.Instance.Size.X
								* RaycastResult.Instance.Size.Y
								* RaycastResult.Instance.Size.Z
							)
						local Dot = RaycastResult.Normal:Dot(SegmentVelocity.Unit)
						Dot = Dot
							* (Cast.UserData.BounceData.UsePartDensity and (10 / Density) or 1)
							* (Cast.UserData.BounceData.UseBulletSpeed and (SegmentVelocity.Magnitude / 2400) or 1)
						if
							(
								math.abs(Dot)
								<= math.cos(math.rad(math.clamp(Cast.UserData.BounceData.MaxBounceAngle, 0, 90)))
							) and Cast.UserData.BounceData.CurrentBounces > 0
						then
							return false
						end
						local MaxExtent = RaycastResult.Instance.Size.Magnitude * Direction
						local ExitHit, ExitPoint, ExitNormal, ExitMaterial = Workspace:FindPartOnRayWithWhitelist(
							Ray.new(RaycastResult.Position + MaxExtent, -MaxExtent),
							{ RaycastResult.Instance },
							Cast.RayInfo.Parameters.IgnoreWater
						)
						local Diff = ExitPoint - RaycastResult.Position
						local Dist = Direction:Dot(Diff)
						if Cast.UserData.Setting.PenetrationType == "WallPenetration" then
							if Dist >= Cast.UserData.PenetrationData.PenetrationDepth then
								return false
							end
						elseif Cast.UserData.Setting.PenetrationType == "HumanoidPenetration" then
							if Cast.UserData.PenetrationData.PenetrationAmount <= 0 then
								return false
							end
						end
						local Modifier = Cast.UserData.PenetrationData.PenetrationModifiers[RaycastResult.Material.Name]
									~= nil
								and math.max(
									0,
									Cast.UserData.PenetrationData.PenetrationModifiers[RaycastResult.Material.Name]
								)
							or 1
						if Cast.UserData.Setting.BlacklistParts[RaycastResult.Instance.Name] then
							if Cast.UserData.Setting.PenetrationType == "WallPenetration" then
								Cast.UserData.PenetrationData.PenetrationDepth -= (Dist * Modifier)
								return true
							end
						else
							local Distance = (RaycastResult.Position - Origin).Magnitude
							local TargetTorso = Target
								and (Target:FindFirstChild("HumanoidRootPart") or Target:FindFirstChild("Head"))
							if TargetHumanoid and TargetHumanoid.Health > 0 and TargetTorso then
								if not table.find(Cast.UserData.PenetrationData.HitHumanoids, TargetHumanoid) then
									table.insert(Cast.UserData.PenetrationData.HitHumanoids, TargetHumanoid)
									task.spawn(function()
										InflictTargetNPC(
											"Gun",
											Cast.UserData.Tool,
											Cast.UserData.Setting,
											TargetHumanoid,
											TargetTorso,
											RaycastResult.Instance,
											Cast.UserData.Misc,
											Distance
										)
									end)
									if Cast.UserData.Setting.PenetrationType == "WallPenetration" then
										Cast.UserData.PenetrationData.PenetrationDepth -= (Dist * Modifier)
									elseif Cast.UserData.Setting.PenetrationType == "HumanoidPenetration" then
										Cast.UserData.PenetrationData.PenetrationAmount -= 1
									end
									if Cast.UserData.PenetrationData.PenetrationIgnoreDelay ~= math.huge then
										task.delay(Cast.UserData.PenetrationData.PenetrationIgnoreDelay, function()
											local Index =
												table.find(Cast.UserData.PenetrationData.HitHumanoids, TargetHumanoid)
											if Index then
												table.remove(Cast.UserData.PenetrationData.HitHumanoids, Index)
											end
										end)
									end
									return true
								end
							else
								if Cast.UserData.Setting.PenetrationType == "WallPenetration" then
									Cast.UserData.PenetrationData.PenetrationDepth -= (Dist * Modifier)
									return true
								end
							end
						end
					end
					if
						Cast.UserData.BounceData.LastBouncedObject
						and (
							Cast.UserData.BounceData.LastBouncedObject
							== (TargetHumanoid and TargetHumanoid.Parent or RaycastResult.Instance)
						)
					then
						return true
					end
				end
			end
		end
		return false
	end

	function OnRayUpdated(
		Cast,
		LastSegmentOrigin,
		SegmentOrigin,
		SegmentDirection,
		Length,
		SegmentVelocity,
		CosmeticBulletObject
	)
		Cast.UserData.LastSegmentOrigin = LastSegmentOrigin
		Cast.UserData.SegmentOrigin = SegmentOrigin
		Cast.UserData.SegmentDirection = SegmentDirection
		Cast.UserData.SegmentVelocity = SegmentVelocity
		local Tick = os.clock() - Cast.UserData.SpinData.InitalTick
		if Cast.UserData.UpdateData.UpdateRayInExtra then
			local RayUpdater = Cast.UserData.UpdateData.ExtraRayUpdater
			if not RayUpdaters[RayUpdater] then
				if RayUpdateFolder:FindFirstChild(RayUpdater) then
					RayUpdaters[RayUpdater] = require(RayUpdateFolder[RayUpdater])
				end
			end
			if RayUpdaters[RayUpdater] then
				RayUpdaters[RayUpdater](Cast, Cast.StateInfo.Delta)
			end
		end
		if not Cast.UserData.CastBehavior.Hitscan and Cast.UserData.HomeData.Homing then
			local CurrentPosition = Cast:GetPosition()
			local CurrentVelocity = Cast:GetVelocity()
			if Cast.UserData.HomeData.LockOnOnHovering then
				if Cast.UserData.HomeData.LockedEntity then
					local TargetHumanoid = Cast.UserData.HomeData.LockedEntity:FindFirstChildOfClass("Humanoid")
					if TargetHumanoid and TargetHumanoid.Health > 0 then
						local TargetTorso = Cast.UserData.HomeData.LockedEntity:FindFirstChild("HumanoidRootPart")
							or Cast.UserData.HomeData.LockedEntity:FindFirstChild("Torso")
						local DesiredVector = (TargetTorso.Position - CurrentPosition).Unit
						local CurrentVector = CurrentVelocity.Unit
						local AngularDifference = math.acos(DesiredVector:Dot(CurrentVector))
						if AngularDifference > 0 then
							local OrthoVector = CurrentVector:Cross(DesiredVector).Unit
							local AngularCorrection = math.min(
								AngularDifference,
								Cast.StateInfo.Delta * Cast.UserData.HomeData.TurnRatePerSecond
							)
							Cast:SetVelocity(
								CFrame.fromAxisAngle(OrthoVector, AngularCorrection):vectorToWorldSpace(CurrentVelocity)
							)
						end
					end
				end
			else
				local TargetEntity, TargetHumanoid, TargetTorso = FindNearestEntity(Cast, CurrentPosition)
				if TargetEntity and TargetHumanoid and TargetTorso and TargetHumanoid.Health > 0 then
					local DesiredVector = (TargetTorso.Position - CurrentPosition).Unit
					local CurrentVector = CurrentVelocity.Unit
					local AngularDifference = math.acos(DesiredVector:Dot(CurrentVector))
					if AngularDifference > 0 then
						local OrthoVector = CurrentVector:Cross(DesiredVector).Unit
						local AngularCorrection =
							math.min(AngularDifference, Cast.StateInfo.Delta * Cast.UserData.HomeData.TurnRatePerSecond)
						Cast:SetVelocity(
							CFrame.fromAxisAngle(OrthoVector, AngularCorrection):vectorToWorldSpace(CurrentVelocity)
						)
					end
				end
			end
		end
		if Cast.UserData.RealAccelerationData then
			local Accel = Cast.UserData.RealAccelerationData.Acceleration
			local RealAccel = Cast.UserData.RealAccelerationData.RealAcceleration
			local DeltaAccel = Vector3.new(Accel.X * RealAccel, Accel.Y * RealAccel, Accel.Z * RealAccel)
				* Cast.StateInfo.Delta
			Cast:AddVelocity(DeltaAccel)
			local CurrentSpeed = (Cast:GetVelocity() - DeltaAccel).Magnitude
			local FixVelocity = function(Max)
				if not Cast.UserData.RealAccelerationData.Clamped then
					Cast.UserData.RealAccelerationData.Clamped = true
					Cast:SetVelocity(ClampMagnitude(Cast:GetVelocity(), Max))
				end
			end
			if Cast.UserData.RealAccelerationData.InvertRealAcceleration then
				if CurrentSpeed > 0.00001 then
					Cast:SetVelocity(Cast:GetVelocity() * (1 - RealAccel * Cast.StateInfo.Delta))
				else
					FixVelocity(0.00001)
				end
			else
				if Cast.UserData.RealAccelerationData.StartSpeed < Cast.UserData.RealAccelerationData.TargetSpeed then
					if CurrentSpeed < Cast.UserData.RealAccelerationData.TargetSpeed then
						Cast:SetVelocity(Cast:GetVelocity() * (1 + RealAccel * Cast.StateInfo.Delta))
					else
						FixVelocity(Cast.UserData.RealAccelerationData.TargetSpeed)
					end
				elseif
					Cast.UserData.RealAccelerationData.StartSpeed > Cast.UserData.RealAccelerationData.TargetSpeed
				then
					if CurrentSpeed > Cast.UserData.RealAccelerationData.TargetSpeed then
						Cast:SetVelocity(Cast:GetVelocity() * (1 - RealAccel * Cast.StateInfo.Delta))
					else
						FixVelocity(Cast.UserData.RealAccelerationData.TargetSpeed)
					end
				end
			end
		end
		local TravelCFrame
		if Cast.UserData.SpinData.CanSpinPart then
			if not Cast.UserData.CastBehavior.Hitscan then
				local Position = (SegmentOrigin + Cast.UserData.SpinData.ProjectileOffset)
				if Cast.UserData.BounceData.SuperBounce or Cast.UserData.BounceData.CurrentBounces > 0 then
					TravelCFrame = CFrame.new(Position, Position + SegmentVelocity)
						* Math.FromAxisAngle(Tick * Cast.UserData.SpinData.InitalAngularVelocity)
						* Cast.UserData.SpinData.InitalRotation
				else
					TravelCFrame = CFrame.new(SegmentOrigin, SegmentOrigin + SegmentVelocity)
						* CFrame.Angles(
							math.rad(
								-360
									* (
										(os.clock() - Cast.UserData.ShootId / 4) * Cast.UserData.SpinData.SpinX
										- math.floor(
											(os.clock() - Cast.UserData.ShootId / 4) * Cast.UserData.SpinData.SpinX
										)
									)
							),
							math.rad(
								-360
									* (
										(os.clock() - Cast.UserData.ShootId / 4) * Cast.UserData.SpinData.SpinY
										- math.floor(
											(os.clock() - Cast.UserData.ShootId / 4) * Cast.UserData.SpinData.SpinY
										)
									)
							),
							math.rad(
								-360
									* (
										(os.clock() - Cast.UserData.ShootId / 4) * Cast.UserData.SpinData.SpinZ
										- math.floor(
											(os.clock() - Cast.UserData.ShootId / 4) * Cast.UserData.SpinData.SpinZ
										)
									)
							)
						)
				end
			else
				TravelCFrame = CFrame.new(SegmentOrigin, SegmentOrigin + SegmentVelocity)
					* CFrame.Angles(
						math.rad(
							-360
								* (
									(os.clock() - Cast.UserData.ShootId / 4) * Cast.UserData.SpinData.SpinX
									- math.floor(
										(os.clock() - Cast.UserData.ShootId / 4) * Cast.UserData.SpinData.SpinX
									)
								)
						),
						math.rad(
							-360
								* (
									(os.clock() - Cast.UserData.ShootId / 4) * Cast.UserData.SpinData.SpinY
									- math.floor(
										(os.clock() - Cast.UserData.ShootId / 4) * Cast.UserData.SpinData.SpinY
									)
								)
						),
						math.rad(
							-360
								* (
									(os.clock() - Cast.UserData.ShootId / 4) * Cast.UserData.SpinData.SpinZ
									- math.floor(
										(os.clock() - Cast.UserData.ShootId / 4) * Cast.UserData.SpinData.SpinZ
									)
								)
						)
					)
			end
		else
			TravelCFrame = CFrame.new(SegmentOrigin, SegmentOrigin + SegmentVelocity)
		end
		Cast.RayInfo.CurrentCFrame = TravelCFrame
		Cast.UserData.BounceData.CurrentAnchorPoint = (TravelCFrame * Cast.UserData.BounceData.AnchorPoint).p
		Cast.UserData.BounceData.BounceDeltaTime += Cast.StateInfo.Delta
		if Cast.UserData.BounceData.BounceDeltaTime > Cast.UserData.BounceData.BounceDelay then
			Cast.UserData.BounceData.LastBouncedObject = nil
		end
		Cast.UserData.LastPosition = SegmentOrigin
	end

	function OnRayTerminated(Cast, RaycastResult, IsDecayed)
		-- NPC cleanup if needed
	end

	Events.npcShoot.Event:Connect(function(Tool, Handle, Directions, FirePointObject, MuzzlePointObject, Misc)
		if Tool and Handle then
			if FirePointObject then
				if not FirePointObject:IsDescendantOf(Workspace) and not FirePointObject:IsDescendantOf(Tool) then
					return
				end
			else
				return
			end

			local directionsPacket = CreatePacket(CloneTable(Directions))
			local miscPacket = CreatePacket(CloneTable(Misc))
			forNearbyPlayers(nil, BULLET_VISUAL_DISTANCE, function(plr)
				Remotes.VisualizeBullet:FireClient(
					plr,
					Tool,
					Handle,
					directionsPacket,
					FirePointObject,
					MuzzlePointObject,
					miscPacket
				)
			end, getWorldPosition(FirePointObject), getWorldPosition(MuzzlePointObject), getWorldPosition(Handle))

			local Module = GetSetting(nil, nil, nil, Misc.NPCData)
			if Module.OnShootEventName ~= "None" then
				FireOnShootEvent(
					Module.OnShootEventName,
					Module.OnShootEventData,
					Tool,
					Handle,
					Directions,
					FirePointObject,
					Misc
				)
			end
			if Module.ShootType == "Custom" then
				ShootCustom(
					Module.CustomShotName,
					Module.CustomShotData,
					Tool,
					Handle,
					Directions,
					FirePointObject,
					Misc
				)
				return
			end

			local Character = Tool.Parent
			local IgnoreList2 = CloneTable(IgnoreList)
			table.insert(IgnoreList2, Tool)
			table.insert(IgnoreList2, Character)
			local CastParams = RaycastParams.new()
			CastParams.IgnoreWater = true
			CastParams.FilterType = Enum.RaycastFilterType.Blacklist
			CastParams.FilterDescendantsInstances = IgnoreList2

			ShootId += 1

			for _, Direction in pairs(Directions) do
				if FirePointObject then
					if not FirePointObject:IsDescendantOf(Workspace) and not FirePointObject:IsDescendantOf(Tool) then
						return
					end
				else
					return
				end

				local Origin, Dir = FirePointObject.WorldPosition, Direction[1]
				local HumanoidRootPart = Character and Character:FindFirstChild("HumanoidRootPart") or nil
				if not HumanoidRootPart and Character then
					HumanoidRootPart = Character:WaitForChild("HumanoidRootPart", 1)
				end
				if not HumanoidRootPart then
					return
				end
				local TipCFrame = FirePointObject.WorldCFrame
				local TipPos = TipCFrame.Position
				local TipDir = TipCFrame.LookVector
				local AmountToCheatBack = math.abs((HumanoidRootPart.Position - TipPos):Dot(TipDir)) + 1
				local GunRay = Ray.new(TipPos - TipDir.Unit * AmountToCheatBack, TipDir.Unit * AmountToCheatBack)
				local HitPart, HitPoint = Workspace:FindPartOnRayWithIgnoreList(GunRay, IgnoreList2, false, true)
				if HitPart and math.abs((TipPos - HitPoint).Magnitude) > 0 then
					Origin = HitPoint - TipDir.Unit * 0.1
				end

				local TempMisc = CloneTable(Misc)
				if TempMisc.NPCData.ModData then
					TempMisc.NPCData.ModData["BulletId"] = Direction[2]
				end
				local Module2 = GetSetting(nil, nil, nil, TempMisc.NPCData)

				local BulletSpeed = math.max(0.00001, Module2.BulletSpeed)
				local Acceleration = Module2.Acceleration
				local RealAcceleration = Module2.RealAcceleration
				local InvertRealAcceleration = Module2.InvertRealAcceleration
				local RealAccelerationData
				if RealAcceleration > 0 then
					if not InvertRealAcceleration then
						BulletSpeed = math.max(0.00001, Module2.InitialBulletSpeed)
					end
					RealAccelerationData = {
						Acceleration = Acceleration,
						RealAcceleration = RealAcceleration,
						InvertRealAcceleration = InvertRealAcceleration,
						StartSpeed = BulletSpeed,
						TargetSpeed = math.max(0.00001, Module2.BulletSpeed),
						Clamped = false,
					}
				end
				local Velocity = Dir * BulletSpeed

				local PenetrationDepth = Module2.PenetrationDepth
				local PenetrationAmount = Module2.PenetrationAmount
				local PenetrationData
				if PenetrationDepth > 0 or PenetrationAmount > 0 then
					PenetrationData = {
						PenetrationDepth = PenetrationDepth,
						PenetrationAmount = PenetrationAmount,
						PenetrationIgnoreDelay = Module2.PenetrationIgnoreDelay,
						PenetrationModifiers = Module2.PenetrationModifiers,
						HitHumanoids = {},
					}
				end

				local CastBehavior = FastCast.newBehavior()
				CastBehavior.RaycastParams = CastParams
				CastBehavior.TravelType = Module2.TravelType
				CastBehavior.MaxDistance = Module2.Range
				CastBehavior.Lifetime = Module2.Lifetime
				CastBehavior.HighFidelityBehavior = FastCast.HighFidelityBehavior.Default
				CastBehavior.Acceleration = RealAcceleration > 0 and Vector3.new(0, 0, 0) or Module2.Acceleration
				CastBehavior.AutoIgnoreContainer = false
				CastBehavior.HitEventOnTermination = Module2.HitEventOnTermination
				CastBehavior.CanPenetrateFunction = CanRayPenetrate
				CastBehavior.CanHitFunction = CanRayHit

				local RaycastHitbox = Module2.RaycastHitbox
				local RaycastHitboxData = Module2.RaycastHitboxData
				local ShapeCast = Module2.ShapeCast
				CastBehavior.RaycastHitbox = (not ShapeCast and RaycastHitbox and #RaycastHitboxData > 0)
						and RaycastHitboxData
					or nil
				CastBehavior.ShapeCast = nil
				if ShapeCast then
					CastBehavior.ShapeCast =
						{ CastShape = Module2.CastShape, CastSize = Module2.CastSize, CastRadius = Module2.CastRadius }
				end
				CastBehavior.CurrentCFrame = CFrame.new(Origin, Origin + Dir)
				CastBehavior.ModifiedDirection = CFrame.new(Origin, Origin + Dir).LookVector
				CastBehavior.Hitscan = Module2.ShootType == "Hitscan"

				CastBehavior.UserData = {
					ShootId = ShootId,
					Tool = Tool,
					Character = Character,
					Setting = Module2,
					Misc = Misc,
					RealAccelerationData = RealAccelerationData,
					PenetrationData = PenetrationData,
					SpinData = {
						CanSpinPart = Module2.CanSpinPart,
						SpinX = Module2.SpinX,
						SpinY = Module2.SpinY,
						SpinZ = Module2.SpinZ,
						InitalTick = os.clock(),
						InitalAngularVelocity = Vector3.new(Module2.SpinX, Module2.SpinY, Module2.SpinZ),
						InitalRotation = (CastBehavior.CurrentCFrame - CastBehavior.CurrentCFrame.p),
						ProjectileOffset = Vector3.new(),
					},
					BounceData = {
						CurrentBounces = Module2.BounceAmount,
						BounceElasticity = Module2.BounceElasticity,
						FrictionConstant = Module2.FrictionConstant,
						IgnoreSlope = Module2.IgnoreSlope,
						SlopeAngle = Module2.SlopeAngle,
						BounceHeight = Module2.BounceHeight,
						NoExplosionWhileBouncing = Module2.NoExplosionWhileBouncing,
						StopBouncingOn = Module2.StopBouncingOn,
						SuperBounce = Module2.SuperBounce,
						BounceBetweenHumanoids = Module2.BounceBetweenHumanoids,
						PredictDirection = Module2.PredictDirection,
						MaxBounceAngle = Module2.MaxBounceAngle,
						UsePartDensity = Module2.UsePartDensity,
						UseBulletSpeed = Module2.UseBulletSpeed,
						AnchorPoint = Module2.AnchorPoint,
						BounceDelay = Module2.BounceDelay,
						BouncedHumanoids = {},
						CurrentAnchorPoint = Vector3.new(),
						BounceDeltaTime = 0,
						LastBouncedObject = nil,
					},
					HomeData = {
						Homing = Module2.Homing,
						HomingDistance = Module2.HomingDistance,
						TurnRatePerSecond = Module2.TurnRatePerSecond,
						HomeThroughWall = Module2.HomeThroughWall,
						LockOnOnHovering = Module2.LockOnOnHovering,
						LockedEntity = Misc.LockedEntity,
					},
					UpdateData = {
						UpdateRayInExtra = Module2.UpdateRayInExtra,
						ExtraRayUpdater = Module2.ExtraRayUpdater,
					},
					LastReflectingModel = nil,
					IgnoreList = IgnoreList2,
					LastSegmentOrigin = Vector3.new(),
					SegmentOrigin = Vector3.new(),
					SegmentDirection = Vector3.new(),
					SegmentVelocity = Vector3.new(),
					LastPosition = Origin,
					CastBehavior = CastBehavior,
				}

				Caster:Fire(Origin, Dir, Velocity, CastBehavior)
			end
		end
	end)

	Events.inflictTargetNPC.Event:Connect(function(...)
		InflictTargetNPC(...)
	end)

	Caster.RayFinalHit:Connect(OnRayFinalHit)
	Caster.RayHit:Connect(OnRayHit)
	Caster.LengthChanged:Connect(OnRayUpdated)
	Caster.CastTerminating:Connect(OnRayTerminated)
end

-- ============================================================
-- PLAYER ADDED / WORLD SETUP
-- ============================================================
Players.PlayerAdded:Connect(function(player)
	for i, v in pairs(_G.TempBannedPlayers) do
		if v == player.Name then
			player:Kick("You cannot rejoin a server where you were kicked from.")
			warn(player.Name .. " tried to rejoin a server where he/she was kicked from.")
			break
		end
	end
end)

for i, v in pairs(Workspace:GetDescendants()) do
	if v:IsA("Humanoid") then
		CollectionService:AddTag(v, "Humanoids")
	end
end

Workspace.DescendantAdded:Connect(function(Obj)
	if Obj:IsA("Humanoid") then
		CollectionService:AddTag(Obj, "Humanoids")
	end
end)
