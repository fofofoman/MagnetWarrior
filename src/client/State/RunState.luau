--!nonstrict
--[[
	RunState.luau

	The client's view of the run. It holds what the server last told it and
	interpolates the timer between syncs so the display ticks smoothly at 60fps
	while the authoritative value arrives at GameConfig.TimerSyncRate.

	The distinction matters: `Elapsed()` is a *rendering* estimate, and the
	number that ends up on a leaderboard never comes from here. When a sync
	arrives it overwrites the estimate outright rather than easing toward it —
	the server is right by definition.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)
local Signal = require(Shared.Util.Signal)
local Types = require(Shared.Types)

local RunState = {}

--- Every update the server sends, in the order it sent them. One signal rather
--- than a family of them: subscribers already branch on `update.kind`, and a
--- second "finished" signal only made ordering between the two ambiguous.
RunState.Changed = Signal.new() -- (update: Types.RunUpdate)

local active = false
local stageId: string? = nil
local startedAt = 0 -- server clock
local checkpointIndex = 0
local checkpointTotal = 0
local lastSyncElapsedMs = 0
local lastSyncAt = 0

function RunState.IsActive(): boolean
	return active
end

function RunState.StageId(): string?
	return stageId
end

function RunState.Checkpoints(): (number, number)
	return checkpointIndex, checkpointTotal
end

--- Estimated elapsed milliseconds, for display only.
function RunState.Elapsed(): number
	if not active then
		return lastSyncElapsedMs
	end
	if startedAt > 0 then
		return math.max(0, math.floor((workspace:GetServerTimeNow() - startedAt) * 1000))
	end
	return lastSyncElapsedMs + math.floor((os.clock() - lastSyncAt) * 1000)
end

local function onUpdate(update: Types.RunUpdate)
	if typeof(update) ~= "table" then
		return
	end

	if update.kind == "Started" then
		active = true
		stageId = update.stageId
		startedAt = update.startedAt or workspace:GetServerTimeNow()
		checkpointIndex = 0
		checkpointTotal = update.checkpointTotal or 0
		lastSyncElapsedMs = 0
		lastSyncAt = os.clock()
	elseif update.kind == "Sync" then
		if update.startedAt then
			startedAt = update.startedAt
		end
		checkpointIndex = update.checkpointIndex or checkpointIndex
		checkpointTotal = update.checkpointTotal or checkpointTotal
		lastSyncElapsedMs = update.elapsedMs or lastSyncElapsedMs
		lastSyncAt = os.clock()
	elseif update.kind == "Checkpoint" then
		checkpointIndex = update.checkpointIndex or checkpointIndex
		checkpointTotal = update.checkpointTotal or checkpointTotal
		lastSyncElapsedMs = update.elapsedMs or lastSyncElapsedMs
		lastSyncAt = os.clock()
	elseif update.kind == "Finished" or update.kind == "Aborted" then
		active = false
		lastSyncElapsedMs = update.elapsedMs or lastSyncElapsedMs
		lastSyncAt = os.clock()
	end

	RunState.Changed:Fire(update)
end

function RunState.Start()
	Net.RunUpdate.OnClientEvent:Connect(onUpdate)
end

return RunState
