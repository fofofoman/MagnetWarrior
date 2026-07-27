--!nonstrict
--[[
	Client bootstrap.

	Everything here is presentation and input. There is no gameplay decision on
	this side of the wire: the client reports what the player pressed and where
	they were looking, and renders what the server sends back. Timers shown are
	interpolations of server values, medals are server verdicts, and the stage
	list's lock icons mirror a rule the server enforces independently.
]]

local Players = game:GetService("Players")

local AudioController = require(script.AudioController)
local GhostPlayer = require(script.Effects.GhostPlayer)
local ImpactEffects = require(script.Effects.ImpactEffects)
local MagnetController = require(script.MagnetController)
local MagnetEffects = require(script.Effects.MagnetEffects)
local Hud = require(script.UI.Hud)
local LeaderboardPanel = require(script.UI.LeaderboardPanel)
local MedalPopup = require(script.UI.MedalPopup)
local RespawnPrompt = require(script.UI.RespawnPrompt)
local RunState = require(script.State.RunState)
local ShopPanel = require(script.UI.ShopPanel)
local Toast = require(script.UI.Toast)

local player = Players.LocalPlayer

local function main()
	-- State before UI: the panels subscribe to RunState on construction.
	RunState.Start()

	MagnetController.Start()
	MagnetEffects.Start()
	ImpactEffects.Start()
	GhostPlayer.Start()
	AudioController.Start()

	Toast.Start()
	Hud.Start()
	MedalPopup.Start()
	LeaderboardPanel.Start()

	-- ShopPanel owns the entitlement snapshot, so it starts before the retry
	-- prompt that reads ticket counts from it.
	ShopPanel.Start()
	RespawnPrompt.Start()

	print(`[MagnetWarrior] client ready for {player.Name}`)
end

main()
