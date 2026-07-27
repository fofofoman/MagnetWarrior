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
MagnetConfig.PullImpulse = 1400
MagnetConfig.PushImpulse = 1900

--- Impulse is scaled by distance: full strength up close, PullFalloffMin at max
--- range. Keeps long-range shots from being strictly better.
MagnetConfig.FalloffAtMaxRange = 0.45

--- A target heavier than this (or anchored) cannot be moved, so the force is
--- reflected onto the player instead. That reflection *is* the movement
--- mechanic: grapple-pull toward walls, push off them to launch.
MagnetConfig.ImmovableMassThreshold = 260

MagnetConfig.SelfPullSpeed = 78 -- studs/s toward an anchored target
MagnetConfig.SelfPushSpeed = 92 -- studs/s away from an anchored target
MagnetConfig.SelfPushUpBias = 0.35 -- fraction of push redirected upward, so push-off feels like a jump

--- Pull on an immovable target is a *grapple*, not a blink: the server holds a
--- velocity toward the anchor while the button is down, and converts it to a
--- cling on arrival. These bound how long that can last.
MagnetConfig.SelfPullMaxDuration = 3.0 -- seconds before the grapple gives out
MagnetConfig.SelfPullMaxForce = 45000

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
MagnetConfig.PullTargetMinSpeed = 18
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

MagnetConfig.PullCooldown = 0.30
MagnetConfig.PushCooldown = 0.45

--- Hard remote rate limit, enforced independently of cooldowns. A client that
--- exceeds it is throttled rather than trusted.
MagnetConfig.MaxActionsPerSecond = 12
MagnetConfig.RateLimitBurst = 6

-- ─────────────────────────────────────────────────────────────────────────────
-- Impact damage
-- ─────────────────────────────────────────────────────────────────────────────

--- Below this closing speed an impact does nothing; the mechanic should reward
--- deliberate slams, not incidental nudges.
MagnetConfig.ImpactMinSpeed = 46 -- studs/s
MagnetConfig.ImpactDamagePerSpeed = 0.85 -- damage per stud/s above the minimum
MagnetConfig.ImpactMaxDamage = 120

--- Window after a magnet impulse during which the object counts as "thrown" and
--- can deal impact damage. Stops a slow-rolling crate from being lethal.
MagnetConfig.ImpactActiveWindow = 2.5 -- seconds

--- Cooldown between damage events for the same object/victim pair.
MagnetConfig.ImpactCooldown = 0.4

return MagnetConfig
