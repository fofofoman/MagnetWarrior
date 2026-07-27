--!strict
--[[
	Types.luau
	Shared type definitions. Kept in one place so the server, the client and the
	config modules all agree on the shape of the data that crosses the wire.
]]

export type Hand = "Left" | "Right"
export type MagnetAction = "Pull" | "Push"

--- What the magnet actually did, resolved on the server and echoed back to the
--- client purely so it can play the matching effect.
export type MagnetOutcome =
	"MovedTarget" -- the object was light enough to fly
	| "MovedSelf" -- anchored / heavy target, so the player moved instead
	| "Clinging" -- the player latched onto a magnetic surface
	| "Released" -- a cling or grab ended
	| "NoTarget"
	| "OnCooldown"
	| "Rejected" -- failed validation (rate limit, bad input, out of range)

export type MedalTier = "Gold" | "Silver" | "Bronze" | "None"

export type StageKind = "Tutorial" | "Combat" | "Puzzle" | "Boss" | "Extra"

--- Per-stage medal thresholds, in milliseconds.
export type MedalThresholds = {
	Gold: number,
	Silver: number,
	Bronze: number,
}

export type StageDefinition = {
	id: string,
	order: number,
	displayName: string,
	kind: StageKind,
	description: string,
	--- Mechanics the stage is allowed to use. The server refuses magnet actions
	--- that a stage has not unlocked, which is what makes the tutorial stages
	--- genuinely Pull-only / Push-only.
	allowedActions: { MagnetAction },
	medals: MedalThresholds,
	--- Hard floor for a legitimate run, in milliseconds. Any completion faster
	--- than this is impossible and is rejected outright.
	minPossibleMs: number,
	--- Number of ordered checkpoints, excluding start and finish.
	checkpointCount: number,
	--- World-space origin the stage geometry is built at.
	originX: number,
	--- Stages without a layout module are listed but not yet playable.
	hasLayout: boolean,
	requires: string?, -- stage id that must be cleared first
}

export type StageRecord = {
	bestTimeMs: number,
	medal: MedalTier,
	achievedAt: number, -- unix seconds
	completions: number,
	attempts: number,
}

export type LeaderboardEntry = {
	userId: number,
	displayName: string,
	timeMs: number,
	medal: MedalTier,
	rank: number,
}

export type LeaderboardScope = "Personal" | "Friends" | "Global"

export type LeaderboardPayload = {
	stageId: string,
	scope: LeaderboardScope,
	entries: { LeaderboardEntry },
	--- Set when a scope is recognised but switched off by a feature flag.
	unavailableReason: string?,
}

--- Sent to the client whenever the run state changes. The client renders this;
--- it never computes it.
export type RunUpdate = {
	kind: "Started" | "Checkpoint" | "Finished" | "Aborted" | "Sync",
	stageId: string,
	--- Server clock (workspace:GetServerTimeNow) the run began at, so the client
	--- can interpolate a smooth timer between syncs without being trusted.
	startedAt: number?,
	elapsedMs: number?,
	checkpointIndex: number?,
	checkpointTotal: number?,
	splitMs: number?,
	medal: MedalTier?,
	isPersonalBest: boolean?,
	previousBestMs: number?,
	rejected: boolean?,
	rejectReason: string?,
}

export type GhostScope = "Personal" | "Best"

--- A recorded run. `data` is a flat integer array of
--- (x, y, z, yawDegrees) quadruples, quantised to one decimal place for
--- position — see GhostRecorder for why it is stored this way rather than as an
--- array of CFrames.
export type GhostPayload = {
	stageId: string,
	scope: GhostScope,
	userId: number,
	displayName: string,
	timeMs: number,
	sampleRate: number,
	data: { number },
	unavailableReason: string?,
}

export type PurchaseCategory = "Cosmetic" | "Convenience" | "Consumable"

--- Every sellable item declares how much it can influence a run. Anything other
--- than "None" or "Convenience" is refused at boot — see MonetizationConfig.
export type GameplayImpact = "None" | "Convenience"

export type ProductDefinition = {
	key: string,
	assetId: number,
	displayName: string,
	description: string,
	category: PurchaseCategory,
	impact: GameplayImpact,
	--- Cosmetic payload, e.g. the colour a magnet beam is tinted.
	cosmetic: { [string]: any }?,
}

return nil
