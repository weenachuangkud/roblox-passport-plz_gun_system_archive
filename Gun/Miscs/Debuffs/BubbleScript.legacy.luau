local character = script.Parent
local Humanoid = character:FindFirstChild("Humanoid")
local HRP = character:FindFirstChild("HumanoidRootPart")
local Head = character:FindFirstChild("Head")
local Player = game.Players:GetPlayerFromCharacter(character)

local bubble = nil
local weld = nil
local floatForce = nil
local PreventTools = nil
local DisableJump = nil

local FLOAT_DURATION = script.Duration and script.Duration.Value or 6
local BUBBLE_SIZE = 8
local FLOAT_HEIGHT = 40
local FLOAT_SPEED = 0.09 -- studs per heartbeat, smooth rise

-- Sounds (replace IDs as needed)
local bubbleFormSounds = { 114405896207723, 109359226723492, 109359226723492, 109359226723492, 109359226723492 } -- water/bubble sfx
local bubblePopSounds = { 109359226723492 } -- pop sfx

local function DisableMove()
	Humanoid.AutoRotate = false
	Humanoid:UnequipTools()
	PreventTools = character.ChildAdded:Connect(function(child)
		task.wait()
		if child:IsA("Tool") and child.Parent == character then
			Humanoid:UnequipTools()
		end
	end)
	DisableJump = Humanoid.Changed:Connect(function(prop)
		if prop == "Jump" then
			Humanoid.Jump = false
		end
	end)
	Humanoid:ChangeState(Enum.HumanoidStateType.Physics)
end

local function EnableMove()
	Humanoid.AutoRotate = true
	for _, conn in ipairs({ DisableJump, PreventTools }) do
		if conn then
			conn:Disconnect()
		end
	end
	Humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
end

-- Play a sound on the Head
local function PlaySound(id, volume, pitch)
	local s = Instance.new("Sound")
	s.SoundId = "rbxassetid://" .. id
	s.Volume = volume or 1.5
	s.PlaybackSpeed = pitch or 1
	s.Parent = Head
	game.Debris:AddItem(s, 10)
	task.delay(0, function()
		s:Play()
	end)
	return s
end

-- ─── Freeze & Build Bubble ────────────────────────────────────────────────────

DisableMove()

PlaySound(bubbleFormSounds[math.random(1, #bubbleFormSounds)], 1.5)

-- Create the bubble sphere
bubble = Instance.new("Part")
bubble.Name = "DebuffBubble"
bubble.Shape = Enum.PartType.Ball
bubble.Size = Vector3.new(BUBBLE_SIZE, BUBBLE_SIZE, BUBBLE_SIZE)
bubble.Color = Color3.fromRGB(121, 226, 255)
bubble.Material = Enum.Material.Glass
bubble.Transparency = 0.45
bubble.Reflectance = 0.25
bubble.CanCollide = false
bubble.Anchored = false
bubble.Massless = true
bubble.CastShadow = false
bubble.BottomSurface = Enum.SurfaceType.Smooth
bubble.TopSurface = Enum.SurfaceType.Smooth
bubble.CFrame = HRP.CFrame
bubble.Parent = workspace

-- Weld bubble to HRP so it moves with the character
weld = Instance.new("Weld")
weld.Part0 = HRP
weld.Part1 = bubble
weld.C0 = CFrame.new(0, 0, 0)
weld.Parent = bubble

-- BodyPosition to float the bubble (and character) upward
local bodyPos = Instance.new("BodyPosition")
bodyPos.MaxForce = Vector3.new(1e5, 1e5, 1e5)
bodyPos.D = 500
bodyPos.P = 8000
bodyPos.Position = HRP.Position
bodyPos.Parent = HRP

-- BodyGyro to keep character upright and stop spinning
local bodyGyro = Instance.new("BodyGyro")
bodyGyro.MaxTorque = Vector3.new(1e5, 1e5, 1e5)
bodyGyro.D = 800
bodyGyro.P = 8000
bodyGyro.CFrame = HRP.CFrame
bodyGyro.Parent = HRP

-- ─── Float Up ────────────────────────────────────────────────────────────────

local startY = HRP.Position.Y
local targetY = startY + FLOAT_HEIGHT
local elapsed = 0
local floatConn

floatConn = game:GetService("RunService").Heartbeat:Connect(function(dt)
	elapsed = elapsed + dt
	-- Smooth lerp upward over the first ~2 seconds, then hold
	local t = math.min(elapsed / 2, 1)
	local eased = 1 - (1 - t) ^ 3 -- ease-out cubic
	local currentTarget = startY + (FLOAT_HEIGHT * eased)
	bodyPos.Position = Vector3.new(HRP.Position.X, currentTarget, HRP.Position.Z)
end)

-- ─── Hold, Then Pop ──────────────────────────────────────────────────────────

-- Count down duration
local remaining = FLOAT_DURATION
while remaining > 0 do
	task.wait(1)
	remaining = remaining - 1
end

-- Stop the float connection before releasing
if floatConn then
	floatConn:Disconnect()
end

-- Remove body movers so gravity takes over immediately
if bodyPos then
	bodyPos:Destroy()
end
if bodyGyro then
	bodyGyro:Destroy()
end

-- Detach the weld so bubble separates
if weld then
	weld:Destroy()
end

-- Pop the bubble visually: scale it up briefly then remove
task.spawn(function()
	for i = 1, 6 do
		if bubble and bubble.Parent then
			bubble.Size = bubble.Size + Vector3.new(0.4, 0.4, 0.4)
			bubble.Transparency = bubble.Transparency + 0.08
		end
		task.wait(0.04)
	end
	if bubble and bubble.Parent then
		bubble:Destroy()
	end
end)

-- Pop sound
local popSound = PlaySound(bubblePopSounds[math.random(1, #bubblePopSounds)], 1.5)

-- Re-enable movement and let the player fall
EnableMove()

-- Clean up after sound finishes
popSound.Ended:Connect(function()
	if script then
		script:Destroy()
	end
end)

-- Safety cleanup if sound never fires Ended
game.Debris:AddItem(script, 15)
