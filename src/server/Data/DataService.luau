--!nonstrict
--[[
	DataService.luau

	Player profiles: personal records, cosmetic choices, entitlements, receipt
	history. Three things here are load-bearing and worth reading before
	changing anything:

	1. **The schema is versioned.** `SCHEMA_VERSION` plus the `migrations` table
	   means adding a field later — a season pass ledger, ghost replay handles,
	   a global-leaderboard opt-in — is an append, not a wipe. The 2nd-phase
	   global ranking is already accounted for this way.

	2. **Saves go through UpdateAsync.** Two servers can hold the same player
	   briefly during a teleport; last-write-wins would lose a personal best.
	   The merge keeps the better time.

	3. **Studio without API access still works.** Every DataStore call is
	   wrapped, and a failure falls back to an in-memory profile so the game is
	   playable in Studio before anything is published.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local GameConfig = require(Shared.Config.GameConfig)
local Signal = require(Shared.Util.Signal)
local Types = require(Shared.Types)

local DataService = {}

local STORE_NAME = "PlayerProfile_v1"
local SCHEMA_VERSION = 1
local LOAD_RETRIES = 4
local AUTOSAVE_INTERVAL = 90 -- seconds
local LOCK_STALE_AFTER = 120 -- seconds before another server's lock is ignored

export type Profile = {
	schemaVersion: number,
	records: { [string]: Types.StageRecord },
	cosmetics: { [string]: string },
	--- Non-gamepass grants (developer products, and later season pass rewards).
	--- Gamepass ownership is never cached here — it is queried live so refunds
	--- and gifts take effect immediately.
	entitlements: { [string]: boolean },
	consumables: { [string]: number },
	checkpoint: { stageId: string, components: { number } }?,
	--- Receipt ids we have already granted, so a retried receipt cannot double
	--- grant. Roblox retries ProcessReceipt until it returns Granted.
	purchaseHistory: { [string]: boolean },
	stats: { totalRuns: number, totalCompletions: number },
	createdAt: number,
	lastSeen: number,
	lock: { jobId: string, at: number }?,
}

DataService.ProfileLoaded = Signal.new() -- (player, profile)

local store: DataStore?
local profiles: { [Player]: Profile } = {}
local loading: { [Player]: boolean } = {}
local usingFallback = false

local function log(message: string)
	if GameConfig.Debug.DataStore then
		print(`[DataService] {message}`)
	end
end

local function defaultProfile(): Profile
	return {
		schemaVersion = SCHEMA_VERSION,
		records = {},
		cosmetics = {
			beamColor = "Default",
			trail = "None",
			pose = "None",
		},
		entitlements = {},
		consumables = {},
		checkpoint = nil,
		purchaseHistory = {},
		stats = { totalRuns = 0, totalCompletions = 0 },
		createdAt = os.time(),
		lastSeen = os.time(),
		lock = nil,
	}
end

--- Version N -> N+1. Append only; never renumber an existing entry.
local migrations: { [number]: (Profile) -> Profile } = {
	-- [1] = function(profile)
	-- 	profile.seasonPass = { tier = 0, claimed = {} }
	-- 	profile.schemaVersion = 2
	-- 	return profile
	-- end,
}

local function migrate(profile: Profile): Profile
	local version = profile.schemaVersion or 0
	while version < SCHEMA_VERSION do
		local step = migrations[version]
		if not step then
			-- No path forward: keep the data, stamp it current rather than
			-- destroying a player's records over a missing migration.
			warn(`[DataService] no migration from schema {version}; stamping as {SCHEMA_VERSION}`)
			profile.schemaVersion = SCHEMA_VERSION
			break
		end
		profile = step(profile)
		version = profile.schemaVersion
	end
	return profile
end

--- Fills in fields added to defaultProfile() without a formal migration.
local function reconcile(profile: Profile): Profile
	local template = defaultProfile()
	for key, value in template do
		if profile[key] == nil then
			profile[key] = value
		end
	end
	if typeof(profile.records) ~= "table" then
		profile.records = {}
	end
	if typeof(profile.purchaseHistory) ~= "table" then
		profile.purchaseHistory = {}
	end
	return profile
end

local function keyFor(userId: number): string
	return `player_{userId}`
end

local function getStore(): DataStore?
	if store then
		return store
	end
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(STORE_NAME)
	end)
	if ok then
		store = result
		return store
	end
	warn(`[DataService] DataStore unavailable ({result}); running on in-memory profiles`)
	usingFallback = true
	return nil
end

--- True when profiles are not being persisted (Studio without API access).
function DataService.IsUsingFallback(): boolean
	return usingFallback
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Load / save
-- ─────────────────────────────────────────────────────────────────────────────

local function loadProfile(player: Player): Profile
	local dataStore = getStore()
	if not dataStore then
		return defaultProfile()
	end

	local key = keyFor(player.UserId)

	for attempt = 1, LOAD_RETRIES do
		local ok, result = pcall(function()
			return dataStore:UpdateAsync(key, function(saved: Profile?)
				local profile = saved or defaultProfile()

				local lock = profile.lock
				if lock and lock.jobId ~= game.JobId and (os.time() - lock.at) < LOCK_STALE_AFTER then
					-- Another server still holds this profile. Abort the write
					-- and let the retry loop wait it out.
					return nil
				end

				profile = reconcile(migrate(profile))
				profile.lock = { jobId = game.JobId, at = os.time() }
				profile.lastSeen = os.time()
				return profile
			end)
		end)

		if ok and result then
			log(`loaded {player.Name} on attempt {attempt}`)
			return result
		end

		if not ok then
			warn(`[DataService] load failed for {player.Name}: {result}`)
		end

		task.wait(2 ^ attempt)
	end

	-- Session lock never cleared, or the store is down. Give the player a
	-- working (unsaved) profile rather than blocking them from playing, and
	-- mark it so the save path knows not to overwrite good data with it.
	warn(`[DataService] giving {player.Name} an unsaved profile — could not acquire the session lock`)
	local profile = defaultProfile()
	profile.lock = nil
	profile.schemaVersion = -1 -- poison marker: never written back
	return profile
end

--- Merges the in-memory profile into whatever is currently stored. The merge
--- exists so a stale second writer cannot roll back a better time.
local function mergeInto(stored: Profile?, incoming: Profile, releaseLock: boolean): Profile
	local base = stored and reconcile(migrate(stored)) or defaultProfile()

	for stageId, incomingRecord in incoming.records do
		local existing = base.records[stageId]

		-- A record with bestTimeMs == 0 is an attempts-only row created when a
		-- run starts; it is *not* a time of zero. Treating it as one would let a
		-- fresh attempt wipe out a real personal best on merge.
		local incomingHasTime = incomingRecord.bestTimeMs > 0
		local existingHasTime = existing ~= nil and existing.bestTimeMs > 0

		if not existing then
			base.records[stageId] = incomingRecord
		elseif incomingHasTime and (not existingHasTime or incomingRecord.bestTimeMs < existing.bestTimeMs) then
			-- Faster: take it, but carry the counters and best medal forward.
			incomingRecord.completions = math.max(existing.completions, incomingRecord.completions)
			incomingRecord.attempts = math.max(existing.attempts, incomingRecord.attempts)
			base.records[stageId] = incomingRecord
		else
			existing.completions = math.max(existing.completions, incomingRecord.completions)
			existing.attempts = math.max(existing.attempts, incomingRecord.attempts)
		end
	end

	base.cosmetics = incoming.cosmetics
	base.checkpoint = incoming.checkpoint
	base.consumables = incoming.consumables

	for key, value in incoming.entitlements do
		base.entitlements[key] = value
	end
	for purchaseId in incoming.purchaseHistory do
		base.purchaseHistory[purchaseId] = true
	end

	base.stats.totalRuns = math.max(base.stats.totalRuns, incoming.stats.totalRuns)
	base.stats.totalCompletions = math.max(base.stats.totalCompletions, incoming.stats.totalCompletions)
	base.lastSeen = os.time()
	base.lock = if releaseLock then nil else { jobId = game.JobId, at = os.time() }

	return base
end

local function saveProfile(player: Player, releaseLock: boolean): boolean
	local profile = profiles[player]
	if not profile then
		return false
	end
	if profile.schemaVersion == -1 then
		return false -- poisoned placeholder; writing it would clobber real data
	end

	local dataStore = getStore()
	if not dataStore then
		return false
	end

	local ok, err = pcall(function()
		dataStore:UpdateAsync(keyFor(player.UserId), function(stored: Profile?)
			return mergeInto(stored, profile, releaseLock)
		end)
	end)

	if not ok then
		warn(`[DataService] save failed for {player.Name}: {err}`)
		return false
	end

	log(`saved {player.Name}{if releaseLock then " (released)" else ""}`)
	return true
end

DataService.Save = saveProfile

-- ─────────────────────────────────────────────────────────────────────────────
-- Access
-- ─────────────────────────────────────────────────────────────────────────────

function DataService.Get(player: Player): Profile?
	return profiles[player]
end

--- Yields until the profile is available, or the timeout expires.
function DataService.WaitFor(player: Player, timeout: number?): Profile?
	local deadline = os.clock() + (timeout or 15)
	while os.clock() < deadline do
		local profile = profiles[player]
		if profile then
			return profile
		end
		if not player.Parent then
			return nil
		end
		task.wait(0.1)
	end
	return profiles[player]
end

local function onPlayerAdded(player: Player)
	if loading[player] then
		return
	end
	loading[player] = true

	local profile = loadProfile(player)

	-- They may have left while we were waiting on the store.
	if not player.Parent then
		loading[player] = nil
		return
	end

	profiles[player] = profile
	loading[player] = nil
	DataService.ProfileLoaded:Fire(player, profile)
end

local function onPlayerRemoving(player: Player)
	saveProfile(player, true)
	profiles[player] = nil
	loading[player] = nil
end

function DataService.Start()
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end
	Players.PlayerAdded:Connect(function(player)
		task.spawn(onPlayerAdded, player)
	end)
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	task.spawn(function()
		while true do
			task.wait(AUTOSAVE_INTERVAL)
			for player in profiles do
				saveProfile(player, false)
			end
		end
	end)

	game:BindToClose(function()
		if RunService:IsStudio() then
			return
		end
		-- Save everyone in parallel; the shutdown budget is ~30s.
		local pending = 0
		for player in profiles do
			pending += 1
			task.spawn(function()
				saveProfile(player, true)
				pending -= 1
			end)
		end

		local deadline = os.clock() + 25
		while pending > 0 and os.clock() < deadline do
			task.wait(0.1)
		end
	end)
end

return DataService
