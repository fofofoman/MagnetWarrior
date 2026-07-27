--!nonstrict
--[[
	SoundKit.luau

	One call site shape for audio on both the server and the client.

		SoundKit.PlayAt("ImpactHeavy", part)      -- positional, heard by everyone
		SoundKit.PlayLocal("MedalGold")           -- client only, non-positional

	Positional sounds are created on the *server* and replicate on their own,
	which is why impacts and gates sound the same to every player without a
	broadcast remote. Local sounds are UI feedback and belong to one listener.

	An entry whose `assetId` is 0 is not sourced yet, so every function here
	returns immediately. That keeps the wiring honest — the call sites are real
	and complete — while the game stays silent until audio assets exist.
]]

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")

local SoundConfig = require(script.Parent.Parent.Config.SoundConfig)

local SoundKit = {}

--- How long a one-shot lingers before cleanup. Generous: Debris only needs to
--- outlast the clip, and a truncated sound is worse than a late collect.
local CLEANUP_SECONDS = 8

--- Slack past a sound's falloff radius before it is considered inaudible.
local AUDIBLE_MARGIN = 1.5

--- True if any player is close enough for this to matter. All twelve stages are
--- built and simulated simultaneously, so without this a pulsing wall in an
--- empty stage would create Sound instances forever.
local function anyoneNearby(position: Vector3, radius: number): boolean
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if root and (root.Position - position).Magnitude <= radius then
			return true
		end
	end
	return false
end

local function configure(sound: Sound, definition: SoundConfig.SoundDefinition)
	sound.SoundId = `rbxassetid://{definition.assetId}`
	sound.Volume = definition.volume
	sound.Looped = definition.looped == true

	local jitter = definition.pitchJitter
	if jitter and jitter > 0 then
		sound.PlaybackSpeed = definition.pitch + (math.random() * 2 - 1) * jitter
	else
		sound.PlaybackSpeed = definition.pitch
	end
end

--- A world-positioned one-shot. `target` may be a part (the sound follows it)
--- or a position (an invisible anchor is created and cleaned up).
function SoundKit.PlayAt(name: string, target: BasePart | Vector3): Sound?
	local definition = SoundConfig.Get(name)
	if not definition or definition.assetId == 0 then
		return nil
	end

	local origin = if typeof(target) == "Vector3" then target else (target :: BasePart).Position
	if not anyoneNearby(origin, (definition.rollOffMax or 220) * AUDIBLE_MARGIN) then
		return nil
	end

	local parent: BasePart
	local temporary: BasePart? = nil

	if typeof(target) == "Vector3" then
		local anchor = Instance.new("Part")
		anchor.Name = "SoundAnchor"
		anchor.Size = Vector3.one
		anchor.Transparency = 1
		anchor.Anchored = true
		anchor.CanCollide = false
		anchor.CanQuery = false
		anchor.CanTouch = false
		anchor.Position = target
		anchor.Parent = workspace
		parent = anchor
		temporary = anchor
	else
		if not target.Parent then
			return nil
		end
		parent = target
	end

	local sound = Instance.new("Sound")
	sound.Name = `SFX_{name}`
	configure(sound, definition)
	sound.RollOffMode = Enum.RollOffMode.InverseTapered
	sound.RollOffMinDistance = definition.rollOffMin or 12
	sound.RollOffMaxDistance = definition.rollOffMax or 220
	sound.Parent = parent
	sound:Play()

	-- The anchor owns the sound, so cleaning it up cleans up both.
	Debris:AddItem(temporary or sound, CLEANUP_SECONDS)
	return sound
end

--- Non-positional feedback for the local player. Client only; calling it on the
--- server is a no-op rather than an error, so shared code stays simple.
function SoundKit.PlayLocal(name: string): Sound?
	if not RunService:IsClient() then
		return nil
	end

	local definition = SoundConfig.Get(name)
	if not definition or definition.assetId == 0 then
		return nil
	end

	local sound = Instance.new("Sound")
	sound.Name = `UI_{name}`
	configure(sound, definition)
	sound.Parent = SoundService
	sound:Play()

	Debris:AddItem(sound, CLEANUP_SECONDS)
	return sound
end

return SoundKit
