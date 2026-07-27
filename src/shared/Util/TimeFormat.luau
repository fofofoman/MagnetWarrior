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
---
--- Truncated to hundredths in integer arithmetic rather than handed to "%.2f".
--- Formatting a float rounds it, and a time of 1:59.999 rounds its seconds
--- component to 60.00 — printing "1:60.00" instead of "2:00.00". Every minute
--- boundary has a 5ms window where that happens, and it shows up on the
--- leaderboard, the medal thresholds and the ghost label.
function TimeFormat.Short(timeMs: number): string
	if timeMs < 0 then
		return "--:--"
	end

	local hundredths = math.floor(timeMs / 10)
	local minutes = math.floor(hundredths / 6000)
	local remainder = hundredths % 6000

	if minutes > 0 then
		return string.format("%d:%02d.%02d", minutes, remainder // 100, remainder % 100)
	end
	return string.format("%d.%02d", remainder // 100, remainder % 100)
end

--- Signed delta against a personal best: -1.204 / +0.337
function TimeFormat.Delta(deltaMs: number): string
	local sign = if deltaMs < 0 then "-" else "+"
	return sign .. TimeFormat.Clock(math.abs(deltaMs))
end

return TimeFormat
