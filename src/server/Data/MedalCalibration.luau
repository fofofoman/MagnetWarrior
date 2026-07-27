--!nonstrict
--[[
	MedalCalibration.luau

	Records how long real completions actually take, so medal thresholds can stop
	being an estimate.

	`tools/estimate_medals.py` derives thresholds from level geometry, which is
	the best that can be done before anyone has played. It is still a model: it
	guesses at how fast people move and how long they spend aiming. This closes
	that loop by measuring, and after a few hundred completions its answer beats
	any static analysis.

	Run this from the Studio command bar, or a live server console, once the game
	has players:

	    require(game.ServerScriptService.Server.Data.MedalCalibration).Report()
	    require(game.ServerScriptService.Server.Data.MedalCalibration).ProposeConfig()

	Only runs RecordService accepted are counted — the same validation the
	leaderboard uses — so a cheated time cannot drag the curve.

	**A histogram, not a list of times.** Storage has to be bounded, and several
	servers write to the same key. Buckets make the cross-server merge a matter
	of adding counts, which is exactly correct with no sampling subtleties; a
	reservoir would need weighted merging to avoid quietly over-representing
	whichever server flushed least. Buckets are sized relative to each stage's
	configured Gold, so the resolution lands where the decision is being made.
]]

local DataStoreService = game:GetService("DataStoreService")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local StageConfig = require(Shared.Config.StageConfig)
local TimeFormat = require(Shared.Util.TimeFormat)

local RunSessionService = require(script.Parent.Parent.Run.RunSessionService)

local MedalCalibration = {}

local STORE_NAME = "MedalCalibration_v1"
local FLUSH_INTERVAL = 180 -- seconds

--- Buckets span 0.4x to 3.0x the configured Gold, which covers everything from
--- a run that beats the threshold outright to one that limps home.
local BUCKETS = 40
local RANGE_LOW = 0.4
local RANGE_HIGH = 3.0

--- Which percentile of completions Gold should sit at. A fifth of finishers
--- earning gold makes it an achievement without making it folklore.
local GOLD_PERCENTILE = 0.20
local SILVER_RATIO = 1.35
local BRONZE_RATIO = 1.90

type Histogram = { total: number, under: number, over: number, bins: { number } }

local pending: { [string]: Histogram } = {}
local store: DataStore?

local function getStore(): DataStore?
	if store then
		return store
	end
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(STORE_NAME)
	end)
	if not ok then
		return nil
	end
	store = result
	return store
end

local function newHistogram(): Histogram
	local bins = table.create(BUCKETS, 0)
	return { total = 0, under = 0, over = 0, bins = bins }
end

--- Time in milliseconds at the top edge of a bucket.
local function bucketEdge(gold: number, index: number): number
	local span = (RANGE_HIGH - RANGE_LOW) / BUCKETS
	return gold * (RANGE_LOW + span * index)
end

local function record(histogram: Histogram, gold: number, timeMs: number)
	histogram.total += 1

	if timeMs < gold * RANGE_LOW then
		histogram.under += 1
		return
	end
	if timeMs >= gold * RANGE_HIGH then
		histogram.over += 1
		return
	end

	local span = (RANGE_HIGH - RANGE_LOW) / BUCKETS
	local index = math.clamp(math.floor((timeMs / gold - RANGE_LOW) / span) + 1, 1, BUCKETS)
	histogram.bins[index] += 1
end

local function onFinished(_player: Player, result: any)
	if not result.valid then
		return
	end

	local definition = StageConfig.Get(result.stageId)
	if not definition then
		return
	end

	local histogram = pending[result.stageId]
	if not histogram then
		histogram = newHistogram()
		pending[result.stageId] = histogram
	end
	record(histogram, definition.medals.Gold, math.floor(result.timeMs))
end

--- Merges this server's counts into the shared store. Adding bins is
--- commutative, so concurrent servers cannot corrupt each other's data.
local function flush()
	local dataStore = getStore()
	if not dataStore then
		return
	end

	for stageId, histogram in pending do
		if histogram.total == 0 then
			continue
		end
		pending[stageId] = nil

		local ok, err = pcall(function()
			dataStore:UpdateAsync(stageId, function(stored: Histogram?)
				local merged = stored
				if typeof(merged) ~= "table" or typeof(merged.bins) ~= "table" or #merged.bins ~= BUCKETS then
					merged = newHistogram()
				end

				merged.total += histogram.total
				merged.under += histogram.under
				merged.over += histogram.over
				for index = 1, BUCKETS do
					merged.bins[index] += histogram.bins[index]
				end
				return merged
			end)
		end)

		if not ok then
			warn(`[MedalCalibration] flush failed for {stageId}: {err}`)
			-- Put it back rather than losing the counts.
			pending[stageId] = histogram
		end
	end
end

--- Time below which `fraction` of completions fall.
local function percentile(histogram: Histogram, gold: number, fraction: number): number
	if histogram.total == 0 then
		return 0
	end

	local target = histogram.total * fraction
	local cumulative = histogram.under
	if cumulative >= target then
		return gold * RANGE_LOW
	end

	for index = 1, BUCKETS do
		cumulative += histogram.bins[index]
		if cumulative >= target then
			return bucketEdge(gold, index)
		end
	end

	return gold * RANGE_HIGH
end

local function load(stageId: string): Histogram?
	local dataStore = getStore()
	if not dataStore then
		return nil
	end
	local ok, stored = pcall(function()
		return dataStore:GetAsync(stageId)
	end)
	if not ok or typeof(stored) ~= "table" or typeof(stored.bins) ~= "table" then
		return nil
	end
	return stored
end

--- Prints what players actually achieve against what the config asks for.
function MedalCalibration.Report()
	flush()

	if not getStore() then
		warn("[MedalCalibration] no DataStore access — nothing to report")
		return
	end

	print("─── medal calibration ──────────────────────────────────────────────────")
	print(string.format("%-22s %7s %9s %9s %9s %11s %9s", "stage", "runs", "p20", "p50", "p80", "gold now", "gold →"))

	for _, definition in StageConfig.Ordered() do
		local histogram = load(definition.id)
		if not histogram or histogram.total == 0 then
			print(string.format("%-22s %7s", definition.displayName, "—"))
			continue
		end

		local gold = definition.medals.Gold
		print(
			string.format(
				"%-22s %7d %9s %9s %9s %11s %9s",
				definition.displayName,
				histogram.total,
				TimeFormat.Short(percentile(histogram, gold, 0.2)),
				TimeFormat.Short(percentile(histogram, gold, 0.5)),
				TimeFormat.Short(percentile(histogram, gold, 0.8)),
				TimeFormat.Short(gold),
				TimeFormat.Short(percentile(histogram, gold, GOLD_PERCENTILE))
			)
		)
	end

	print("────────────────────────────────────────────────────────────────────────")
	print(
		string.format(
			"gold = p%d of completions, silver = gold x %.2f, bronze = gold x %.2f",
			GOLD_PERCENTILE * 100,
			SILVER_RATIO,
			BRONZE_RATIO
		)
	)
	print("a stage with under ~100 runs is not worth retuning from yet")
end

--- Ready-to-paste StageConfig lines, so applying the report is a copy rather
--- than twelve pieces of mental arithmetic.
function MedalCalibration.ProposeConfig()
	flush()

	for _, definition in StageConfig.Ordered() do
		local histogram = load(definition.id)
		if not histogram or histogram.total < 100 then
			continue
		end

		local gold = math.floor(percentile(histogram, definition.medals.Gold, GOLD_PERCENTILE) / 1000 + 0.5)
		print(
			string.format(
				"-- %s (%d runs)\nmedals = { Gold = seconds(%d), Silver = seconds(%d), Bronze = seconds(%d) },",
				definition.id,
				histogram.total,
				gold,
				math.floor(gold * SILVER_RATIO + 0.5),
				math.floor(gold * BRONZE_RATIO + 0.5)
			)
		)
	end
end

function MedalCalibration.Start()
	RunSessionService.Finished:Connect(onFinished)

	task.spawn(function()
		while true do
			task.wait(FLUSH_INTERVAL)
			flush()
		end
	end)

	game:BindToClose(function()
		if not RunService:IsStudio() then
			flush()
		end
	end)
end

return MedalCalibration
