--!nonstrict
--[[
	AudioController.luau

	Non-positional feedback for the local player: run start and finish stings,
	medal fanfares, and notification blips.

	World audio — magnet fire, impacts, gates, polarity ticks — is *not* here.
	Those are created on the server so every player in the room hears them from
	the right place. This file only handles the sounds that belong to one
	listener and have no position.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)
local SoundConfig = require(Shared.Config.SoundConfig)
local SoundKit = require(Shared.Util.SoundKit)

local RunState = require(script.Parent.State.RunState)

local AudioController = {}

local toneSounds = {
	Good = "Purchase",
	Warn = "Notify",
	Bad = "RunRejected",
	Info = "Notify",
}

local function onRunUpdate(update)
	if update.kind == "Started" then
		SoundKit.PlayLocal("RunStart")
	elseif update.kind == "Aborted" then
		SoundKit.PlayLocal("RunRejected")
	elseif update.kind == "Finished" then
		if update.rejected then
			SoundKit.PlayLocal("RunRejected")
			return
		end

		SoundKit.PlayLocal(SoundConfig.MedalSounds[update.medal or "None"] or "RunFinish")

		-- A personal best gets its own layer on top of the medal sting rather
		-- than replacing it: they are two different pieces of news.
		if update.isPersonalBest then
			task.delay(0.35, function()
				SoundKit.PlayLocal("PersonalBest")
			end)
		end
	end
end

function AudioController.Start()
	RunState.Changed:Connect(onRunUpdate)

	Net.Notify.OnClientEvent:Connect(function(payload)
		if typeof(payload) ~= "table" then
			return
		end
		SoundKit.PlayLocal(toneSounds[payload.tone] or "Notify")
	end)

	if not SoundConfig.HasAnyAssets() then
		-- Not a warning: a silent build is the expected state until audio is
		-- sourced, and the wiring is already complete.
		print("[MagnetWarrior] no sound asset ids configured yet — audio is wired but silent")
	end
end

return AudioController
