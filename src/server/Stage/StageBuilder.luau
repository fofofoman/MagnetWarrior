--!nonstrict
--[[
	StageBuilder.luau

	Stages are described as Lua data and built at runtime rather than saved as
	binary .rbxm models. For a solo developer working out of git that trade is
	worth making: a layout change shows up as a readable diff, twelve stages cost
	twelve small files instead of twelve opaque blobs, and tags/attributes can
	never drift out of sync with the code that reads them because this builder
	applies both.

	The cost is that geometry is written by hand. Everything below exists to keep
	that cheap: sensible defaults, one entry per solid, and helpers for the four
	things every stage needs (triggers, magnetic props, sockets, gates).
]]

local CollectionService = game:GetService("CollectionService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local GameConfig = require(Shared.Config.GameConfig)
local Types = require(Shared.Types)

-- Required for its BossSpec type only; StageService does the actual spawning.
local BossService = require(script.Parent.Parent.Combat.BossService)

local StageBuilder = {}

export type BossSpec = BossService.BossSpec

export type PartSpec = {
	name: string?,
	size: Vector3,
	position: Vector3,
	orientation: Vector3?, -- degrees
	color: Color3?,
	material: Enum.Material?,
	anchored: boolean?,
	canCollide: boolean?,
	--- Set false for decoration the magnet should shoot straight through.
	canQuery: boolean?,
	transparency: number?,
	density: number?,
	--- Magnetic parts only: marks an anchored wall as clingable.
	surface: boolean?,
	tags: { string }?,
	attributes: { [string]: any }?,
}

export type TriggerSpec = {
	position: Vector3,
	size: Vector3,
}

export type EnemySpec = {
	kind: string,
	position: Vector3,
	group: string?,
}

export type SocketSpec = {
	position: Vector3,
	size: Vector3?,
	orientation: Vector3?,
	group: string,
}

export type BlockSpec = {
	position: Vector3,
	size: Vector3?,
	group: string,
}

export type GateSpec = {
	id: string,
	position: Vector3,
	size: Vector3,
	openBy: { kind: "Enemies" | "Sockets", group: string },
}

--- A magnet wall that moves, pulses its polarity, or both. Give several the
--- same `period` and different `phase` values to compose a rhythm — that is how
--- the timing stages are authored. See MotionService.
export type KineticSpec = {
	name: string?,
	size: Vector3,
	position: Vector3, -- centre of travel
	--- Half-amplitude of the oscillation. Omit for a wall that only pulses.
	travel: Vector3?,
	period: number, -- seconds for one full cycle
	phase: number?, -- 0..1 offset into the cycle
	--- When true the wall's magnetism switches on and off within the cycle.
	pulses: boolean?,
	dutyCycle: number?, -- fraction of the cycle spent magnetic (default 0.5)
	--- Extra offset applied to the polarity window only, so a wall that travels
	--- *and* pulses can be live during the half of its sweep that matters.
	pulsePhase: number?,
	--- Clingable while live. Almost always true for these.
	surface: boolean?,
}

export type Layout = {
	spawn: Vector3,
	parts: { PartSpec },
	magnetic: { PartSpec }?,
	start: TriggerSpec,
	finish: TriggerSpec,
	checkpoints: { TriggerSpec },
	enemies: { EnemySpec }?,
	sockets: { SocketSpec }?,
	blocks: { BlockSpec }?,
	gates: { GateSpec }?,
	kinetics: { KineticSpec }?,
	boss: BossSpec?,
	--- Y below which the player is killed. Defaults to 60 studs under spawn.
	killY: number?,
}

export type BuiltStage = {
	model: Model,
	spawnCFrame: CFrame,
	enemies: { EnemySpec },
	origin: Vector3,
	boss: BossSpec?,
	--- Absolute Y of the kill volume. EnemyService uses it so enemies knocked
	--- off the stage die instead of falling forever.
	killY: number,
}

local STEEL = Color3.fromRGB(122, 132, 143)
local MAGNET_BLUE = Color3.fromRGB(64, 156, 255)
local MAGNET_RED = Color3.fromRGB(255, 96, 88)
local TRIGGER_GREEN = Color3.fromRGB(88, 224, 132)
local TRIGGER_GOLD = Color3.fromRGB(255, 206, 84)
local CHECKPOINT_CYAN = Color3.fromRGB(102, 217, 232)

StageBuilder.Palette = {
	Steel = STEEL,
	MagnetBlue = MAGNET_BLUE,
	MagnetRed = MAGNET_RED,
}

local function applyAttributes(instance: Instance, attributes: { [string]: any }?)
	if not attributes then
		return
	end
	for key, value in attributes do
		instance:SetAttribute(key, value)
	end
end

local function applyTags(instance: Instance, tags: { string }?)
	if not tags then
		return
	end
	for _, tag in tags do
		CollectionService:AddTag(instance, tag)
	end
end

local function makePart(spec: PartSpec, origin: Vector3, parent: Instance): BasePart
	local part = Instance.new("Part")
	part.Name = spec.name or "Solid"
	part.Size = spec.size
	part.Anchored = if spec.anchored ~= nil then spec.anchored else true
	part.CanCollide = if spec.canCollide ~= nil then spec.canCollide else true
	part.CanQuery = if spec.canQuery ~= nil then spec.canQuery else true
	part.Color = spec.color or STEEL
	part.Material = spec.material or Enum.Material.Metal
	part.Transparency = spec.transparency or 0
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth

	local position = origin + spec.position
	if spec.orientation then
		part.CFrame = CFrame.new(position)
			* CFrame.Angles(
				math.rad(spec.orientation.X),
				math.rad(spec.orientation.Y),
				math.rad(spec.orientation.Z)
			)
	else
		part.CFrame = CFrame.new(position)
	end

	if spec.density then
		part.CustomPhysicalProperties = PhysicalProperties.new(spec.density, 0.5, 0.2, 1, 1)
	end

	applyAttributes(part, spec.attributes)
	applyTags(part, spec.tags)
	part.Parent = parent
	return part
end

local function makeTrigger(
	spec: TriggerSpec,
	origin: Vector3,
	parent: Instance,
	name: string,
	tag: string,
	color: Color3,
	attributes: { [string]: any }
): BasePart
	local part = Instance.new("Part")
	part.Name = name
	part.Size = spec.size
	part.CFrame = CFrame.new(origin + spec.position)
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false -- detection is a server overlap query, not Touched
	part.CanQuery = true
	-- Queryable by the run scan, transparent to the magnet: see
	-- GameConfig.CollisionGroups.Trigger.
	part.CollisionGroup = GameConfig.CollisionGroups.Trigger
	part.Color = color
	part.Material = Enum.Material.Neon
	part.Transparency = 0.72

	applyAttributes(part, attributes)
	CollectionService:AddTag(part, tag)
	part.Parent = parent
	return part
end

--- Builds one stage under `parent` and returns the model plus where to spawn.
function StageBuilder.Build(definition: Types.StageDefinition, layout: Layout, parent: Instance): BuiltStage
	local origin = Vector3.new(definition.originX, 0, 0)

	local model = Instance.new("Model")
	model.Name = definition.id
	model:SetAttribute("StageId", definition.id)

	local solids = Instance.new("Folder")
	solids.Name = "Solids"
	solids.Parent = model

	for _, spec in layout.parts do
		makePart(spec, origin, solids)
	end

	-- Magnetic props. Anchored ones marked `surface` become cling-able walls;
	-- everything else is grabbable furniture.
	local magneticFolder = Instance.new("Folder")
	magneticFolder.Name = "Magnetic"
	magneticFolder.Parent = model

	for _, spec in layout.magnetic or {} do
		local tags = table.clone(spec.tags or {})
		table.insert(tags, GameConfig.Tags.Magnetic)
		if spec.surface then
			table.insert(tags, GameConfig.Tags.MagneticSurface)
		end

		local resolved: PartSpec = table.clone(spec)
		resolved.tags = tags
		resolved.color = spec.color or (if spec.surface then MAGNET_BLUE else STEEL)
		resolved.name = spec.name or (if spec.surface then "MagnetWall" else "SteelProp")
		makePart(resolved, origin, magneticFolder)
	end

	-- Puzzle blocks and their sockets.
	local puzzleFolder = Instance.new("Folder")
	puzzleFolder.Name = "Puzzle"
	puzzleFolder.Parent = model

	for index, spec in layout.blocks or {} do
		makePart({
			name = `PuzzleBlock_{spec.group}_{index}`,
			size = spec.size or Vector3.new(6, 6, 6),
			position = spec.position,
			anchored = false,
			color = MAGNET_RED,
			material = Enum.Material.DiamondPlate,
			-- A 10×2×12 slab at 0.25 is mass 60, which one Pull can move about
			-- 46 studs/s. Heavier than that and dragging a slab to its socket
			-- took so many pulls that the assembly stages stopped being puzzles
			-- and started being chores.
			density = 0.25,
			tags = { GameConfig.Tags.Magnetic, GameConfig.Tags.PuzzleBlock },
			attributes = { StageId = definition.id, PuzzleGroup = spec.group },
		}, origin, puzzleFolder)
	end

	for index, spec in layout.sockets or {} do
		makePart({
			name = `PuzzleSocket_{spec.group}_{index}`,
			size = spec.size or Vector3.new(7, 1, 7),
			position = spec.position,
			orientation = spec.orientation,
			anchored = true,
			canCollide = false,
			-- Placement is a distance check in PuzzleService, so sockets never
			-- need to be raycast — and staying out of the way keeps them from
			-- blocking a shot aimed at the block behind them.
			canQuery = false,
			color = TRIGGER_GOLD,
			material = Enum.Material.Neon,
			transparency = 0.55,
			tags = { GameConfig.Tags.PuzzleSocket },
			attributes = { StageId = definition.id, PuzzleGroup = spec.group },
		}, origin, puzzleFolder)
	end

	-- Kinetic walls. Built live (magnetic) and tagged Kinetic; MotionService
	-- takes over the movement and polarity from there.
	local kineticFolder = Instance.new("Folder")
	kineticFolder.Name = "Kinetic"
	kineticFolder.Parent = model

	for index, spec in layout.kinetics or {} do
		local tags = { GameConfig.Tags.Kinetic, GameConfig.Tags.Magnetic }
		if spec.surface ~= false then
			table.insert(tags, GameConfig.Tags.MagneticSurface)
		end

		makePart({
			name = spec.name or `KineticWall_{index}`,
			size = spec.size,
			position = spec.position,
			anchored = true,
			color = MAGNET_BLUE,
			material = Enum.Material.Neon,
			tags = tags,
			attributes = {
				StageId = definition.id,
				Period = spec.period,
				Phase = spec.phase or 0,
				Travel = spec.travel or Vector3.zero,
				Pulses = spec.pulses == true,
				DutyCycle = spec.dutyCycle or 0.5,
				PulsePhase = spec.pulsePhase or 0,
				IsSurface = spec.surface ~= false,
			},
		}, origin, kineticFolder)
	end

	-- Gates: solid until their condition is met.
	local gateFolder = Instance.new("Folder")
	gateFolder.Name = "Gates"
	gateFolder.Parent = model

	for _, spec in layout.gates or {} do
		makePart({
			name = `Gate_{spec.id}`,
			size = spec.size,
			position = spec.position,
			anchored = true,
			color = Color3.fromRGB(58, 62, 70),
			material = Enum.Material.Metal,
			tags = { GameConfig.Tags.Gate },
			attributes = {
				StageId = definition.id,
				GateId = spec.id,
				OpenByKind = spec.openBy.kind,
				OpenByGroup = spec.openBy.group,
			},
		}, origin, gateFolder)
	end

	-- Run triggers.
	local triggerFolder = Instance.new("Folder")
	triggerFolder.Name = "Triggers"
	triggerFolder.Parent = model

	makeTrigger(layout.start, origin, triggerFolder, "StartZone", GameConfig.Tags.StageStart, TRIGGER_GREEN, {
		StageId = definition.id,
	})

	assert(
		#layout.checkpoints == definition.checkpointCount,
		`{definition.id}: layout has {#layout.checkpoints} checkpoints but StageConfig declares {definition.checkpointCount}`
	)

	for index, spec in layout.checkpoints do
		makeTrigger(
			spec,
			origin,
			triggerFolder,
			`Checkpoint_{index}`,
			GameConfig.Tags.Checkpoint,
			CHECKPOINT_CYAN,
			{ StageId = definition.id, CheckpointIndex = index }
		)
	end

	makeTrigger(layout.finish, origin, triggerFolder, "FinishZone", GameConfig.Tags.StageFinish, TRIGGER_GOLD, {
		StageId = definition.id,
	})

	-- Kill volume under the stage.
	--
	-- Deliberately far larger than any stage's geometry. HazardService only kills
	-- a player who is below the plane *and* inside its footprint, so anyone who
	-- clears the edge falls right past it — a chained launch at
	-- MagnetConfig.ChainedSpeedCap carries about 125 studs during the drop, and
	-- stage 8 already reaches Z 558 against the old 900-stud plane. Overshooting
	-- costs nothing: the part is invisible, non-colliding, non-queryable, and
	-- stages sit 2000 studs apart so neighbouring planes still cannot touch.
	local killY = layout.killY or (layout.spawn.Y - 90)
	makePart({
		name = "KillPlane",
		size = Vector3.new(1600, 4, 1600),
		position = Vector3.new(0, killY, 200),
		anchored = true,
		canCollide = false,
		-- HazardService checks player position against this volume rather than
		-- touching it, so it stays out of every raycast.
		canQuery = false,
		transparency = 1,
		tags = { GameConfig.Tags.Killbrick },
		attributes = { StageId = definition.id },
	}, origin, model)

	model.Parent = parent

	return {
		model = model,
		spawnCFrame = CFrame.new(origin + layout.spawn),
		enemies = layout.enemies or {},
		origin = origin,
		boss = layout.boss,
		killY = killY,
	}
end

return StageBuilder
