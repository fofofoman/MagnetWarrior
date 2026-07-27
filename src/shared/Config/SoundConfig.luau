--!strict
--[[
	SoundConfig.luau

	Every sound the game plays, in one table.

	`assetId = 0` means "not sourced yet" and SoundKit treats it as a silent
	no-op — the same pattern MonetizationConfig uses for unconfigured products.
	That is deliberate: the audio *wiring* is a code problem and is finished, but
	the audio *assets* are a content problem that has to be solved in the Roblox
	creator dashboard. Dropping ids in here later turns the whole game audible
	without touching another file.

	`volume` and `pitch` are tuned per entry rather than at the call site, so
	balancing the mix is an edit to this table and nothing else. `pitchJitter`
	randomises playback rate by ±n, which is what stops repeated sounds (magnet
	fire, impacts) from sounding like a machine gun.
]]

export type SoundDefinition = {
	assetId: number,
	volume: number,
	pitch: number,
	pitchJitter: number?,
	--- Studs at which the sound starts falling off. Positional sounds only.
	rollOffMin: number?,
	rollOffMax: number?,
	looped: boolean?,
}

local SoundConfig = {}

local function sound(assetId: number, volume: number, pitch: number?, jitter: number?): SoundDefinition
	return {
		assetId = assetId,
		volume = volume,
		pitch = pitch or 1,
		pitchJitter = jitter,
		rollOffMin = 12,
		rollOffMax = 220,
	}
end

local definitions: { [string]: SoundDefinition } = {
	-- ── Magnet ──────────────────────────────────────────────────────────────
	PullFire = sound(0, 0.45, 1.0, 0.08),
	PushFire = sound(0, 0.55, 0.92, 0.08),
	MagnetMiss = sound(0, 0.25, 1.15, 0.05),
	MagnetDenied = sound(0, 0.3, 0.8),
	ClingAttach = sound(0, 0.5, 1.0, 0.05),
	ClingRelease = sound(0, 0.45, 1.05, 0.05),
	GrappleLaunch = sound(0, 0.5, 1.0, 0.06),

	-- ── Combat ──────────────────────────────────────────────────────────────
	ImpactLight = sound(0, 0.5, 1.1, 0.1),
	ImpactHeavy = sound(0, 0.7, 0.85, 0.1),
	EnemyDeath = sound(0, 0.6, 1.0, 0.08),
	PlayerHurt = sound(0, 0.5, 1.0, 0.05),

	-- ── Boss ────────────────────────────────────────────────────────────────
	BossArmorOpen = sound(0, 0.8, 1.0),
	BossArmorClose = sound(0, 0.7, 0.9),
	BossThrow = sound(0, 0.5, 1.0, 0.06),
	BossDefeated = sound(0, 0.9, 1.0),

	-- ── Stage ───────────────────────────────────────────────────────────────
	Checkpoint = sound(0, 0.6, 1.0),
	GateOpen = sound(0, 0.65, 1.0),
	SocketFilled = sound(0, 0.55, 1.0, 0.04),
	PuzzleComplete = sound(0, 0.7, 1.0),
	PolarityOn = sound(0, 0.35, 1.0),
	PolarityOff = sound(0, 0.3, 0.85),

	-- ── Run / UI (played locally, non-positional) ───────────────────────────
	RunStart = sound(0, 0.6, 1.0),
	RunFinish = sound(0, 0.7, 1.0),
	RunRejected = sound(0, 0.6, 0.8),
	MedalGold = sound(0, 0.8, 1.0),
	MedalSilver = sound(0, 0.75, 1.0),
	MedalBronze = sound(0, 0.7, 1.0),
	PersonalBest = sound(0, 0.8, 1.0),
	PanelOpen = sound(0, 0.4, 1.0),
	-- Closing is deliberately quieter and lower than opening: the pair reads as
	-- one gesture rather than two unrelated blips.
	PanelClose = sound(0, 0.32, 0.88),
	ButtonClick = sound(0, 0.35, 1.0),
	Purchase = sound(0, 0.6, 1.0),
	Notify = sound(0, 0.4, 1.0),
}

SoundConfig.Definitions = definitions

--- Medal tier -> sound name, so the result card does not need a lookup chain.
SoundConfig.MedalSounds = {
	Gold = "MedalGold",
	Silver = "MedalSilver",
	Bronze = "MedalBronze",
	None = "RunFinish",
}

function SoundConfig.Get(name: string): SoundDefinition?
	return definitions[name]
end

--- True once at least one asset id has been filled in. Used only to decide
--- whether to bother warning about a silent build.
function SoundConfig.HasAnyAssets(): boolean
	for _, definition in definitions do
		if definition.assetId ~= 0 then
			return true
		end
	end
	return false
end

return SoundConfig
