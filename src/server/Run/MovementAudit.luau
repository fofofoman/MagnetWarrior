--!nonstrict
--[[
	MovementAudit.luau

	Character movement is simulated by the owning client — that is how Roblox
	works, and no amount of wishing changes it. What the server *can* do is watch
	where the character actually ends up and decide whether that path was
	physically reachable. This module does that, and its verdict is what decides
	whether a finish time is recorded or thrown away.

	Axes are judged separately, because they have genuinely different limits:

	  • horizontal — walking, or a magnet launch if one was earned recently
	  • upward     — jumping, or a magnet launch; unexplained rise is flight
	  • downward   — falling, which is fast and legal

	"Earned recently" is the key idea. MagnetService calls NoteBoost() every time
	it applies a legitimate force; for a short window afterwards the caps rise to
	MagnetConfig.MaxLegitimateSpeed. Speed with no preceding server-applied force
	has no explanation, and is counted against the run.

	One-off spikes are tolerated (lag, a rough physics step). Repeated ones, or a
	single displacement no force could produce, invalidate the run.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local GameConfig = require(Shared.Config.GameConfig)
local MagnetConfig = require(Shared.Config.MagnetConfig)

local MovementAudit = {}

--- Ordinary running, with headroom for slopes and the odd conveyor.
local NORMAL_HORIZONTAL_SPEED = 34 -- studs/s
--- Default JumpPower is 50; a little headroom on top.
local NORMAL_UP_SPEED = 62 -- studs/s
--- Falling is uncapped by the engine in practice; this is a sanity bound only.
local FALL_SPEED = 320 -- studs/s

--- Absolute per-sample displacement that no force in the game can produce.
--- At the 10 Hz sample rate this is ~550 studs/s.
local TELEPORT_DISTANCE = 55 -- studs

--- Additive slack per sample to absorb jitter and variable frame timing.
local SAMPLE_TOLERANCE = 4 -- studs

--- How long a server-applied force keeps the caps raised.
---
--- This has to outlast the *flight* a legal launch produces, not just the
--- instant it is applied. A chained push at MagnetConfig.ChainedSpeedCap off a
--- high ledge stays fast for the whole fall — around two seconds on the tallest
--- stage — and a window that expires mid-flight would flag the player for
--- movement the server itself granted. Raising the launch speeds means raising
--- this too.
local BOOST_WINDOW = 2.5 -- seconds

--- Soft violations tolerated before a run is thrown out.
local MAX_SOFT_VIOLATIONS = 6

export type Verdict = {
	valid: boolean,
	reason: string?,
	softViolations: number,
	hardViolations: number,
	peakSpeed: number,
}

type AuditState = {
	active: boolean,
	lastPosition: Vector3?,
	lastSampleAt: number,
	boostUntil: number,
	lastBoostReason: string?,
	softViolations: number,
	hardViolations: number,
	firstReason: string?,
	peakSpeed: number,
}

local states: { [Player]: AuditState } = {}

local function getState(player: Player): AuditState
	local state = states[player]
	if not state then
		state = {
			active = false,
			lastPosition = nil,
			lastSampleAt = 0,
			boostUntil = 0,
			lastBoostReason = nil,
			softViolations = 0,
			hardViolations = 0,
			firstReason = nil,
			peakSpeed = 0,
		}
		states[player] = state
	end
	return state
end

--- Called by MagnetService whenever it applies a legitimate force to a player.
function MovementAudit.NoteBoost(player: Player, reason: string)
	local state = getState(player)
	state.boostUntil = os.clock() + BOOST_WINDOW
	state.lastBoostReason = reason
end

--- Drops the previous sample without penalty. Used for server-initiated
--- position changes — respawns, checkpoint restores, stage teleports — which
--- would otherwise look exactly like a teleport hack.
function MovementAudit.Forgive(player: Player)
	local state = getState(player)
	state.lastPosition = nil
	state.lastSampleAt = 0
end

function MovementAudit.Begin(player: Player)
	local state = getState(player)
	state.active = true
	state.lastPosition = nil
	state.lastSampleAt = 0
	state.softViolations = 0
	state.hardViolations = 0
	state.firstReason = nil
	state.peakSpeed = 0
end

function MovementAudit.IsActive(player: Player): boolean
	local state = states[player]
	return state ~= nil and state.active
end

local function flag(state: AuditState, hard: boolean, reason: string)
	if hard then
		state.hardViolations += 1
	else
		state.softViolations += 1
	end
	if not state.firstReason then
		state.firstReason = reason
	end
	if GameConfig.Debug.MovementAudit then
		warn(`[MovementAudit] {if hard then "hard" else "soft"} flag: {reason}`)
	end
end

--- Samples one player. Called from the run loop at GameConfig.AuditSampleRate.
function MovementAudit.Sample(player: Player)
	local state = states[player]
	if not state or not state.active then
		return
	end

	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		state.lastPosition = nil
		return
	end

	local now = os.clock()
	local position = root.Position

	local lastPosition = state.lastPosition
	local lastSampleAt = state.lastSampleAt
	state.lastPosition = position
	state.lastSampleAt = now

	if not lastPosition then
		return -- first sample of the run, or just after a forgiven teleport
	end

	local deltaTime = now - lastSampleAt
	if deltaTime <= 0 then
		deltaTime = 1 / GameConfig.AuditSampleRate
	end
	-- A stalled server thread must not become free distance.
	deltaTime = math.min(deltaTime, 1)

	local delta = position - lastPosition
	local speed = delta.Magnitude / deltaTime
	state.peakSpeed = math.max(state.peakSpeed, speed)

	if delta.Magnitude >= TELEPORT_DISTANCE then
		flag(state, true, "teleport")
		return
	end

	local boosted = now <= state.boostUntil
	local horizontalCap = (if boosted then MagnetConfig.MaxLegitimateSpeed else NORMAL_HORIZONTAL_SPEED)
			* deltaTime
		+ SAMPLE_TOLERANCE
	local upCap = (if boosted then MagnetConfig.MaxLegitimateSpeed else NORMAL_UP_SPEED) * deltaTime
		+ SAMPLE_TOLERANCE
	local downCap = FALL_SPEED * deltaTime + SAMPLE_TOLERANCE

	local horizontal = Vector3.new(delta.X, 0, delta.Z).Magnitude
	if horizontal > horizontalCap then
		flag(state, false, "horizontal speed")
	end

	if delta.Y > upCap then
		flag(state, false, "unexplained ascent")
	elseif -delta.Y > downCap then
		flag(state, false, "descent speed")
	end
end

--- Ends the audit and reports. Called when a run finishes or is abandoned.
function MovementAudit.Finish(player: Player): Verdict
	local state = getState(player)
	state.active = false

	local valid = state.hardViolations == 0 and state.softViolations <= MAX_SOFT_VIOLATIONS
	local reason: string? = nil
	if not valid then
		reason = state.firstReason or "movement validation failed"
	end

	return {
		valid = valid,
		reason = reason,
		softViolations = state.softViolations,
		hardViolations = state.hardViolations,
		peakSpeed = state.peakSpeed,
	}
end

function MovementAudit.Release(player: Player)
	states[player] = nil
end

function MovementAudit.Start()
	Players.PlayerRemoving:Connect(MovementAudit.Release)
end

return MovementAudit
