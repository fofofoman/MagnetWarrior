--!nonstrict
--[[
	StageService.luau

	Owns the world: builds the hub and every stage that has a layout, answers the
	stage roster query, and handles stage-select teleports.

	Two things worth calling out:

	**Unlocks are server-side.** `requires` in StageConfig is checked here
	against the player's saved records before a teleport is allowed. The client's
	stage list greys out locked entries as a courtesy; the server refuses them as
	the actual rule.

	**Stages reset when they go idle.** Stages are shared world space, so a
	solved puzzle or a cleared arena would otherwise stay solved for the next
	player. When a run starts and nobody else is running that stage, its puzzles,
	gates and enemies are put back. That keeps a shared server honest without
	needing per-player instancing.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local GameConfig = require(Shared.Config.GameConfig)
local Net = require(Shared.Net)
local RateLimiter = require(Shared.Util.RateLimiter)
local StageConfig = require(Shared.Config.StageConfig)
local Types = require(Shared.Types)

local BossService = require(script.Parent.Parent.Combat.BossService)
local DataService = require(script.Parent.Parent.Data.DataService)
local EnemyService = require(script.Parent.Parent.Combat.EnemyService)
local GateService = require(script.Parent.GateService)
local MagnetService = require(script.Parent.Parent.Magnet.MagnetService)
local PuzzleService = require(script.Parent.PuzzleService)
local RunSessionService = require(script.Parent.Parent.Run.RunSessionService)
local StageBuilder = require(script.Parent.StageBuilder)

local StageService = {}

local HUB_ORIGIN_X = -2000

local layouts: { [string]: StageBuilder.Layout } = {
	stage_01_pull = require(script.Parent.Layouts.Stage01Pull),
	stage_02_push = require(script.Parent.Layouts.Stage02Push),
	stage_03_scrapyard = require(script.Parent.Layouts.Stage03Scrapyard),
	stage_04_crossfire = require(script.Parent.Layouts.Stage04Crossfire),
	stage_05_gauntlet = require(script.Parent.Layouts.Stage05Gauntlet),
	stage_06_assembly = require(script.Parent.Layouts.Stage06Assembly),
	stage_07_cadence = require(script.Parent.Layouts.Stage07Cadence),
	stage_08_foundry = require(script.Parent.Layouts.Stage08Foundry),
	stage_09_miniboss = require(script.Parent.Layouts.Stage09Miniboss),
	stage_10_finalboss = require(script.Parent.Layouts.Stage10FinalBoss),
	stage_11_extra = require(script.Parent.Layouts.Stage11Hangar),
	stage_12_extra = require(script.Parent.Layouts.Stage12DisposalLine),
}

local built: { [string]: StageBuilder.BuiltStage } = {}
local hubSpawn = CFrame.new(HUB_ORIGIN_X, 6, 0)

local teleportLimiter = RateLimiter.new(0.5, 3)

export type StageRosterEntry = {
	id: string,
	order: number,
	displayName: string,
	kind: Types.StageKind,
	description: string,
	allowedActions: { Types.MagnetAction },
	medals: Types.MedalThresholds,
	checkpointCount: number,
	playable: boolean,
	unlocked: boolean,
	requires: string?,
}

-- ─────────────────────────────────────────────────────────────────────────────
-- World construction
-- ─────────────────────────────────────────────────────────────────────────────

local function buildHub(parent: Instance)
	local hub = Instance.new("Model")
	hub.Name = "Hub"

	local floor = Instance.new("Part")
	floor.Name = "HubFloor"
	floor.Size = Vector3.new(120, 2, 120)
	floor.Position = Vector3.new(HUB_ORIGIN_X, 0, 0)
	floor.Anchored = true
	floor.Color = Color3.fromRGB(58, 64, 74)
	floor.Material = Enum.Material.Metal
	floor.TopSurface = Enum.SurfaceType.Smooth
	floor.Parent = hub

	local spawnLocation = Instance.new("SpawnLocation")
	spawnLocation.Name = "HubSpawn"
	spawnLocation.Size = Vector3.new(12, 1, 12)
	spawnLocation.Position = Vector3.new(HUB_ORIGIN_X, 1.5, 0)
	spawnLocation.Anchored = true
	spawnLocation.Neutral = true
	spawnLocation.Duration = 0
	spawnLocation.Color = Color3.fromRGB(88, 224, 132)
	spawnLocation.Material = Enum.Material.Neon
	spawnLocation.Parent = hub

	-- A practice wall and a practice crate, so the magnet can be tried out
	-- before entering a timed stage.
	local practiceWall = Instance.new("Part")
	practiceWall.Name = "PracticeWall"
	practiceWall.Size = Vector3.new(40, 24, 3)
	practiceWall.Position = Vector3.new(HUB_ORIGIN_X, 12, 40)
	practiceWall.Anchored = true
	practiceWall.Color = StageBuilder.Palette.MagnetBlue
	practiceWall.Material = Enum.Material.Metal
	practiceWall.Parent = hub

	local practiceCrate = Instance.new("Part")
	practiceCrate.Name = "PracticeCrate"
	practiceCrate.Size = Vector3.new(6, 6, 6)
	practiceCrate.Position = Vector3.new(HUB_ORIGIN_X + 14, 5, 10)
	practiceCrate.Anchored = false
	practiceCrate.Color = StageBuilder.Palette.MagnetRed
	practiceCrate.Material = Enum.Material.DiamondPlate
	-- Matches the crates in the stages, so what the hub teaches is what the
	-- stages do.
	practiceCrate.CustomPhysicalProperties = PhysicalProperties.new(0.22, 0.5, 0.2, 1, 1)
	practiceCrate.Parent = hub

	-- The hub has edges too; falling off it should reset you, not drop you
	-- through the world forever.
	local killPlane = Instance.new("Part")
	killPlane.Name = "HubKillPlane"
	killPlane.Size = Vector3.new(900, 4, 900)
	killPlane.Position = Vector3.new(HUB_ORIGIN_X, -60, 0)
	killPlane.Anchored = true
	killPlane.CanCollide = false
	killPlane.CanQuery = false
	killPlane.Transparency = 1
	killPlane.Parent = hub

	hub.Parent = parent

	local CollectionService = game:GetService("CollectionService")
	CollectionService:AddTag(killPlane, GameConfig.Tags.Killbrick)
	CollectionService:AddTag(practiceWall, GameConfig.Tags.Magnetic)
	CollectionService:AddTag(practiceWall, GameConfig.Tags.MagneticSurface)
	CollectionService:AddTag(practiceCrate, GameConfig.Tags.Magnetic)

	hubSpawn = CFrame.new(HUB_ORIGIN_X, 6, 0)
end

local function spawnStageEnemies(stageId: string)
	local stage = built[stageId]
	if not stage then
		return
	end

	EnemyService.ClearStage(stageId)
	for _, spec in stage.enemies do
		EnemyService.Spawn(spec.kind, stage.origin + spec.position, stageId, spec.group)
	end
end

--- Puts a stage back to its starting state.
function StageService.ResetStage(stageId: string)
	PuzzleService.ResetStage(stageId)
	GateService.CloseStage(stageId)
	spawnStageEnemies(stageId)
	BossService.ResetStage(stageId)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Roster and teleports
-- ─────────────────────────────────────────────────────────────────────────────

local function hasCompleted(player: Player, stageId: string?): boolean
	if not stageId then
		return true
	end
	local profile = DataService.Get(player)
	if not profile then
		return false
	end
	local record = profile.records[stageId]
	return record ~= nil and record.completions > 0
end

local function buildRoster(player: Player): { StageRosterEntry }
	local roster: { StageRosterEntry } = {}

	for _, definition in StageConfig.Ordered() do
		table.insert(roster, {
			id = definition.id,
			order = definition.order,
			displayName = definition.displayName,
			kind = definition.kind,
			description = definition.description,
			allowedActions = definition.allowedActions,
			medals = definition.medals,
			checkpointCount = definition.checkpointCount,
			playable = definition.hasLayout and built[definition.id] ~= nil,
			unlocked = hasCompleted(player, definition.requires),
			requires = definition.requires,
		})
	end

	return roster
end

local function teleportTo(player: Player, cframe: CFrame)
	local character = player.Character
	if not character or not character.PrimaryPart then
		return
	end

	RunSessionService.AbortRun(player, "teleported")
	RunSessionService.ClearCheckpoint(player)
	MagnetService.ClearPlayerState(player)

	character:PivotTo(cframe)

	local root = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if root then
		root.AssemblyLinearVelocity = Vector3.zero
	end
end

local function onTeleportRequest(player: Player, payload: any)
	if not teleportLimiter:Consume(player) then
		return
	end
	if typeof(payload) ~= "table" then
		return
	end

	local stageId = payload.stageId
	if stageId == "hub" then
		teleportTo(player, hubSpawn)
		return
	end

	if typeof(stageId) ~= "string" then
		return
	end

	local definition = StageConfig.Get(stageId)
	local stage = built[stageId]
	if not definition or not stage then
		Net.Notify:FireClient(player, { text = "아직 준비되지 않은 스테이지입니다.", tone = "Warn" })
		return
	end

	-- The unlock rule lives here, not in the UI.
	if not hasCompleted(player, definition.requires) then
		local required = definition.requires and StageConfig.Get(definition.requires)
		Net.Notify:FireClient(player, {
			text = if required then `먼저 "{required.displayName}"을(를) 클리어해야 합니다.` else "잠긴 스테이지입니다.",
			tone = "Warn",
		})
		return
	end

	teleportTo(player, stage.spawnCFrame)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Lifecycle
-- ─────────────────────────────────────────────────────────────────────────────

function StageService.Start()
	local stages = Instance.new("Folder")
	stages.Name = "Stages"
	stages.Parent = workspace

	buildHub(stages)

	for _, definition in StageConfig.Ordered() do
		local layout = layouts[definition.id]
		if not layout then
			if definition.hasLayout then
				warn(`[StageService] {definition.id} claims hasLayout but no layout module is registered`)
			end
			continue
		end

		local ok, result = pcall(StageBuilder.Build, definition, layout, stages)
		if ok then
			built[definition.id] = result
			-- Anything knocked below the stage dies rather than falling forever.
			EnemyService.SetStageVoidY(definition.id, result.killY)
			if result.boss then
				BossService.Register(definition.id, result.boss, result.origin)
			end
		else
			warn(`[StageService] failed to build {definition.id}: {result}`)
		end
	end

	-- Enemies and bosses exist as soon as the world does, not only after
	-- someone starts a run.
	for stageId in built do
		spawnStageEnemies(stageId)
		BossService.ResetStage(stageId)
	end

	-- Reset a stage when a run starts on it and nobody else is mid-run there.
	RunSessionService.Started:Connect(function(_player: Player, stageId: string)
		if RunSessionService.CountActiveRuns(stageId) <= 1 then
			StageService.ResetStage(stageId)
		end
	end)

	Net.RequestStageTeleport.OnServerEvent:Connect(function(player, payload)
		local ok, err = pcall(onTeleportRequest, player, payload)
		if not ok then
			warn(`[StageService] teleport error for {player.Name}: {err}`)
		end
	end)

	Net.GetStageRoster.OnServerInvoke = function(player: Player)
		return buildRoster(player)
	end

	Players.PlayerRemoving:Connect(function(player)
		teleportLimiter:Release(player)
	end)
end

function StageService.GetHubSpawn(): CFrame
	return hubSpawn
end

return StageService
