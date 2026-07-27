--!nonstrict
--[[
	RunSessionService.luau — the authoritative stage timer.

	The client never tells the server how long a run took. It is not asked, and
	if it volunteered a number there is nowhere for that number to go. The server
	starts the clock when it observes the player inside the start volume, stops
	it when it observes them inside the finish volume, and validates everything
	in between:

	  • checkpoints must be entered in order — skipping one means the finish
	    volume simply does not accept you
	  • the total must exceed the stage's minPossibleMs, a hard floor below which
	    no human route exists
	  • each segment must exceed its own floor, which catches clipping through
	    part of a stage rather than all of it
	  • MovementAudit must not have seen anything unexplainable

	Dying voids the timed run. That is deliberate: it keeps the leaderboard
	meaning "cleared the stage in one go", and it is why checkpoints can double
	as practice respawns without muddying the records.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local GameConfig = require(Shared.Config.GameConfig)
local Net = require(Shared.Net)
local Signal = require(Shared.Util.Signal)
local SoundKit = require(Shared.Util.SoundKit)
local StageConfig = require(Shared.Config.StageConfig)
local Types = require(Shared.Types)

local MovementAudit = require(script.Parent.MovementAudit)

local RunSessionService = {}

local TRIGGER_RATE = 20 -- Hz
local BASE_TRIGGER_RADIUS = 7 -- studs
local START_REENTRY_GRACE = 1.5 -- seconds before touching start again restarts the run

--- A segment may not be faster than this fraction of its fair share of the
--- stage floor. Generous — routing wildly uneven splits is skill, clipping
--- through half the level is not.
local SEGMENT_FLOOR_FACTOR = 0.4

export type RunResult = {
	stageId: string,
	timeMs: number,
	splits: { number },
	valid: boolean,
	reason: string?,
	peakSpeed: number,
	softViolations: number,
	hardViolations: number,
}

type RunState = {
	stageId: string,
	definition: Types.StageDefinition,
	startedAtClock: number,
	startedAtServer: number,
	nextCheckpoint: number,
	splits: { number },
	lastStartTouchAt: number,
}

type TriggerInfo = {
	kind: "Start" | "Finish" | "Checkpoint",
	stageId: string,
	index: number,
}

RunSessionService.Started = Signal.new()
RunSessionService.CheckpointReached = Signal.new()
RunSessionService.Finished = Signal.new() -- (player, RunResult)
RunSessionService.Aborted = Signal.new() -- (player, stageId, reason)

local runs: { [Player]: RunState } = {}
local checkpointCFrames: { [Player]: CFrame } = {}

local triggerInfo: { [BasePart]: TriggerInfo } = {}
local triggerParts: { BasePart } = {}
local overlapParams = OverlapParams.new()
overlapParams.FilterType = Enum.RaycastFilterType.Include
overlapParams.MaxParts = 16
--- Trigger volumes live in their own collision group so that magnet raycasts
--- (which run in the default group) pass straight through them. Without this a
--- checkpoint volume would soak up every shot aimed through it.
overlapParams.CollisionGroup = GameConfig.CollisionGroups.Trigger

--- Called by MagnetService's hook to gate which hands a stage allows.
function RunSessionService.GetActiveStageId(player: Player): string?
	local run = runs[player]
	return run and run.stageId
end

function RunSessionService.GetRunState(player: Player): RunState?
	return runs[player]
end

function RunSessionService.GetCheckpointCFrame(player: Player): CFrame?
	return checkpointCFrames[player]
end

function RunSessionService.ClearCheckpoint(player: Player)
	checkpointCFrames[player] = nil
end

--- How many players are currently timing a run on this stage. StageService uses
--- it to decide when a stage is idle enough to reset its puzzles and enemies.
function RunSessionService.CountActiveRuns(stageId: string): number
	local count = 0
	for _, run in runs do
		if run.stageId == stageId then
			count += 1
		end
	end
	return count
end

--- Restores a checkpoint saved in a previous session (the CheckpointSave pass).
function RunSessionService.RestoreCheckpoint(player: Player, cframe: CFrame)
	checkpointCFrames[player] = cframe
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Trigger registry
-- ─────────────────────────────────────────────────────────────────────────────

local function rebuildTriggerList()
	table.clear(triggerParts)
	for part in triggerInfo do
		if part.Parent then
			table.insert(triggerParts, part)
		end
	end
	overlapParams.FilterDescendantsInstances = triggerParts
end

local function registerTrigger(instance: Instance, kind: "Start" | "Finish" | "Checkpoint")
	if not instance:IsA("BasePart") then
		return
	end

	local stageId = instance:GetAttribute("StageId")
	if typeof(stageId) ~= "string" then
		warn(`[RunSession] {instance:GetFullName()} is tagged as a {kind} trigger but has no StageId attribute`)
		return
	end

	local index = instance:GetAttribute("CheckpointIndex")
	triggerInfo[instance] = {
		kind = kind,
		stageId = stageId,
		index = if typeof(index) == "number" then index else 0,
	}
	rebuildTriggerList()
end

local function unregisterTrigger(instance: Instance)
	if instance:IsA("BasePart") and triggerInfo[instance] then
		triggerInfo[instance] = nil
		rebuildTriggerList()
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Run lifecycle
-- ─────────────────────────────────────────────────────────────────────────────

local function pushUpdate(player: Player, update: Types.RunUpdate)
	Net.RunUpdate:FireClient(player, update)
end

local function abortRun(player: Player, reason: string)
	local run = runs[player]
	if not run then
		return
	end
	runs[player] = nil
	MovementAudit.Finish(player)

	pushUpdate(player, {
		kind = "Aborted",
		stageId = run.stageId,
		rejected = true,
		rejectReason = reason,
	})
	RunSessionService.Aborted:Fire(player, run.stageId, reason)
end

--- Public abort, used when a player teleports away mid-run.
function RunSessionService.AbortRun(player: Player, reason: string)
	abortRun(player, reason)
end

local function startRun(player: Player, stageId: string)
	local definition = StageConfig.Get(stageId)
	if not definition then
		warn(`[RunSession] start trigger references unknown stage "{stageId}"`)
		return
	end
	if not definition.hasLayout then
		return
	end

	local existing = runs[player]
	if existing and existing.stageId == stageId then
		if (os.clock() - existing.lastStartTouchAt) < START_REENTRY_GRACE then
			-- Still standing in the start volume. Refresh the stamp so the grace
			-- window tracks "continuously inside" rather than "entered once".
			existing.lastStartTouchAt = os.clock()
			return
		end
	end

	if existing then
		abortRun(player, "restarted")
	end

	local now = os.clock()
	runs[player] = {
		stageId = stageId,
		definition = definition,
		startedAtClock = now,
		startedAtServer = workspace:GetServerTimeNow(),
		nextCheckpoint = 1,
		splits = {},
		lastStartTouchAt = now,
	}

	MovementAudit.Begin(player)

	pushUpdate(player, {
		kind = "Started",
		stageId = stageId,
		startedAt = runs[player].startedAtServer,
		elapsedMs = 0,
		checkpointIndex = 0,
		checkpointTotal = definition.checkpointCount,
	})
	RunSessionService.Started:Fire(player, stageId)
end

local function elapsedMsOf(run: RunState): number
	return math.floor((os.clock() - run.startedAtClock) * 1000)
end

local function reachCheckpoint(player: Player, run: RunState, info: TriggerInfo, part: BasePart)
	if info.index ~= run.nextCheckpoint then
		-- Out of order. No credit, no message: the finish volume will refuse
		-- them later, which is the actual anti-skip enforcement.
		return
	end

	local elapsed = elapsedMsOf(run)
	table.insert(run.splits, elapsed)
	run.nextCheckpoint += 1

	-- Respawn a short hop above the *floor* of the trigger volume, not above its
	-- centre — checkpoint volumes are tall, and spawning at the top of one drops
	-- the player from height.
	checkpointCFrames[player] = part.CFrame - Vector3.new(0, part.Size.Y / 2 - 4, 0)
	SoundKit.PlayAt("Checkpoint", part.Position)

	pushUpdate(player, {
		kind = "Checkpoint",
		stageId = run.stageId,
		elapsedMs = elapsed,
		checkpointIndex = info.index,
		checkpointTotal = run.definition.checkpointCount,
		splitMs = elapsed - (run.splits[#run.splits - 1] or 0),
	})
	RunSessionService.CheckpointReached:Fire(player, run.stageId, info.index, elapsed)
end

--- Everything a finish has to survive before it counts.
local function validate(run: RunState, timeMs: number, verdict: MovementAudit.Verdict): (boolean, string?)
	local definition = run.definition

	if run.nextCheckpoint <= definition.checkpointCount then
		return false, "checkpoint skipped"
	end

	if timeMs < definition.minPossibleMs then
		return false, "impossible time"
	end

	local segmentCount = definition.checkpointCount + 1
	local segmentFloor = (definition.minPossibleMs / segmentCount) * SEGMENT_FLOOR_FACTOR
	local previous = 0
	for _, split in run.splits do
		if (split - previous) < segmentFloor then
			return false, "segment skipped"
		end
		previous = split
	end
	if (timeMs - previous) < segmentFloor then
		return false, "segment skipped"
	end

	if not verdict.valid then
		return false, verdict.reason or "movement validation failed"
	end

	return true, nil
end

local function finishRun(player: Player, run: RunState)
	local timeMs = elapsedMsOf(run)
	runs[player] = nil

	local verdict = MovementAudit.Finish(player)
	local valid, reason = validate(run, timeMs, verdict)

	local result: RunResult = {
		stageId = run.stageId,
		timeMs = timeMs,
		splits = run.splits,
		valid = valid,
		reason = reason,
		peakSpeed = verdict.peakSpeed,
		softViolations = verdict.softViolations,
		hardViolations = verdict.hardViolations,
	}

	if not valid then
		warn(
			`[RunSession] rejected {player.Name} on {run.stageId}: {reason} `
				.. `(peak {math.floor(result.peakSpeed)} studs/s, {verdict.softViolations} soft, `
				.. `{verdict.hardViolations} hard)`
		)
		pushUpdate(player, {
			kind = "Finished",
			stageId = run.stageId,
			elapsedMs = timeMs,
			rejected = true,
			rejectReason = reason,
		})
	end

	-- RecordService listens here and decides what to persist. It re-reads
	-- `valid` rather than trusting the caller.
	RunSessionService.Finished:Fire(player, result)
end

local function handleTrigger(player: Player, part: BasePart)
	local info = triggerInfo[part]
	if not info then
		return
	end

	local run = runs[player]

	if info.kind == "Start" then
		-- startRun owns the re-entry grace; stamping it here would refresh the
		-- window before the check and make a restart impossible.
		startRun(player, info.stageId)
		return
	end

	if not run or run.stageId ~= info.stageId then
		return
	end

	if info.kind == "Checkpoint" then
		reachCheckpoint(player, run, info, part)
	elseif info.kind == "Finish" then
		finishRun(player, run)
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Scanning
-- ─────────────────────────────────────────────────────────────────────────────

local function scanTriggers(interval: number)
	if #triggerParts == 0 then
		return
	end

	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not root then
			continue
		end

		-- Widen the query by how far the player travelled since the last scan so
		-- a fast magnet launch cannot tunnel straight through a checkpoint.
		local travelled = root.AssemblyLinearVelocity.Magnitude * interval
		local radius = BASE_TRIGGER_RADIUS + travelled

		for _, part in workspace:GetPartBoundsInRadius(root.Position, radius, overlapParams) do
			handleTrigger(player, part)
		end
	end
end

local function syncTimers()
	for player, run in runs do
		pushUpdate(player, {
			kind = "Sync",
			stageId = run.stageId,
			startedAt = run.startedAtServer,
			elapsedMs = elapsedMsOf(run),
			checkpointIndex = run.nextCheckpoint - 1,
			checkpointTotal = run.definition.checkpointCount,
		})
	end
end

local function onCharacterAdded(player: Player, character: Model)
	local humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid?
	if not humanoid then
		return
	end

	humanoid.Died:Connect(function()
		abortRun(player, "died")
	end)

	-- Put the player back at their last checkpoint, and tell the audit this
	-- particular jump through space was ours.
	local checkpoint = checkpointCFrames[player]
	if checkpoint then
		local root = character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if root then
			character:PivotTo(checkpoint)
		end
	end
	MovementAudit.Forgive(player)
end

function RunSessionService.Start()
	MovementAudit.Start()

	local tagKinds: { [string]: "Start" | "Finish" | "Checkpoint" } = {
		[GameConfig.Tags.StageStart] = "Start",
		[GameConfig.Tags.StageFinish] = "Finish",
		[GameConfig.Tags.Checkpoint] = "Checkpoint",
	}

	for tag, kind in tagKinds do
		for _, instance in CollectionService:GetTagged(tag) do
			registerTrigger(instance, kind)
		end
		CollectionService:GetInstanceAddedSignal(tag):Connect(function(instance)
			registerTrigger(instance, kind)
		end)
		CollectionService:GetInstanceRemovedSignal(tag):Connect(unregisterTrigger)
	end

	for _, player in Players:GetPlayers() do
		if player.Character then
			task.spawn(onCharacterAdded, player, player.Character)
		end
		player.CharacterAdded:Connect(function(character)
			onCharacterAdded(player, character)
		end)
	end

	Players.PlayerAdded:Connect(function(player)
		player.CharacterAdded:Connect(function(character)
			onCharacterAdded(player, character)
		end)
	end)

	Players.PlayerRemoving:Connect(function(player)
		runs[player] = nil
		checkpointCFrames[player] = nil
		MovementAudit.Release(player)
	end)

	local triggerInterval = 1 / TRIGGER_RATE
	local auditInterval = 1 / GameConfig.AuditSampleRate
	local syncInterval = 1 / GameConfig.TimerSyncRate

	local triggerAccumulator, auditAccumulator, syncAccumulator = 0, 0, 0

	RunService.Heartbeat:Connect(function(deltaTime: number)
		triggerAccumulator += deltaTime
		auditAccumulator += deltaTime
		syncAccumulator += deltaTime

		if triggerAccumulator >= triggerInterval then
			scanTriggers(triggerAccumulator)
			triggerAccumulator = 0
		end

		if auditAccumulator >= auditInterval then
			auditAccumulator = 0
			for player in runs do
				MovementAudit.Sample(player)
			end
		end

		if syncAccumulator >= syncInterval then
			syncAccumulator = 0
			syncTimers()
		end
	end)
end

return RunSessionService
