--!nonstrict
--[[
	LeaderboardService.luau

	One OrderedDataStore per stage, keyed by user id, valued by finish time in
	milliseconds. Ascending order therefore puts the fastest run first.

	That single choice is what makes the phased rollout work. Phase 1 needs
	personal bests and friend rankings, which are point reads of specific keys.
	Phase 2 needs a global top 10, which is `GetSortedAsync(true, 10)` over the
	*same* store — no migration, no backfill, no second write path. So the write
	path is live from day one even though `GameConfig.Features.GlobalLeaderboard`
	is off; records accumulate now and the global board simply switches on later
	with real data already in it.

	Everything is written through UpdateAsync with a compare, so a slower time
	can never overwrite a faster one, even from a stale server.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local GameConfig = require(Shared.Config.GameConfig)
local StageConfig = require(Shared.Config.StageConfig)
local Types = require(Shared.Types)

local LeaderboardService = {}

local STORE_PREFIX = "StageTimes_v1_"
local MAX_FRIENDS_SCANNED = 60

--- Hard ceiling on how long a friend board may take to assemble.
---
--- Each friend costs one GetAsync, and awaitBudget will sit on a nearly-spent
--- request budget for up to eight seconds per call. Sixty friends on a busy
--- server is therefore minutes of blocking, during which the player's panel is
--- stuck on "불러오는 중…" with no way to cancel. A partial board that arrives is
--- worth far more than a complete one that never does, so the scan stops here and
--- ranks whoever it managed to read.
local FRIEND_SCAN_DEADLINE = 6 -- seconds

local FRIEND_CACHE_SECONDS = 60
local GLOBAL_CACHE_SECONDS = 45
local GLOBAL_TOP_COUNT = 10

local stores: { [string]: OrderedDataStore } = {}
local nameCache: { [number]: string } = {}

type CacheEntry = { at: number, payload: Types.LeaderboardPayload }
local friendCache: { [string]: CacheEntry } = {}
local globalCache: { [string]: CacheEntry } = {}

local function getStore(stageId: string): OrderedDataStore?
	local cached = stores[stageId]
	if cached then
		return cached
	end

	local ok, result = pcall(function()
		return DataStoreService:GetOrderedDataStore(STORE_PREFIX .. stageId)
	end)
	if not ok then
		warn(`[Leaderboard] ordered store unavailable for {stageId}: {result}`)
		return nil
	end

	stores[stageId] = result
	return result
end

--- Blocks briefly when the request budget is nearly spent, so a busy server
--- degrades into slower leaderboards instead of throttled errors.
local function awaitBudget(requestType: Enum.DataStoreRequestType, minimum: number?)
	local needed = minimum or 1
	local deadline = os.clock() + 8
	while os.clock() < deadline do
		local ok, budget = pcall(function()
			return DataStoreService:GetRequestBudgetForRequestType(requestType)
		end)
		if not ok or budget >= needed then
			return
		end
		task.wait(0.5)
	end
end

local function resolveName(userId: number): string
	local cached = nameCache[userId]
	if cached then
		return cached
	end

	local player = Players:GetPlayerByUserId(userId)
	if player then
		nameCache[userId] = player.DisplayName
		return player.DisplayName
	end

	local ok, name = pcall(function()
		return Players:GetNameFromUserIdAsync(userId)
	end)
	local resolved = if ok and name then name else `User {userId}`
	nameCache[userId] = resolved
	return resolved
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Writes
-- ─────────────────────────────────────────────────────────────────────────────

--- Records a verified time. Never call this with an unvalidated result — the
--- ordered store is the ranking, and anything written here is public.
function LeaderboardService.Submit(userId: number, stageId: string, timeMs: number): boolean
	local dataStore = getStore(stageId)
	if not dataStore then
		return false
	end

	local rounded = math.floor(timeMs)
	if rounded <= 0 then
		return false
	end

	awaitBudget(Enum.DataStoreRequestType.SetIncrementAsync)

	local ok, err = pcall(function()
		dataStore:UpdateAsync(tostring(userId), function(existing: number?)
			if existing and existing <= rounded then
				return nil -- already have a better time; abort the write
			end
			return rounded
		end)
	end)

	if not ok then
		warn(`[Leaderboard] submit failed for {userId} on {stageId}: {err}`)
		return false
	end

	-- A new entry can change the top 10, so drop the cached page.
	globalCache[stageId] = nil
	return true
end

--- Best recorded time for one player on one stage, or nil.
function LeaderboardService.GetTime(userId: number, stageId: string): number?
	local dataStore = getStore(stageId)
	if not dataStore then
		return nil
	end

	awaitBudget(Enum.DataStoreRequestType.GetAsync)

	local ok, value = pcall(function()
		return dataStore:GetAsync(tostring(userId))
	end)
	if not ok then
		warn(`[Leaderboard] read failed for {userId} on {stageId}: {value}`)
		return nil
	end

	return if typeof(value) == "number" then value else nil
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Reads
-- ─────────────────────────────────────────────────────────────────────────────

local function buildEntries(rows: { { userId: number, timeMs: number } }, stageId: string): { Types.LeaderboardEntry }
	table.sort(rows, function(a, b)
		return a.timeMs < b.timeMs
	end)

	local entries: { Types.LeaderboardEntry } = {}
	for index, row in rows do
		table.insert(entries, {
			userId = row.userId,
			displayName = resolveName(row.userId),
			timeMs = row.timeMs,
			medal = StageConfig.MedalFor(stageId, row.timeMs),
			rank = index,
		})
	end
	return entries
end

--- Friend ranking. Reads the same ordered store one key at a time, capped at
--- MAX_FRIENDS_SCANNED and cached, because a player with 400 friends would
--- otherwise cost 400 requests per panel open.
function LeaderboardService.GetFriendBoard(player: Player, stageId: string): Types.LeaderboardPayload
	if not GameConfig.Features.FriendLeaderboard then
		return { stageId = stageId, scope = "Friends", entries = {}, unavailableReason = "친구 랭킹 준비 중" }
	end

	local cacheKey = `{player.UserId}:{stageId}`
	local cached = friendCache[cacheKey]
	if cached and (os.clock() - cached.at) < FRIEND_CACHE_SECONDS then
		return cached.payload
	end

	local userIds: { number } = { player.UserId }

	local ok, pages = pcall(function()
		return Players:GetFriendsAsync(player.UserId)
	end)

	if ok and pages then
		local scanned = 0
		while scanned < MAX_FRIENDS_SCANNED do
			local pageOk, page = pcall(function()
				return pages:GetCurrentPage()
			end)
			if not pageOk or not page then
				break
			end

			for _, friend in page do
				scanned += 1
				table.insert(userIds, friend.Id)
				if friend.DisplayName then
					nameCache[friend.Id] = friend.DisplayName
				end
				if scanned >= MAX_FRIENDS_SCANNED then
					break
				end
			end

			if pages.IsFinished or scanned >= MAX_FRIENDS_SCANNED then
				break
			end
			local advanceOk = pcall(function()
				pages:AdvanceToNextPageAsync()
			end)
			if not advanceOk then
				break
			end
		end
	end

	local rows: { { userId: number, timeMs: number } } = {}
	local deadline = os.clock() + FRIEND_SCAN_DEADLINE
	local truncated = false

	for index, userId in userIds do
		-- The player's own row is first and is always read; past that, stop as
		-- soon as the budget for this request is spent.
		if index > 1 and os.clock() >= deadline then
			truncated = true
			break
		end
		local timeMs = LeaderboardService.GetTime(userId, stageId)
		if timeMs then
			table.insert(rows, { userId = userId, timeMs = timeMs })
		end
	end

	local payload: Types.LeaderboardPayload = {
		stageId = stageId,
		scope = "Friends",
		entries = buildEntries(rows, stageId),
	}

	-- A truncated board is not cached: caching it would freeze a partial answer in
	-- place for a minute, and the next open should get another try at the rest.
	if not truncated then
		friendCache[cacheKey] = { at = os.clock(), payload = payload }
	end
	return payload
end

--- Global top 10 — phase 2. The data is already there; only this read is gated.
function LeaderboardService.GetGlobalBoard(stageId: string): Types.LeaderboardPayload
	if not GameConfig.Features.GlobalLeaderboard then
		return {
			stageId = stageId,
			scope = "Global",
			entries = {},
			unavailableReason = "글로벌 랭킹은 다음 업데이트에 공개됩니다",
		}
	end

	local cached = globalCache[stageId]
	if cached and (os.clock() - cached.at) < GLOBAL_CACHE_SECONDS then
		return cached.payload
	end

	local dataStore = getStore(stageId)
	if not dataStore then
		return { stageId = stageId, scope = "Global", entries = {}, unavailableReason = "랭킹 서버에 연결할 수 없습니다" }
	end

	awaitBudget(Enum.DataStoreRequestType.GetSortedAsync)

	local rows: { { userId: number, timeMs: number } } = {}
	local ok, err = pcall(function()
		-- ascending = true: lowest time first.
		local pages = dataStore:GetSortedAsync(true, GLOBAL_TOP_COUNT)
		for _, row in pages:GetCurrentPage() do
			local userId = tonumber(row.key)
			if userId then
				table.insert(rows, { userId = userId, timeMs = row.value })
			end
		end
	end)

	if not ok then
		warn(`[Leaderboard] global read failed for {stageId}: {err}`)
		return { stageId = stageId, scope = "Global", entries = {}, unavailableReason = "랭킹을 불러오지 못했습니다" }
	end

	local payload: Types.LeaderboardPayload = {
		stageId = stageId,
		scope = "Global",
		entries = buildEntries(rows, stageId),
	}

	globalCache[stageId] = { at = os.clock(), payload = payload }
	return payload
end

function LeaderboardService.InvalidatePlayer(player: Player)
	for key in friendCache do
		if string.sub(key, 1, #tostring(player.UserId) + 1) == `{player.UserId}:` then
			friendCache[key] = nil
		end
	end
end

return LeaderboardService
