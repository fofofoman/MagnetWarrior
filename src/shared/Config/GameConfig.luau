--!strict
--[[
	GameConfig.luau
	Global switches and tuning that is not specific to one system.
]]

local GameConfig = {}

--- Feature flags. Each one gates a *read* path only — the systems behind them
--- have been writing data since the first build, which is what made turning
--- them on a flag flip rather than a migration.
GameConfig.Features = {
	--- Phase 2. The write path has been live since day one, so switching this on
	--- exposes records that already exist rather than an empty board.
	GlobalLeaderboard = true,
	FriendLeaderboard = true,
	--- Recording, storage and playback are all implemented; the ticket product
	--- gates access to *other people's* ghosts only.
	GhostReplay = true,
	--- Still deliberately unbuilt — see docs/MONETIZATION.md for the shape they
	--- will plug into.
	SeasonPass = false,
	RewardedAds = false,
}

--- Verbose server logging for magnet resolution and audit decisions.
GameConfig.Debug = {
	MagnetResolution = false,
	MovementAudit = false,
	DataStore = false,
	--- Treat cosmetic passes as owned while testing in Studio. Cosmetics only —
	--- there is nothing gameplay-affecting to grant, by design.
	GrantCosmeticsInStudio = true,
}

--- CollectionService tags. Anything the magnet can interact with is tagged;
--- untagged geometry is inert, which keeps targeting cheap and predictable.
GameConfig.Tags = {
	Magnetic = "Magnetic", -- any part the magnet can grab
	MagneticSurface = "MagneticSurface", -- anchored wall you can cling to / ride
	Enemy = "Enemy",
	PuzzleBlock = "PuzzleBlock",
	PuzzleSocket = "PuzzleSocket",
	Gate = "Gate",
	--- Walls that move, or whose magnetism pulses on a cycle. See MotionService.
	Kinetic = "Kinetic",
	Hazard = "Hazard",
	StageStart = "StageStart",
	StageFinish = "StageFinish",
	Checkpoint = "Checkpoint",
	Killbrick = "Killbrick",
}

--- Physics collision groups created at boot.
---
--- `Trigger` is the important one: run-timing volumes must be queryable by the
--- server's overlap scan but invisible to the magnet's raycasts, and a
--- collision group is the only way to have both.
GameConfig.CollisionGroups = {
	Default = "Default",
	Player = "Player",
	Trigger = "Trigger",
}

--- How often the server samples player position for the movement audit.
GameConfig.AuditSampleRate = 10 -- Hz

--- How often the server pushes an authoritative timer sync to the client.
GameConfig.TimerSyncRate = 2 -- Hz

--- Respawn delay after death, in seconds. The "skip retry wait" developer
--- product removes this wait and nothing else.
GameConfig.RespawnDelay = 3

GameConfig.MaxStageOriginSpacing = 2000 -- studs between stage build origins

return GameConfig
