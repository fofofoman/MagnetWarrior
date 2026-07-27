--!strict
--[[
	MagnetConfig.luau
	Tuning for the two core forces. Every value here is read by the *server* —
	the client keeps a copy only so it can draw effects at the right length and
	grey out buttons during cooldown. The client's copy is never authoritative.
]]

local MagnetConfig = {}

-- ─────────────────────────────────────────────────────────────────────────────
-- Targeting
-- ─────────────────────────────────────────────────────────────────────────────

MagnetConfig.MaxRange = 90 -- studs
MagnetConfig.MinRange = 3 -- closer than this and the magnet has nothing to push against

--- The client aims with a camera ray. If that ray misses, the server sweeps a
--- cone around it and takes the best magnetic candidate — this is aim assist,
--- and doing it server-side means a modified client gains nothing by claiming a
--- perfect hit.
MagnetConfig.AssistConeDegrees = 12
MagnetConfig.AssistMaxCandidates = 40

--- How far the claimed ray origin may sit from the player's head before the
--- action is rejected as spoofed.
MagnetConfig.MaxOriginDeviation = 8 -- studs

-- ─────────────────────────────────────────────────────────────────────────────
-- Forces
-- ─────────────────────────────────────────────────────────────────────────────

--- Applied as an impulse (mass * velocity delta), so heavy things move less.
---
--- These numbers are load-bearing for combat, not decoration. Impact damage is
--- driven by closing speed, and closing speed is impulse/mass, so an impulse
--- that is too small silently turns "밀어서 벽에 처박기" into a mechanic that
--- deals zero damage. Worked example at the current values:
---
---   Scrapper (mass 35) : 4500/35 → capped at PushTargetSpeed 105 → 131 damage
---                        at range (falloff 0.45): 57 studs/s     →  46 damage
---   Hauler   (mass 108): 4500/108 = 42 studs/s                   →  17 damage
---
--- so a committed close-range slam kills a Scrapper outright, a long-range one
--- chips it, and the Hauler is too heavy to slam — it has to be dealt with by
--- throwing *other* things at it. That gradient is the combat design; changing
--- these values changes it.
MagnetConfig.PullImpulse = 2800
MagnetConfig.PushImpulse = 4500

--- Impulse is scaled by distance: full strength up close, PullFalloffMin at max
--- range. Keeps long-range shots from being strictly better.
MagnetConfig.FalloffAtMaxRange = 0.45

--- A target heavier than this (or anchored) cannot be moved, so the force is
--- reflected onto the player instead. That reflection *is* the movement
--- mechanic: grapple-pull toward walls, push off them to launch.
MagnetConfig.ImmovableMassThreshold = 260

MagnetConfig.SelfPullSpeed = 78 -- studs/s toward an anchored target, at the start of a grapple
MagnetConfig.SelfPushSpeed = 92 -- studs/s away from an anchored target, from a standstill
MagnetConfig.SelfPushUpBias = 0.35 -- fraction of push redirected upward, so push-off feels like a jump

--- **Momentum compounds.** A push-off does not overwrite your speed, it adds to
--- whatever you already had going that way. Chaining pushes in one direction is
--- therefore genuinely faster than repeating them from a standstill, which is
--- what gives the movement a skill ceiling instead of a fixed hop distance:
---
---   from rest → 92 → 126 → 128 (capped)
---
--- ChainedSpeedCap sits deliberately below MovementAudit's
--- MaxLegitimateSpeed (140) so that the fastest *legal* play still leaves the
--- anti-cheat headroom. Raise one and you must raise the other.
MagnetConfig.ChainedSpeedCap = 128
MagnetConfig.PushChainBonus = 34
MagnetConfig.ClingLaunchChainBonus = 26

--- Speed a self-launch should leave the player at. Lives here rather than in
--- either caller because MagnetService and ClingController both need it and
--- cannot share a module (MagnetService already requires ClingController), and a
--- duplicated tuning formula is a drift waiting to happen.
function MagnetConfig.ChainSpeed(current: Vector3, direction: Vector3, base: number, bonus: number): number
	local along = current:Dot(direction)
	return math.clamp(math.max(along + bonus, base), base, MagnetConfig.ChainedSpeedCap)
end

--- Pull on an immovable target is a *grapple*, not a blink: the server holds a
--- velocity toward the anchor while the button is down, and converts it to a
--- cling on arrival. These bound how long that can last.
MagnetConfig.SelfPullMaxDuration = 3.0 -- seconds before the grapple gives out
MagnetConfig.SelfPullMaxForce = 45000

--- A grapple accelerates rather than running at a fixed speed, so a long line
--- pays out real velocity and reaching the anchor with speed to spare is worth
--- aiming for. Momentum survives the release, so grapple → push is the fastest
--- thing in the game.
MagnetConfig.SelfPullMaxSpeed = 120
MagnetConfig.SelfPullRampSeconds = 0.9

-- ─────────────────────────────────────────────────────────────────────────────
-- Object motion
-- ─────────────────────────────────────────────────────────────────────────────

--- Pulled objects are steered to a hold point in front of the player rather
--- than into their face.
MagnetConfig.HoldDistance = 9 -- studs in front of the torso
MagnetConfig.HoldHeight = 1.5 -- studs above the torso

--- Pull steers toward the hold point with a proportional gain, clamped so
--- distant objects do not arrive at absurd speed.
MagnetConfig.PullTargetGain = 2.4
--- Near-zero on purpose. A proportional controller is supposed to ease off as
--- it arrives; a meaningful floor here meant every pulled object was still
--- doing 18 studs/s when it reached the hold point and always overshot, which
--- made socket placement a fight. The impulse cap above already stops heavy
--- objects from being ignored.
MagnetConfig.PullTargetMinSpeed = 6
MagnetConfig.PullTargetMaxSpeed = 95

MagnetConfig.PushTargetSpeed = 105
MagnetConfig.PushTargetUpBias = 0.12 -- keeps pushed crates from grinding along the floor

--- Ceiling used by the movement audit. Nothing the magnet does may exceed it.
MagnetConfig.MaxLegitimateSpeed = 140 -- studs/s

-- ─────────────────────────────────────────────────────────────────────────────
-- Cling (자석 벽 타기)
-- ─────────────────────────────────────────────────────────────────────────────

--- Holding Pull on a MagneticSurface latches the player once they arrive.
MagnetConfig.ClingRange = 7 -- distance to the surface at which the latch engages
MagnetConfig.ClingMaxDuration = 6 -- seconds before the magnet overheats and drops you
MagnetConfig.ClingMoveSpeed = 16 -- lateral climb speed while latched
MagnetConfig.ClingReleaseImpulse = 42 -- pop-off given when the player lets go

-- ─────────────────────────────────────────────────────────────────────────────
-- Cooldowns and rate limits
-- ─────────────────────────────────────────────────────────────────────────────

MagnetConfig.PullCooldown = 0.24
MagnetConfig.PushCooldown = 0.34

--- Hitting nothing costs almost nothing. Charging the full cooldown for a whiff
--- punishes exploring the space exactly as hard as committing to a slam, which
--- makes players stop probing and start waiting — the opposite of what a
--- movement game wants.
MagnetConfig.MissCooldown = 0.12

--- Hard remote rate limit, enforced independently of cooldowns. A client that
--- exceeds it is throttled rather than trusted.
MagnetConfig.MaxActionsPerSecond = 12
MagnetConfig.RateLimitBurst = 6

-- ─────────────────────────────────────────────────────────────────────────────
-- Impact damage
-- ─────────────────────────────────────────────────────────────────────────────

--- Below this closing speed an impact does nothing; the mechanic should reward
--- deliberate slams, not incidental nudges. Kept low enough that a mid-range
--- push still registers — see the worked example on PushImpulse above.
MagnetConfig.ImpactMinSpeed = 32 -- studs/s
MagnetConfig.ImpactDamagePerSpeed = 1.8 -- damage per stud/s above the minimum
MagnetConfig.ImpactMaxDamage = 150

--- Window after a magnet impulse during which the object counts as "thrown" and
--- can deal impact damage. Stops a slow-rolling crate from being lethal.
MagnetConfig.ImpactActiveWindow = 2.5 -- seconds

--- Cooldown between damage events for the same object/victim pair.
MagnetConfig.ImpactCooldown = 0.4

return MagnetConfig
