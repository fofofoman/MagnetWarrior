--!nonstrict
--[[
	EnemyService.luau

	Enemies are single unanchored magnetic parts — hovering drones — rather than
	humanoid rigs. That is a deliberate design choice, not a shortcut: the whole
	combat loop is "grab an enemy and throw it at something", which requires the
	enemy to be a physics body the server owns and can apply impulses to. A
	Humanoid would fight every impulse with its own state machine and would need
	a rig this project has no reason to carry.

	While an enemy is airborne from a magnet hit (MagneticRegistry.IsThrown) its
	AI stops driving it, so a thrown drone actually flies instead of hovering
	back into place mid-arc.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local GameConfig = require(Shared.Config.GameConfig)
local Signal = require(Shared.Util.Signal)

local MagneticRegistry = require(script.Parent.Parent.Magnet.MagneticRegistry)

local EnemyService = {}

local AI_RATE = 15 -- Hz
local HOVER_HEIGHT = 5 -- studs above the ground the drone tries to hold
local CONTACT_RANGE = 6.5
local CONTACT_COOLDOWN = 1.1

export type EnemyKind = {
	displayName: string,
	health: number,
	speed: number,
	aggroRange: number,
	contactDamage: number,
	size: Vector3,
	color: Color3,
	density: number,
	--- Stationary bodies get no hover AI at all. Boss cores use this: BossService
	--- owns their position, so an AI fighting it for control would be noise.
	stationary: boolean?,
}

local kinds: { [string]: EnemyKind } = {
	Scrapper = {
		displayName = "스크래퍼",
		health = 60,
		speed = 20,
		aggroRange = 70,
		contactDamage = 12,
		size = Vector3.new(4, 4, 4),
		color = Color3.fromRGB(226, 88, 72),
		density = 0.55,
	},
	Hauler = {
		displayName = "하울러",
		health = 150,
		speed = 12,
		aggroRange = 60,
		contactDamage = 22,
		size = Vector3.new(6, 6, 6),
		color = Color3.fromRGB(196, 112, 42),
		density = 0.9,
	},
	Spark = {
		displayName = "스파크",
		health = 35,
		speed = 30,
		aggroRange = 85,
		contactDamage = 8,
		size = Vector3.new(3, 3, 3),
		color = Color3.fromRGB(255, 214, 92),
		density = 0.4,
	},

	-- Boss cores. Health is high because the damage windows are short, not
	-- because the fight is a slog — see BossService.
	-- Core density is load-bearing, not flavour. Mass must stay well under
	-- MagnetConfig.ImmovableMassThreshold (260) or the magnet would treat an
	-- exposed core as an anchor and grapple the player to it instead of
	-- wrenching it loose — which would quietly delete half the boss fight.
	--   7³ × 0.2 ≈ 69,  8³ × 0.13 ≈ 67
	CollectorCore = {
		displayName = "폐기물 수집기",
		health = 900,
		speed = 0,
		aggroRange = 0,
		contactDamage = 0,
		size = Vector3.new(7, 7, 7),
		color = Color3.fromRGB(255, 116, 84),
		density = 0.2,
		stationary = true,
	},
	FurnaceCore = {
		displayName = "대자석로",
		health = 1500,
		speed = 0,
		aggroRange = 0,
		contactDamage = 0,
		size = Vector3.new(8, 8, 8),
		color = Color3.fromRGB(140, 108, 255),
		density = 0.13,
		stationary = true,
	},
}

EnemyService.Kinds = kinds

type EnemyState = {
	part: BasePart,
	kind: EnemyKind,
	kindName: string,
	stageId: string,
	group: string,
	velocity: LinearVelocity,
	lastContactAt: number,
	homePosition: Vector3,
	stationary: boolean,
	--- Who last threw this thing. Kept beyond MagneticRegistry's throw window so
	--- a drone that sails into a pit still credits the player who launched it.
	lastThrower: Player?,
}

local enemies: { [BasePart]: EnemyState } = {}

--- Y below which an enemy counts as knocked out of the world, per stage.
local voidY: { [string]: number } = {}

EnemyService.EnemyDied = Signal.new() -- (part, stageId, group, killer)
EnemyService.GroupCleared = Signal.new() -- (stageId, group)

local function countGroup(stageId: string, group: string): number
	local count = 0
	for _, state in enemies do
		if state.stageId == stageId and state.group == group then
			count += 1
		end
	end
	return count
end

function EnemyService.GetAliveCount(stageId: string, group: string): number
	return countGroup(stageId, group)
end

function EnemyService.Spawn(kindName: string, position: Vector3, stageId: string, group: string?): BasePart?
	local kind = kinds[kindName]
	if not kind then
		warn(`[EnemyService] unknown enemy kind "{kindName}"`)
		return nil
	end

	local part = Instance.new("Part")
	part.Name = `Enemy_{kindName}`
	part.Size = kind.size
	part.Position = position
	part.Anchored = false
	part.CanCollide = true
	part.Color = kind.color
	part.Material = Enum.Material.Neon
	part.Shape = Enum.PartType.Block
	part.CustomPhysicalProperties = PhysicalProperties.new(kind.density, 0.4, 0.35, 1, 1)

	part:SetAttribute("EnemyKind", kindName)
	part:SetAttribute("StageId", stageId)
	part:SetAttribute("EnemyGroup", group or "default")
	part:SetAttribute("MaxHealth", kind.health)
	part:SetAttribute("Health", kind.health)

	local attachment = Instance.new("Attachment")
	attachment.Name = "Drive"
	attachment.Parent = part

	local velocity = Instance.new("LinearVelocity")
	velocity.Name = "Hover"
	velocity.Attachment0 = attachment
	velocity.RelativeTo = Enum.ActuatorRelativeTo.World
	velocity.MaxForce = 25000
	velocity.VectorVelocity = Vector3.zero
	velocity.Parent = part

	part.Parent = workspace:FindFirstChild("Enemies") or workspace

	-- Tagging last: the registry claims network ownership on tag, and we want
	-- the part fully assembled first.
	CollectionService:AddTag(part, GameConfig.Tags.Enemy)
	CollectionService:AddTag(part, GameConfig.Tags.Magnetic)

	enemies[part] = {
		part = part,
		kind = kind,
		kindName = kindName,
		stageId = stageId,
		group = group or "default",
		velocity = velocity,
		lastContactAt = 0,
		homePosition = position,
		stationary = kind.stationary == true,
		lastThrower = nil,
	}

	return part
end

function EnemyService.IsEnemy(part: Instance?): boolean
	return part ~= nil and enemies[part :: BasePart] ~= nil
end

--- Registered by StageService from each layout's kill height, so "밀어서
--- 떨어뜨리기" is a real way to kill things and not just a way to lose them.
function EnemyService.SetStageVoidY(stageId: string, y: number)
	voidY[stageId] = y
end

function EnemyService.Damage(part: BasePart, amount: number, killer: Player?)
	local state = enemies[part]
	if not state or amount <= 0 then
		return
	end

	-- Armoured bosses shrug everything off until their window opens. Checked
	-- here rather than at each call site so no damage source can forget.
	if part:GetAttribute("Invulnerable") == true then
		return
	end

	local health = (part:GetAttribute("Health") or 0) - amount
	part:SetAttribute("Health", math.max(health, 0))

	if health > 0 then
		return
	end

	enemies[part] = nil

	local stageId, group = state.stageId, state.group
	EnemyService.EnemyDied:Fire(part, stageId, group, killer)

	-- Brief death flash before removal, so a kill reads clearly.
	part.Anchored = true
	part.CanCollide = false
	CollectionService:RemoveTag(part, GameConfig.Tags.Magnetic)
	CollectionService:RemoveTag(part, GameConfig.Tags.Enemy)
	task.delay(0.35, function()
		part:Destroy()
	end)

	if countGroup(stageId, group) == 0 then
		EnemyService.GroupCleared:Fire(stageId, group)
	end
end

--- Removes a group without firing death signals — used to clear a defeated
--- boss's escorts, which should vanish rather than count as kills.
function EnemyService.ClearGroup(stageId: string, group: string)
	for part, state in enemies do
		if state.stageId == stageId and state.group == group then
			enemies[part] = nil
			part:Destroy()
		end
	end
end

function EnemyService.ClearStage(stageId: string)
	for part, state in enemies do
		if state.stageId == stageId then
			enemies[part] = nil
			part:Destroy()
		end
	end
end

local function nearestPlayer(position: Vector3, range: number): (Player?, BasePart?, number)
	local bestPlayer, bestRoot, bestDistance = nil, nil, range

	for _, player in Players:GetPlayers() do
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not humanoid or not root or humanoid.Health <= 0 then
			continue
		end

		local distance = (root.Position - position).Magnitude
		if distance < bestDistance then
			bestPlayer, bestRoot, bestDistance = player, root, distance
		end
	end

	return bestPlayer, bestRoot, bestDistance
end

local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Exclude
groundParams.IgnoreWater = true

local function stepAi()
	local now = os.clock()

	for part, state in enemies do
		if not part.Parent then
			enemies[part] = nil
			continue
		end

		-- Knocked out of the world. Credited to whoever launched it, which is
		-- the entire point of the "knock them into the pit" stages.
		local floor = voidY[state.stageId]
		if floor and part.Position.Y < floor then
			EnemyService.Damage(part, (part:GetAttribute("Health") or 1) + 1, state.lastThrower)
			continue
		end

		if state.stationary then
			state.velocity.Enabled = false
			continue
		end

		-- Airborne from a magnet hit: hands off, let physics carry it.
		if MagneticRegistry.IsThrown(part) then
			state.lastThrower = MagneticRegistry.Thrower(part) or state.lastThrower
			state.velocity.VectorVelocity = Vector3.zero
			state.velocity.Enabled = false
			continue
		end
		state.velocity.Enabled = true

		local position = part.Position
		local player, root, distance = nearestPlayer(position, state.kind.aggroRange)

		if not player or not root then
			-- Drift home so a knocked-away drone returns to its arena.
			local toHome = state.homePosition - position
			state.velocity.VectorVelocity = if toHome.Magnitude > 3
				then toHome.Unit * math.min(state.kind.speed, toHome.Magnitude)
				else Vector3.zero
			continue
		end

		local toPlayer = root.Position - position
		local horizontal = Vector3.new(toPlayer.X, 0, toPlayer.Z)
		local desired = if horizontal.Magnitude > 0.5
			then horizontal.Unit * state.kind.speed
			else Vector3.zero

		-- Hold a hover height above whatever is underneath.
		groundParams.FilterDescendantsInstances = { part }
		local ground = workspace:Raycast(position, Vector3.new(0, -60, 0), groundParams)
		local targetY = if ground then ground.Position.Y + HOVER_HEIGHT else position.Y
		desired = Vector3.new(desired.X, math.clamp(targetY - position.Y, -14, 14) * 2, desired.Z)

		state.velocity.VectorVelocity = desired

		if distance <= CONTACT_RANGE and (now - state.lastContactAt) >= CONTACT_COOLDOWN then
			state.lastContactAt = now
			local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
			if humanoid then
				humanoid:TakeDamage(state.kind.contactDamage)
			end
		end
	end
end

function EnemyService.Start()
	if not workspace:FindFirstChild("Enemies") then
		local folder = Instance.new("Folder")
		folder.Name = "Enemies"
		folder.Parent = workspace
	end

	local accumulator = 0
	local interval = 1 / AI_RATE

	RunService.Heartbeat:Connect(function(deltaTime)
		accumulator += deltaTime
		if accumulator < interval then
			return
		end
		accumulator = 0
		stepAi()
	end)
end

return EnemyService
