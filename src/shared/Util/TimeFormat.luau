--!strict
--[[
	TimeFormat.luau
	Run times are stored and transmitted as integer milliseconds everywhere —
	OrderedDataStore only accepts integers, and floats invite rounding
	disagreements between client and server. Formatting happens at the very edge,
	here.
]]

local TimeFormat = {}

--- 1:04.372 / 12.480
function TimeFormat.Clock(timeMs: number): string
	if timeMs < 0 then
		return "--:--.---"
	end

	local totalSeconds = timeMs / 1000
	local minutes = math.floor(totalSeconds / 60)
	local seconds = math.floor(totalSeconds % 60)
	local millis = math.floor(timeMs % 1000)

	if minutes > 0 then
		return string.format("%d:%02d.%03d", minutes, seconds, millis)
	end
	return string.format("%d.%03d", seconds, millis)
end

--- Compact form for leaderboard rows: 1:04.37
function TimeFormat.Short(timeMs: number): string
	if timeMs < 0 then
		return "--:--"
	end

	local totalSeconds = timeMs / 1000
	local minutes = math.floor(totalSeconds / 60)
	local seconds = totalSeconds % 60

	if minutes > 0 then
		return string.format("%d:%05.2f", minutes, seconds)
	end
	return string.format("%.2f", seconds)
end

--- Signed delta against a personal best: -1.204 / +0.337
function TimeFormat.Delta(deltaMs: number): string
	local sign = if deltaMs < 0 then "-" else "+"
	return sign .. TimeFormat.Clock(math.abs(deltaMs))
end

return TimeFormat
