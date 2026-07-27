--!nonstrict
--[[
	GhostRecorder.luau

	Records where a player was, ten times a second, for the length of a run.

	Storage format is a flat array of integers rather than an array of CFrames or
	tables, and that choice is the whole reason this is viable. A ghost is
	written to a DataStore, which JSON-encodes whatever it is given:

	  { {x=12.3, y=4.5, z=6.7, r=90}, ... }   ~40 bytes per sample
	  { 123, 45, 67, 90, ... }                 ~14 bytes per sample

	At 10 Hz a six-minute run is 3600 samples. Flat integers keep that around
	50 KB, comfortably inside the 4 MB per-key limit with room for the longest
	stage; the table-of-tables form would be three times larger and mostly
	punctuation.

	Positions are quantised to 0.1 studs (stored ×10) and rotation to whole
	degrees of yaw. A ghost is a translucent reference silhouette, not a replay
	you can frame-step, so that precision is far more than enough.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local RunSessionService = require(script.Parent.RunSessionService)

local GhostRecorder = {}

GhostRecorder.SampleRate = 10 -- Hz

--- 6 minutes. Past this the recorder simply stops appending: a run that long is
--- not a leaderboard contender, and an unbounded buffer is a memory leak with
--- extra steps.
local MAX_SAMPLES = 3600

local VALUES_PER_SAMPLE = 4

type RecordingState = {
	stageId: string,
	data: { number },
	samples: number,
	truncated: boolean,
}

local recordings: { [Player]: RecordingState } = {}
local accumulator = 0

function GhostRecorder.Begin(player: Player, stageId: string)
	recordings[player] = {
		stageId = stageId,
		data = {},
		samples = 0,
		truncated = false,
	}
end

function GhostRecorder.Discard(player: Player)
	recordings[player] = nil
end

--- Hands over the recorded buffer and stops recording. Returns nil if there is
--- nothing usable — too short to be worth storing, or the wrong stage.
function GhostRecorder.Take(player: Player, stageId: string): { number }?
	local state = recordings[player]
	recordings[player] = nil

	if not state or state.stageId ~= stageId then
		return nil
	end
	if state.samples < 4 then
		return nil
	end

	return state.data
end

local function sample()
	for player, state in recordings do
		-- Sampling is tied to the run being live rather than to a "stop" signal.
		-- When the run ends the buffer stays put for Take() to collect, but
		-- nothing more is appended — so whether the ghost is claimed before or
		-- after any other Finished handler runs does not matter.
		if RunSessionService.GetActiveStageId(player) ~= state.stageId then
			continue
		end

		if state.samples >= MAX_SAMPLES then
			if not state.truncated then
				state.truncated = true
				warn(`[GhostRecorder] {player.Name} exceeded {MAX_SAMPLES} samples; ghost truncated`)
			end
			continue
		end

		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not root then
			continue
		end

		local position = root.Position
		local _, yaw = root.CFrame:ToEulerAnglesYXZ()

		local index = state.samples * VALUES_PER_SAMPLE
		state.data[index + 1] = math.round(position.X * 10)
		state.data[index + 2] = math.round(position.Y * 10)
		state.data[index + 3] = math.round(position.Z * 10)
		state.data[index + 4] = math.round(math.deg(yaw))
		state.samples += 1
	end
end

function GhostRecorder.Start()
	local interval = 1 / GhostRecorder.SampleRate

	RunService.Heartbeat:Connect(function(deltaTime)
		accumulator += deltaTime
		if accumulator < interval then
			return
		end
		accumulator = 0
		sample()
	end)

	Players.PlayerRemoving:Connect(GhostRecorder.Discard)
end

return GhostRecorder
