--!nonstrict
--[[
	GhostService.luau — 고스트 리플레이

	Stores two ghosts per stage and serves them to the client.

	  • **개인 고스트** — your own personal best. Free: it is your run.
	  • **1위 고스트** — the fastest run this game has recorded for the stage.
	    Gated behind the GhostReplayTicket developer product.

	The ticket is the only thing money buys here, and it buys *viewing* — the
	ghost is a translucent silhouette that runs alongside you. It cannot be
	collided with, it does not alter your run, and the time it was set at is
	already public on the leaderboard. Selling a look at a route you could have
	watched on a video is convenience, not power, which is why the product
	declares `impact = "None"`.

	A ghost is only ever written from a run RecordService has already accepted,
	so the same validation that protects the leaderboard protects this.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local GameConfig = require(Shared.Config.GameConfig)
local Net = require(Shared.Net)
local RateLimiter = require(Shared.Util.RateLimiter)
local StageConfig = require(Shared.Config.StageConfig)
local Types = require(Shared.Types)

local GhostRecorder = require(script.Parent.Parent.Run.GhostRecorder)
local RecordService = require(script.Parent.RecordService)
local RunSessionService = require(script.Parent.Parent.Run.RunSessionService)

local Entitlements = require(script.Parent.Parent.Monetization.Entitlements)

local GhostService = {}

local BEST_STORE_PREFIX = "StageGhost_v1_"
local PERSONAL_STORE = "PlayerGhost_v1"
local BEST_KEY = "best"
local BEST_CACHE_SECONDS = 120

local TICKET_KEY = "GhostReplayTicket"

--- Ghost reads hit DataStores, so they are limited harder than local queries.
local ghostLimiter = RateLimiter.new(0.5, 3)

type StoredGhost = {
	v: number,
	userId: number,
	name: string,
	timeMs: number,
	rate: number,
	data: { number },
}

local bestStores: { [string]: DataStore } = {}
local personalStore: DataStore?

type CacheEntry = { at: number, ghost: StoredGhost? }
local bestCache: { [string]: CacheEntry } = {}

--- Stages whose top ghost a player has already paid to see this session.
--- Re-opening the panel, or reloading after a death, must not charge twice —
--- the ticket buys access to the ghost, not a single network round trip.
local unlockedBest: { [Player]: { [string]: boolean } } = {}

local function getBestStore(stageId: string): DataStore?
	local cached = bestStores[stageId]
	if cached then
		return cached
	end
	local ok, store = pcall(function()
		return DataStoreService:GetDataStore(BEST_STORE_PREFIX .. stageId)
	end)
	if not ok then
		warn(`[GhostService] ghost store unavailable for {stageId}: {store}`)
		return nil
	end
	bestStores[stageId] = store
	return store
end

local function getPersonalStore(): DataStore?
	if personalStore then
		return personalStore
	end
	local ok, store = pcall(function()
		return DataStoreService:GetDataStore(PERSONAL_STORE)
	end)
	if not ok then
		warn(`[GhostService] personal ghost store unavailable: {store}`)
		return nil
	end
	personalStore = store
	return personalStore
end

local function personalKey(userId: number, stageId: string): string
	return `{userId}_{stageId}`
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Writing
-- ─────────────────────────────────────────────────────────────────────────────

local function buildGhost(player: Player, timeMs: number, data: { number }): StoredGhost
	return {
		v = 1,
		userId = player.UserId,
		name = player.DisplayName,
		timeMs = math.floor(timeMs),
		rate = GhostRecorder.SampleRate,
		data = data,
	}
end

--- Called when RecordService accepts a personal best. Writes the player's own
--- ghost unconditionally, and the stage-wide best only if it is actually faster.
local function onPersonalBest(player: Player, stageId: string, timeMs: number)
	local data = GhostRecorder.Take(player, stageId)
	if not data then
		return
	end

	local ghost = buildGhost(player, timeMs, data)

	local personal = getPersonalStore()
	if personal then
		local ok, err = pcall(function()
			personal:SetAsync(personalKey(player.UserId, stageId), ghost)
		end)
		if not ok then
			warn(`[GhostService] failed to store personal ghost for {player.Name}: {err}`)
		end
	end

	local best = getBestStore(stageId)
	if not best then
		return
	end

	local ok, err = pcall(function()
		best:UpdateAsync(BEST_KEY, function(existing: StoredGhost?)
			if existing and existing.timeMs <= ghost.timeMs then
				return nil -- someone is still faster; abort the write
			end
			return ghost
		end)
	end)

	if not ok then
		warn(`[GhostService] failed to store stage ghost for {stageId}: {err}`)
		return
	end

	bestCache[stageId] = nil
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Reading
-- ─────────────────────────────────────────────────────────────────────────────

local function loadBest(stageId: string): StoredGhost?
	local cached = bestCache[stageId]
	if cached and (os.clock() - cached.at) < BEST_CACHE_SECONDS then
		return cached.ghost
	end

	local store = getBestStore(stageId)
	if not store then
		return nil
	end

	local ok, ghost = pcall(function()
		return store:GetAsync(BEST_KEY)
	end)
	if not ok then
		warn(`[GhostService] failed to read stage ghost for {stageId}: {ghost}`)
		return nil
	end

	bestCache[stageId] = { at = os.clock(), ghost = ghost }
	return ghost
end

local function loadPersonal(userId: number, stageId: string): StoredGhost?
	local store = getPersonalStore()
	if not store then
		return nil
	end
	local ok, ghost = pcall(function()
		return store:GetAsync(personalKey(userId, stageId))
	end)
	if not ok then
		warn(`[GhostService] failed to read personal ghost: {ghost}`)
		return nil
	end
	return ghost
end

local function toPayload(stageId: string, scope: Types.GhostScope, ghost: StoredGhost): Types.GhostPayload
	return {
		stageId = stageId,
		scope = scope,
		userId = ghost.userId,
		displayName = ghost.name,
		timeMs = ghost.timeMs,
		sampleRate = ghost.rate,
		data = ghost.data,
	}
end

local function unavailable(stageId: string, scope: Types.GhostScope, reason: string): Types.GhostPayload
	return {
		stageId = stageId,
		scope = scope,
		userId = 0,
		displayName = "",
		timeMs = 0,
		sampleRate = GhostRecorder.SampleRate,
		data = {},
		unavailableReason = reason,
	}
end

local function handleRequest(player: Player, stageId: any, scope: any): Types.GhostPayload?
	if typeof(stageId) ~= "string" or not StageConfig.Get(stageId) then
		return nil
	end
	if scope ~= "Personal" and scope ~= "Best" then
		return nil
	end

	if not GameConfig.Features.GhostReplay then
		return unavailable(stageId, scope, "고스트 리플레이는 준비 중입니다")
	end

	if not ghostLimiter:Consume(player) then
		return unavailable(stageId, scope, "잠시 후 다시 시도해 주세요")
	end

	if scope == "Personal" then
		local ghost = loadPersonal(player.UserId, stageId)
		if not ghost then
			return unavailable(stageId, scope, "이 스테이지의 개인 기록 고스트가 없습니다")
		end
		return toPayload(stageId, scope, ghost)
	end

	-- Check the ghost exists *before* charging for it.
	local ghost = loadBest(stageId)
	if not ghost then
		return unavailable(stageId, scope, "아직 등록된 1위 고스트가 없습니다")
	end

	-- Your own run is never worth a ticket, and neither is one already paid for.
	local unlocked = unlockedBest[player]
	if ghost.userId ~= player.UserId and not (unlocked and unlocked[stageId]) then
		if not Entitlements.ConsumeOne(player, TICKET_KEY) then
			return unavailable(stageId, scope, "고스트 리플레이 열람권이 필요합니다")
		end
		if not unlocked then
			unlocked = {}
			unlockedBest[player] = unlocked
		end
		unlocked[stageId] = true
	end

	return toPayload(stageId, scope, ghost)
end

function GhostService.Start()
	GhostRecorder.Start()

	RunSessionService.Started:Connect(function(player: Player, stageId: string)
		GhostRecorder.Begin(player, stageId)
	end)

	RunSessionService.Aborted:Connect(function(player: Player)
		GhostRecorder.Discard(player)
	end)

	-- The recorder stops appending on its own when the run ends, so this can
	-- collect the buffer whenever it fires. A finished run that was not a
	-- personal best simply leaves its buffer to be overwritten by the next
	-- Begin — no sampling continues, so nothing grows.
	RecordService.PersonalBestSet:Connect(onPersonalBest)

	Net.GetGhost.OnServerInvoke = function(player: Player, stageId: any, scope: any)
		return handleRequest(player, stageId, scope)
	end

	Players.PlayerRemoving:Connect(function(player)
		ghostLimiter:Release(player)
		unlockedBest[player] = nil
	end)
end

return GhostService
