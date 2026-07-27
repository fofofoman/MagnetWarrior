--!nonstrict
--[[
	BossService.luau — 보스전

	A boss is deliberately *not* a new entity type. Its core is an ordinary
	EnemyService body with a large health pool, which means impact damage,
	magnetic grabbing, the death signal and the gate that opens on death all work
	without a line of special-case code. What this module adds is the pattern:
	when the core can be hurt, and what the boss does in between.

	The armour cycle is the fight:

	  닫힘 (closed)  — core is Invulnerable and carries no Magnetic tag. The
	                   magnet does nothing to it. Read the pattern, dodge, and
	                   gather scrap.
	  열림 (open)    — plates retract, core becomes magnetic and vulnerable.
	                   Two ways to hurt it, both magnetic:
	                     · push scrap into the exposed core
	                     · yank the core itself hard enough with Pull

	Scrap thrown *by* the boss is the ammunition for the first one. It damages
	the player on contact, but the moment a player pushes it, MagneticRegistry
	marks it thrown and CombatService starts treating it as a weapon — so the
	boss arms you every few seconds and the fight is about turning that around.
]]

local CollectionService = game:GetService("CollectionService")
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local GameConfig = require(Shared.Config.GameConfig)
local Signal = require(Shared.Util.Signal)
local Trove = require(Shared.Util.Trove)

local EnemyService = require(script.Parent.EnemyService)
local MagneticRegistry = require(script.Parent.Parent.Magnet.MagneticRegistry)

local BossService = {}

local TICK_RATE = 15 -- Hz
local ARMOR_SLIDE_TIME = 0.5
--- MaxForce has to exceed the core's weight or it simply falls out of its
--- cradle (mass ~68 × gravity 145 ≈ 9900). Responsiveness is what actually
--- governs how far a Pull can drag it: it sets the stiffness of the spring, and
--- a soft spring under a high force cap is exactly "heavy but wrenchable".
local CORE_HOLD_FORCE = 40000
local CORE_RESPONSIVENESS = 8

--- Yank detection is by *displacement from the cradle*, not by speed. The
--- velocity spike from a Pull lasts a few frames and this loop runs at 15 Hz,
--- so sampling speed would miss most successful yanks; displacement persists
--- long enough to be seen.
---
--- TUNING: this threshold is the one number here that wants checking against
--- the real engine. Too high and Pull does nothing to the boss; too low and the
--- core's idle drift triggers free damage.
local YANK_DISTANCE = 2.5
local YANK_DAMAGE = 55
local YANK_COOLDOWN = 1.2

local SCRAP_DAMAGE = 18
local SCRAP_LIFETIME = 14

export type BossSpec = {
	id: string,
	kind: string, -- EnemyService kind for the core
	position: Vector3, -- relative to stage origin
	closedSeconds: number,
	openSeconds: number,
	throwInterval: number,
	throwSpeed: number,
	--- Optional reinforcement wave while the armour is shut.
	adds: { kind: string, count: number, interval: number, spread: number }?,
}

type BossState = {
	spec: BossSpec,
	stageId: string,
	core: BasePart,
	anchorPosition: Vector3,
	align: AlignPosition,
	plates: { BasePart },
	plateHomes: { CFrame },
	plateOpen: { CFrame },
	trove: any,
	open: boolean,
	phaseUntil: number,
	nextThrowAt: number,
	nextAddAt: number,
	lastYankAt: number,
	alive: boolean,
}

local bosses: { [string]: BossState } = {} -- keyed by `stageId::bossId`
local specs: { [string]: { spec: BossSpec, origin: Vector3 } } = {}
local heartbeat: RBXScriptConnection?

BossService.ArmorOpened = Signal.new() -- (stageId, bossId)
BossService.ArmorClosed = Signal.new()
BossService.Defeated = Signal.new() -- (stageId, bossId)

local function keyFor(stageId: string, bossId: string): string
	return `{stageId}::{bossId}`
end

--- The enemy group a boss core belongs to. Gates open on this the same way they
--- open on a cleared arena — no separate "boss defeated" gate condition needed.
function BossService.GroupFor(bossId: string): string
	return `boss_{bossId}`
end

local function nearestPlayer(position: Vector3): (Player?, BasePart?)
	local bestPlayer, bestRoot, bestDistance = nil, nil, math.huge

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

	return bestPlayer, bestRoot
end

local function playerHumanoidOf(part: BasePart): Humanoid?
	local model = part:FindFirstAncestorOfClass("Model")
	while model do
		if Players:GetPlayerFromCharacter(model) then
			return model:FindFirstChildOfClass("Humanoid")
		end
		model = model:FindFirstAncestorOfClass("Model")
	end
	return nil
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Armour
-- ─────────────────────────────────────────────────────────────────────────────

local function setArmor(state: BossState, open: boolean)
	if state.open == open or not state.core.Parent then
		return
	end
	state.open = open

	for index, plate in state.plates do
		if not plate.Parent then
			continue
		end
		-- Each plate has its own retracted position, computed at build time so
		-- the left and right plates slide *apart* rather than both one way.
		local target = if open then state.plateOpen[index] else state.plateHomes[index]
		plate.CanCollide = not open
		TweenService:Create(plate, TweenInfo.new(ARMOR_SLIDE_TIME, Enum.EasingStyle.Quad), {
			CFrame = target,
			Transparency = if open then 0.55 else 0,
		}):Play()
	end

	state.core:SetAttribute("Invulnerable", not open)
	state.core.Material = if open then Enum.Material.Neon else Enum.Material.Metal

	if open then
		CollectionService:AddTag(state.core, GameConfig.Tags.Magnetic)
		BossService.ArmorOpened:Fire(state.stageId, state.spec.id)
	else
		CollectionService:RemoveTag(state.core, GameConfig.Tags.Magnetic)
		-- Snap it home so the next window starts from a known position.
		state.core.AssemblyLinearVelocity = Vector3.zero
		state.core.CFrame = CFrame.new(state.anchorPosition)
		BossService.ArmorClosed:Fire(state.stageId, state.spec.id)
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Attacks
-- ─────────────────────────────────────────────────────────────────────────────

local function throwScrap(state: BossState)
	local _player, root = nearestPlayer(state.core.Position)
	if not root then
		return
	end

	local muzzle = state.core.Position + Vector3.new(0, 4, 0)
	local toTarget = root.Position - muzzle
	if toTarget.Magnitude < 1 then
		return
	end

	local scrap = Instance.new("Part")
	scrap.Name = "BossScrap"
	scrap.Size = Vector3.new(4, 4, 4)
	scrap.CFrame = CFrame.new(muzzle)
	scrap.Color = Color3.fromRGB(168, 128, 96)
	scrap.Material = Enum.Material.CorrodedMetal
	scrap.CustomPhysicalProperties = PhysicalProperties.new(0.6, 0.5, 0.2, 1, 1)
	scrap.Parent = workspace:FindFirstChild("Enemies") or workspace

	-- Tag after parenting: MagneticRegistry claims server ownership on tag, and
	-- it needs the part to already be in the world.
	CollectionService:AddTag(scrap, GameConfig.Tags.Magnetic)

	-- Lead the shot slightly upward so it arcs instead of grazing the floor.
	local direction = toTarget.Unit + Vector3.new(0, 0.18, 0)
	scrap.AssemblyLinearVelocity = direction.Unit * state.spec.throwSpeed

	local connection
	connection = scrap.Touched:Connect(function(other: BasePart)
		if not scrap.Parent then
			return
		end
		-- The instant a player pushes it, this stops being an attack and becomes
		-- their ammunition — permanently. Disconnecting rather than skipping
		-- matters: MagneticRegistry's thrown window expires after a couple of
		-- seconds, and without this a shot you deflected and missed with would
		-- turn hostile again and hit you on the roll.
		if MagneticRegistry.IsThrown(scrap) then
			connection:Disconnect()
			return
		end
		local humanoid = playerHumanoidOf(other)
		if humanoid and humanoid.Health > 0 then
			humanoid:TakeDamage(SCRAP_DAMAGE)
			connection:Disconnect()
			scrap:Destroy()
		end
	end)

	Debris:AddItem(scrap, SCRAP_LIFETIME)
end

local function spawnAdds(state: BossState)
	local adds = state.spec.adds
	if not adds then
		return
	end

	for index = 1, adds.count do
		local angle = (index / adds.count) * math.pi * 2
		local offset = Vector3.new(math.cos(angle), 0, math.sin(angle)) * adds.spread
		EnemyService.Spawn(
			adds.kind,
			state.core.Position + offset + Vector3.new(0, 2, 0),
			state.stageId,
			`{BossService.GroupFor(state.spec.id)}_adds`
		)
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Lifecycle
-- ─────────────────────────────────────────────────────────────────────────────

local function despawn(key: string)
	local state = bosses[key]
	if not state then
		return
	end
	bosses[key] = nil
	state.trove:Clean()
end

local function spawnBoss(stageId: string, spec: BossSpec, origin: Vector3)
	local key = keyFor(stageId, spec.id)
	despawn(key)

	local anchorPosition = origin + spec.position
	local trove = Trove.new()

	-- The machine the core sits in. Purely structural, and anchored so the boss
	-- has a silhouette that does not get shoved around.
	local body = trove:Add(Instance.new("Part"))
	body.Name = `BossBody_{spec.id}`
	body.Size = Vector3.new(20, 22, 10)
	body.CFrame = CFrame.new(anchorPosition - Vector3.new(0, 2, -9))
	body.Anchored = true
	body.Color = Color3.fromRGB(52, 56, 66)
	body.Material = Enum.Material.DiamondPlate
	body.Parent = workspace:FindFirstChild("Enemies") or workspace

	local core = EnemyService.Spawn(spec.kind, anchorPosition, stageId, BossService.GroupFor(spec.id))
	if not core then
		warn(`[BossService] could not spawn core for {spec.id}`)
		trove:Clean()
		return
	end
	trove:Add(core)

	-- Held in place softly enough that a hard Pull visibly drags it out.
	local attachment = Instance.new("Attachment")
	attachment.Name = "CoreAnchor"
	attachment.Parent = core

	local align = Instance.new("AlignPosition")
	align.Name = "CoreHold"
	align.Mode = Enum.PositionAlignmentMode.OneAttachment
	align.Attachment0 = attachment
	align.Position = anchorPosition
	align.MaxForce = CORE_HOLD_FORCE
	align.Responsiveness = CORE_RESPONSIVENESS
	align.RigidityEnabled = false
	align.Parent = core

	local plates: { BasePart } = {}
	local plateHomes: { CFrame } = {}
	local plateOpen: { CFrame } = {}

	for _, side in { -1, 1 } do
		local plate = trove:Add(Instance.new("Part"))
		plate.Name = `BossArmor_{spec.id}`
		plate.Size = Vector3.new(5, 11, 3)
		plate.CFrame = CFrame.new(anchorPosition + Vector3.new(side * 4.5, 0, 0))
		plate.Anchored = true
		plate.Color = Color3.fromRGB(96, 104, 118)
		plate.Material = Enum.Material.Metal
		plate.Parent = workspace:FindFirstChild("Enemies") or workspace

		table.insert(plates, plate)
		table.insert(plateHomes, plate.CFrame)
		table.insert(plateOpen, plate.CFrame + Vector3.new(side * 6, 0, 0))
	end

	local now = os.clock()
	local state: BossState = {
		spec = spec,
		stageId = stageId,
		core = core,
		anchorPosition = anchorPosition,
		align = align,
		plates = plates,
		plateHomes = plateHomes,
		plateOpen = plateOpen,
		trove = trove,
		open = true, -- flipped below so setArmor actually applies the closed look
		phaseUntil = now + spec.closedSeconds,
		nextThrowAt = now + spec.throwInterval,
		nextAddAt = if spec.adds then now + spec.adds.interval else math.huge,
		lastYankAt = 0,
		alive = true,
	}

	bosses[key] = state
	setArmor(state, false)
end

local function step()
	local now = os.clock()

	for key, state in bosses do
		local core = state.core
		if not core.Parent or not state.alive then
			despawn(key)
			continue
		end

		-- Armour cycle.
		if now >= state.phaseUntil then
			local nextOpen = not state.open
			setArmor(state, nextOpen)
			state.phaseUntil = now + (if nextOpen then state.spec.openSeconds else state.spec.closedSeconds)
		end

		-- Yank damage: only while exposed, and only if the core actually left
		-- its cradle.
		if state.open and (core.Position - state.anchorPosition).Magnitude >= YANK_DISTANCE then
			if (now - state.lastYankAt) >= YANK_COOLDOWN then
				state.lastYankAt = now
				EnemyService.Damage(core, YANK_DAMAGE, MagneticRegistry.Thrower(core))
			end
		end

		if now >= state.nextThrowAt then
			state.nextThrowAt = now + state.spec.throwInterval
			throwScrap(state)
		end

		if now >= state.nextAddAt then
			local adds = state.spec.adds
			state.nextAddAt = if adds then now + adds.interval else math.huge
			spawnAdds(state)
		end
	end
end

--- Registers a boss so ResetStage can rebuild it. Called by StageService when
--- the stage is built.
function BossService.Register(stageId: string, spec: BossSpec, origin: Vector3)
	specs[keyFor(stageId, spec.id)] = { spec = spec, origin = origin }
end

--- Rebuilds every boss belonging to a stage.
function BossService.ResetStage(stageId: string)
	for key, entry in specs do
		if string.sub(key, 1, #stageId + 2) == `{stageId}::` then
			spawnBoss(stageId, entry.spec, entry.origin)
		end
	end
end

function BossService.Start()
	EnemyService.EnemyDied:Connect(function(part: BasePart, stageId: string, group: string)
		for key, state in bosses do
			if state.core ~= part then
				continue
			end
			state.alive = false
			-- Clear the adds so a defeated boss does not leave escorts behind.
			EnemyService.ClearGroup(stageId, `{group}_adds`)
			BossService.Defeated:Fire(stageId, state.spec.id)
			despawn(key)
			break
		end
	end)

	if heartbeat then
		return
	end

	local accumulator = 0
	local interval = 1 / TICK_RATE
	heartbeat = RunService.Heartbeat:Connect(function(deltaTime)
		accumulator += deltaTime
		if accumulator < interval then
			return
		end
		accumulator = 0
		step()
	end)
end

return BossService
