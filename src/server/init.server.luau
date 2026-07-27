--!nonstrict
--[[
	Server bootstrap.

	Start order matters in two places:

	  • Every tag-driven system (magnet registry, puzzles, gates, hazards,
	    combat) starts *before* StageService builds the world, so they receive
	    the CollectionService added-signals for the geometry rather than having
	    to rescan it.

	  • DataService starts before anything that reads a profile — monetization,
	    records, unlock checks.

	Cross-service wiring that belongs to no single owner lives here: the magnet's
	view of the run systems, and the checkpoint-save pass.
]]

local CollectionService = game:GetService("CollectionService")
local PhysicsService = game:GetService("PhysicsService")
local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local GameConfig = require(Shared.Config.GameConfig)

local BossService = require(script.Combat.BossService)
local CombatService = require(script.Combat.CombatService)
local DataService = require(script.Data.DataService)
local EnemyService = require(script.Combat.EnemyService)
local Entitlements = require(script.Monetization.Entitlements)
local GateService = require(script.Stage.GateService)
local GhostService = require(script.Data.GhostService)
local HazardService = require(script.Stage.HazardService)
local MagnetService = require(script.Magnet.MagnetService)
local MonetizationService = require(script.Monetization.MonetizationService)
local MotionService = require(script.Stage.MotionService)
local MovementAudit = require(script.Run.MovementAudit)
local MedalCalibration = require(script.Data.MedalCalibration)
local PuzzleService = require(script.Stage.PuzzleService)
local RecordService = require(script.Data.RecordService)
local RespawnService = require(script.Run.RespawnService)
local RunSessionService = require(script.Run.RunSessionService)
local StageActivity = require(script.Stage.StageActivity)
local StageService = require(script.Stage.StageService)

-- ─────────────────────────────────────────────────────────────────────────────
-- Collision groups
-- ─────────────────────────────────────────────────────────────────────────────

--- Players pass through each other. Stages are shared space, and a second
--- player standing on a launch pad should never be able to block — or boost —
--- someone else's timed run.
local function setupCollisionGroups()
	local groups = GameConfig.CollisionGroups

	for _, name in { groups.Player, groups.Trigger } do
		local ok, err = pcall(function()
			PhysicsService:RegisterCollisionGroup(name)
		end)
		if not ok then
			-- Already registered (Studio reload); harmless.
			if GameConfig.Debug.MagnetResolution then
				warn(`[Bootstrap] collision group {name}: {err}`)
			end
		end
	end

	pcall(function()
		PhysicsService:CollisionGroupSetCollidable(groups.Player, groups.Player, false)

		-- Trigger volumes answer only the run scan, which queries in the Trigger
		-- group. Everything else — crucially the magnet's raycasts — passes
		-- through them.
		PhysicsService:CollisionGroupSetCollidable(groups.Trigger, groups.Default, false)
		PhysicsService:CollisionGroupSetCollidable(groups.Trigger, groups.Player, false)
	end)

	local function assign(character: Model)
		for _, descendant in character:GetDescendants() do
			if descendant:IsA("BasePart") then
				descendant.CollisionGroup = groups.Player
			end
		end
		character.DescendantAdded:Connect(function(descendant)
			if descendant:IsA("BasePart") then
				descendant.CollisionGroup = groups.Player
			end
		end)
	end

	local function watch(player: Player)
		player.CharacterAdded:Connect(assign)
		if player.Character then
			assign(player.Character)
		end
	end

	for _, player in Players:GetPlayers() do
		watch(player)
	end
	Players.PlayerAdded:Connect(watch)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Cross-service wiring
-- ─────────────────────────────────────────────────────────────────────────────

--- The magnet needs to know which stage a player is in (to enforce Pull-only /
--- Push-only) and needs to tell the audit when it applied a legitimate force.
--- Injecting both keeps MagnetService free of a require cycle with the run
--- systems.
local function wireMagnetHooks()
	MagnetService.SetHooks({
		GetActiveStageId = RunSessionService.GetActiveStageId,
		NoteBoost = MovementAudit.NoteBoost,
	})
end

--- The CheckpointSave pass: persist the last checkpoint so a player can pick up
--- where they left off in a later session. It saves *practice position only* —
--- the timed run still has to be started from the beginning, so this cannot
--- shorten a recorded time.
local function wireCheckpointSave()
	local function serialize(cframe: CFrame): { number }
		return { cframe:GetComponents() }
	end

	RunSessionService.CheckpointReached:Connect(function(player: Player, stageId: string)
		if not Entitlements.Has(player, "CheckpointSave") then
			return
		end
		local profile = DataService.Get(player)
		local cframe = RunSessionService.GetCheckpointCFrame(player)
		if not profile or not cframe then
			return
		end
		profile.checkpoint = { stageId = stageId, components = serialize(cframe) }
	end)

	DataService.ProfileLoaded:Connect(function(player: Player, profile)
		local saved = profile.checkpoint
		if not saved or not Entitlements.Has(player, "CheckpointSave") then
			return
		end
		if typeof(saved.components) ~= "table" or #saved.components ~= 12 then
			return
		end
		RunSessionService.RestoreCheckpoint(player, CFrame.new(table.unpack(saved.components)))
	end)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Boot
-- ─────────────────────────────────────────────────────────────────────────────

local function main()
	-- Before anything can join: RespawnService owns spawning, and an automatic
	-- spawn slipping through would land the player in an unbuilt world.
	Players.CharacterAutoLoads = false

	setupCollisionGroups()

	-- Data first: monetization and unlock checks both read profiles.
	DataService.Start()
	MonetizationService.Start()

	-- Before the tag-driven systems: they consult it every tick, and an
	-- unstarted tracker would report every stage awake.
	StageActivity.Start()

	-- Tag-driven systems, before the world exists.
	MagnetService.Start()
	EnemyService.Start()
	CombatService.Start()
	BossService.Start()
	PuzzleService.Start()
	GateService.Start()
	MotionService.Start()
	HazardService.Start()

	-- Run systems. GhostService starts after RecordService because it listens to
	-- that service's personal-best signal.
	RunSessionService.Start()
	RecordService.Start()
	GhostService.Start()
	MedalCalibration.Start()

	wireMagnetHooks()
	wireCheckpointSave()

	-- Build the world before anyone spawns into it, and after every
	-- added-signal above is already listening.
	StageService.Start()

	-- Spawning last: the hub SpawnLocation only exists once StageService ran.
	RespawnService.Start()

	print(
		`[MagnetWarrior] server ready — {#CollectionService:GetTagged(GameConfig.Tags.Magnetic)} magnetic parts`
	)
end

main()
