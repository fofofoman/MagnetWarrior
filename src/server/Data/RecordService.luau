--!nonstrict
--[[
	RecordService.luau

	Turns a validated run into a stored record, a medal and a leaderboard entry.

	It listens to RunSessionService.Finished and re-checks `result.valid` itself
	rather than assuming the caller filtered. That is the last gate before a time
	becomes public, so it does not delegate the decision.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Net = require(Shared.Net)
local RateLimiter = require(Shared.Util.RateLimiter)
local StageConfig = require(Shared.Config.StageConfig)
local Types = require(Shared.Types)

local DataService = require(script.Parent.DataService)
local LeaderboardService = require(script.Parent.LeaderboardService)
local RunSessionService = require(script.Parent.Parent.Run.RunSessionService)

local RecordService = {}

--- Leaderboard reads hit DataStores, so they get a much tighter limit than the
--- cheap local reads.
local recordsLimiter = RateLimiter.new(2, 4)
local boardLimiter = RateLimiter.new(0.5, 3)

local function onRunStarted(player: Player, stageId: string)
	local profile = DataService.Get(player)
	if not profile then
		return
	end

	local record = profile.records[stageId]
	if record then
		record.attempts += 1
	else
		profile.records[stageId] = {
			bestTimeMs = 0, -- 0 means "no completion yet"; see isCompleted()
			medal = "None",
			achievedAt = 0,
			completions = 0,
			attempts = 1,
		}
	end

	profile.stats.totalRuns += 1
end

local function isCompleted(record: Types.StageRecord?): boolean
	return record ~= nil and record.completions > 0 and record.bestTimeMs > 0
end

local function onRunFinished(player: Player, result: any)
	if not result.valid then
		return -- RunSessionService already told the client why
	end

	local profile = DataService.Get(player)
	if not profile then
		warn(`[RecordService] {player.Name} finished {result.stageId} with no loaded profile`)
		return
	end

	local stageId = result.stageId
	local timeMs = result.timeMs
	local runMedal = StageConfig.MedalFor(stageId, timeMs)

	local record = profile.records[stageId]
	local previousBest: number? = if isCompleted(record) then record.bestTimeMs else nil
	local isPersonalBest = previousBest == nil or timeMs < previousBest

	if not record then
		record = {
			bestTimeMs = timeMs,
			medal = runMedal,
			achievedAt = os.time(),
			completions = 0,
			attempts = 1,
		}
		profile.records[stageId] = record
	end

	record.completions += 1
	profile.stats.totalCompletions += 1

	if isPersonalBest then
		record.bestTimeMs = timeMs
		record.achievedAt = os.time()
	end

	-- The stored medal is the best ever earned, which may predate this run.
	if StageConfig.MedalRank(runMedal) > StageConfig.MedalRank(record.medal) then
		record.medal = runMedal
	end

	if isPersonalBest then
		LeaderboardService.InvalidatePlayer(player)
		task.spawn(function()
			LeaderboardService.Submit(player.UserId, stageId, timeMs)
		end)
		-- Persist promptly: a personal best lost to a server crash is the one
		-- kind of data loss players genuinely resent.
		task.spawn(function()
			DataService.Save(player, false)
		end)
	end

	local update: Types.RunUpdate = {
		kind = "Finished",
		stageId = stageId,
		elapsedMs = timeMs,
		medal = runMedal,
		isPersonalBest = isPersonalBest,
		previousBestMs = previousBest,
		checkpointIndex = #result.splits,
		checkpointTotal = #result.splits,
	}
	Net.RunUpdate:FireClient(player, update)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Remote reads
-- ─────────────────────────────────────────────────────────────────────────────

local function getRecords(player: Player): { [string]: Types.StageRecord }
	if not recordsLimiter:Consume(player) then
		return {}
	end

	local profile = DataService.Get(player)
	if not profile then
		return {}
	end

	-- Only send stages the player has actually completed; an attempts-only row
	-- would render as a bogus 0.000 personal best.
	local out: { [string]: Types.StageRecord } = {}
	for stageId, record in profile.records do
		if isCompleted(record) then
			out[stageId] = record
		end
	end
	return out
end

local function getLeaderboard(player: Player, stageId: any, scope: any): Types.LeaderboardPayload?
	if typeof(stageId) ~= "string" or not StageConfig.Get(stageId) then
		return nil
	end
	if scope ~= "Personal" and scope ~= "Friends" and scope ~= "Global" then
		return nil
	end
	if not boardLimiter:Consume(player) then
		return { stageId = stageId, scope = scope, entries = {}, unavailableReason = "잠시 후 다시 시도해 주세요" }
	end

	if scope == "Personal" then
		local profile = DataService.Get(player)
		local record = profile and profile.records[stageId]
		local entries: { Types.LeaderboardEntry } = {}
		if isCompleted(record) then
			table.insert(entries, {
				userId = player.UserId,
				displayName = player.DisplayName,
				timeMs = record.bestTimeMs,
				medal = record.medal,
				rank = 1,
			})
		end
		return { stageId = stageId, scope = "Personal", entries = entries }
	elseif scope == "Friends" then
		return LeaderboardService.GetFriendBoard(player, stageId)
	end

	return LeaderboardService.GetGlobalBoard(stageId)
end

function RecordService.Start()
	RunSessionService.Started:Connect(onRunStarted)
	RunSessionService.Finished:Connect(onRunFinished)

	Net.GetRecords.OnServerInvoke = function(player: Player)
		return getRecords(player)
	end

	Net.GetLeaderboard.OnServerInvoke = function(player: Player, stageId: any, scope: any)
		return getLeaderboard(player, stageId, scope)
	end

	Players.PlayerRemoving:Connect(function(player)
		recordsLimiter:Release(player)
		boardLimiter:Release(player)
		LeaderboardService.InvalidatePlayer(player)
	end)
end

return RecordService
