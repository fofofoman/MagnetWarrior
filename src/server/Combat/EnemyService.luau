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
local Net = require(Shared.Net)
local Signal = require(Shared.Util.Signal)
local SoundKit = require(Shared.Util.SoundKit)

local MagneticRegistry = require(script.Parent.Parent.Magnet.MagneticRegistry)
local StageActivity = require(script.Parent.Parent.Stage.StageActivity)

local EnemyService = {}

--- Damage readability. A drone with no health bar still has to communicate how
--- close it is to dying, so it flashes white on every hit and then settles to a
--- colour lerped toward FADED by how hurt it is. You can read a whole arena's
--- state at a glance without a single piece of UI.
local HIT_FLASH = Color3.fromRGB(255, 255, 255)
local HIT_FLASH_SECONDS = 0.07
local FADED = Color3.fromRGB(38, 30, 34)

local AI_RATE = 15 -- Hz
local HOVER_HEIGHT = 5 -- studs above the ground the drone tries to hold
local CONTACT_RANGE = 6.5

--- Per drone, so being surrounded stacks. At 1.1s a player could stand inside a
--- Scrapper for ten seconds and walk away; the arenas were survivable by simply
--- not moving, which is the opposite of what a game about momentum wants.
local CONTACT_COOLDOWN = 0.85

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

-- Health values are chosen against the slam damage curve, not picked by feel.
-- A Push is clamped to MagnetConfig.PushImpulse and then attenuated by distance
-- (FalloffAtMaxRange 0.45 at 90 studs), so how hard a drone lands is a function
-- of how close you were when you threw it. Health decides the range at which a
-- slam stops being lethal — which is the whole reason to raise it. At 60 HP a
-- Scrapper died to a lazy poke from 80 studs; at 115 the kill radius is ~46, and
-- closing the distance becomes the thing the combat stages ask of you.
--
-- One-shot kills are kept on purpose. Grabbing something and burying it in a
-- wall is the core pleasure here, and turning every drone into a damage sponge
-- would trade difficulty for tedium. The pressure comes from contact damage
-- instead: the arenas got more dangerous to stand in, not slower to clear.
local kinds: { [string]: EnemyKind } = {
	Scrapper = {
		displayName = "스크래퍼",
		health = 115,
		speed = 20,
		aggroRange = 70,
		contactDamage = 18,
		size = Vector3.new(4, 4, 4),
		color = Color3.fromRGB(226, 88, 72),
		density = 0.55,
	},
	Hauler = {
		displayName = "하울러",
		health = 220,
		speed = 12,
		aggroRange = 60,
		-- Slow, but it hits like the machine it is: four contacts and you are
		-- dead. A Hauler is not something to fight past, it is something to move.
		contactDamage = 28,
		size = Vector3.new(6, 6, 6),
		color = Color3.fromRGB(196, 112, 42),
		-- Mass 108. Heavy enough that slamming it into a wall barely scratches
		-- it (17 damage against 220 health), light enough that the magnet can
		-- still pick it up and throw it. That combination is its whole role: the
		-- Hauler is not something you slam, it is something you slam *with*.
		density = 0.5,
	},
	Spark = {
		displayName = "스파크",
		health = 55,
		speed = 30,
		aggroRange = 85,
		-- Mass 10.8 means a Push reaches full speed at any range, so a Spark is a
		-- one-shot from anywhere no matter what its health is. Raising it buys
		-- nothing against the magnet; the number that matters for a Spark is the
		-- damage it does while you are busy with something heavier.
		contactDamage = 13,
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
		health = 1000,
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
		health = 1800,
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
	--- Anchored because its stage is asleep. Tracked so the anchor is written
	--- once on each transition rather than every tick.
	parked: boolean,
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

	part.Color = kind.color

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
		parked = false,
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

--- `silent` suppresses the death sound and burst. Used for void kills, whose
--- effects would play far below the stage where nobody can see or hear them.
function EnemyService.Damage(part: BasePart, amount: number, killer: Player?, silent: boolean?)
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
		local ratio = math.clamp(health / math.max(state.kind.health, 1), 0, 1)
		local settled = state.kind.color:Lerp(FADED, (1 - ratio) * 0.75)

		part.Color = HIT_FLASH
		task.delay(HIT_FLASH_SECONDS, function()
			if part.Parent then
				part.Color = settled
			end
		end)
		return
	end

	enemies[part] = nil

	local stageId, group = state.stageId, state.group
	EnemyService.EnemyDied:Fire(part, stageId, group, killer)

	if not silent then
		SoundKit.PlayAt("EnemyDeath", part.Position)
		Net.CombatFeedback:FireAllClients({
			kind = "EnemyDeath",
			position = part.Position,
			magnitude = math.clamp(state.kind.health / 150, 0.35, 1),
			color = state.kind.color,
		})
	end

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

		-- Nobody near this stage: no chasing, no hovering, no raycasts.
		--
		-- Anchored, not merely un-driven. Switching the hover off leaves an
		-- unanchored drone to gravity, and Roblox keeps simulating it whether or
		-- not anyone is watching — so every drone in every unattended stage sank
		-- to the floor, and any spawned over a pit fell past
		-- FallenPartsDestroyHeight and was deleted outright. Arriving at an arena
		-- that had quietly emptied itself is not what sleeping a stage was
		-- supposed to mean.
		--
		-- Boss cores are exempt: their position is owned by BossService's
		-- AlignPosition, which holds them without any help from here.
		if not StageActivity.IsAwake(state.stageId) then
			state.velocity.Enabled = false
			if not state.parked and not state.stationary then
				state.parked = true
				part.AssemblyLinearVelocity = Vector3.zero
				part.AssemblyAngularVelocity = Vector3.zero
				part.Anchored = true
			end
			continue
		end

		if state.parked then
			state.parked = false
			part.Anchored = false
		end

		-- Knocked out of the world. Credited to whoever launched it, which is
		-- the entire point of the "knock them into the pit" stages.
		local floor = voidY[state.stageId]
		if floor and part.Position.Y < floor then
			EnemyService.Damage(part, (part:GetAttribute("Health") or 1) + 1, state.lastThrower, true)
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
				SoundKit.PlayAt("PlayerHurt", position)
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
