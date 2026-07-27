--!nonstrict
--[[
	HazardService.luau

	Two kinds of lethality:

	  • Hazard parts — touch them, take damage. Touched is fine here because
	    hazards are things you walk into.
	  • Kill planes — the floor of the world. Touched is *not* fine: a player
	    launched off a magnet wall can fall past a 4-stud plane between physics
	    steps and never touch it. So kill planes are evaluated as a volume check
	    against player position instead, which cannot be tunnelled through.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local GameConfig = require(Shared.Config.GameConfig)
local SoundKit = require(Shared.Util.SoundKit)

local HazardService = {}

local CHECK_RATE = 5 -- Hz
local HAZARD_DAMAGE = 35
local HAZARD_COOLDOWN = 1

local killPlanes: { [BasePart]: true } = {}
local hazardConnections: { [BasePart]: RBXScriptConnection } = {}

--- Weak-keyed on purpose. Every respawn produces a new Humanoid, and a strong
--- table here would hold one entry per death for the lifetime of the server.
--- Nothing else references these humanoids once the character is gone, so weak
--- keys let the whole table drain by itself.
local lastHazardHit: { [Humanoid]: number } = setmetatable({}, { __mode = "k" }) :: any

local function humanoidOf(part: BasePart): Humanoid?
	local model = part:FindFirstAncestorOfClass("Model")
	while model do
		if Players:GetPlayerFromCharacter(model) then
			return model:FindFirstChildOfClass("Humanoid")
		end
		model = model:FindFirstAncestorOfClass("Model")
	end
	return nil
end

local function onHazardTouched(other: BasePart)
	local humanoid = humanoidOf(other)
	if not humanoid or humanoid.Health <= 0 then
		return
	end

	local now = os.clock()
	local last = lastHazardHit[humanoid]
	if last and (now - last) < HAZARD_COOLDOWN then
		return
	end
	lastHazardHit[humanoid] = now

	humanoid:TakeDamage(HAZARD_DAMAGE)
	SoundKit.PlayAt("PlayerHurt", other.Position)
end

local function registerHazard(instance: Instance)
	if not instance:IsA("BasePart") or hazardConnections[instance] then
		return
	end
	hazardConnections[instance] = instance.Touched:Connect(onHazardTouched)
end

local function unregisterHazard(instance: Instance)
	local connection = hazardConnections[instance :: BasePart]
	if connection then
		connection:Disconnect()
		hazardConnections[instance :: BasePart] = nil
	end
end

local function checkKillPlanes()
	if next(killPlanes) == nil then
		return
	end

	for _, player in Players:GetPlayers() do
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not humanoid or not root or humanoid.Health <= 0 then
			continue
		end

		local position = root.Position

		for plane in killPlanes do
			if not plane.Parent then
				killPlanes[plane] = nil
				continue
			end

			local halfX = plane.Size.X / 2
			local halfZ = plane.Size.Z / 2
			local centre = plane.Position

			-- Anything at or below the plane, inside its footprint, is out of
			-- bounds — no matter how fast it got there.
			if
				position.Y <= centre.Y + plane.Size.Y / 2
				and math.abs(position.X - centre.X) <= halfX
				and math.abs(position.Z - centre.Z) <= halfZ
			then
				humanoid.Health = 0
				break
			end
		end
	end
end

function HazardService.Start()
	for _, instance in CollectionService:GetTagged(GameConfig.Tags.Killbrick) do
		if instance:IsA("BasePart") then
			killPlanes[instance] = true
		end
	end
	CollectionService:GetInstanceAddedSignal(GameConfig.Tags.Killbrick):Connect(function(instance)
		if instance:IsA("BasePart") then
			killPlanes[instance] = true
		end
	end)
	CollectionService:GetInstanceRemovedSignal(GameConfig.Tags.Killbrick):Connect(function(instance)
		killPlanes[instance :: BasePart] = nil
	end)

	for _, instance in CollectionService:GetTagged(GameConfig.Tags.Hazard) do
		registerHazard(instance)
	end
	CollectionService:GetInstanceAddedSignal(GameConfig.Tags.Hazard):Connect(registerHazard)
	CollectionService:GetInstanceRemovedSignal(GameConfig.Tags.Hazard):Connect(unregisterHazard)

	local accumulator = 0
	local interval = 1 / CHECK_RATE
	RunService.Heartbeat:Connect(function(deltaTime)
		accumulator += deltaTime
		if accumulator < interval then
			return
		end
		accumulator = 0
		checkKillPlanes()
	end)
end

return HazardService
