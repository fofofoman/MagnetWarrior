--!nonstrict
--[[
	Stage11Hangar.luau — 무중력 격납고 (post-game challenge)

	"바닥이 없다. 벽만 있다."

	The premise is a single subtraction: after the spawn pad there is no floor,
	only walls and four small ledges. Every stud of progress is made while
	attached to something, which is the one thing the main campaign never asks
	for continuously.

	It also re-reads the campaign's three wall types in order — static, pulsing,
	travelling — so the difficulty is memory rather than novelty. A player who
	cleared stage 10 already knows every verb here; what is new is having no
	ground to retreat to while using them.

	Drones patrol the route with nothing under them, so a Push is lethal and a
	miss costs you the wall you were about to grab.
]]

local StageBuilder = require(script.Parent.Parent.StageBuilder)

local STEEL = StageBuilder.Palette.Steel
local LEDGE = Color3.fromRGB(96, 104, 114)

local BEAT = 6

local layout: StageBuilder.Layout = {
	spawn = Vector3.new(0, 6, -14),
	killY = -40,

	parts = {
		{ name = "SpawnPad", size = Vector3.new(36, 2, 36), position = Vector3.new(0, 0, 0), color = STEEL },

		-- Four ledges, and nothing else to stand on for the rest of the stage.
		{ name = "Ledge1", size = Vector3.new(24, 2, 24), position = Vector3.new(0, 30, 90), color = LEDGE },
		{ name = "Ledge2", size = Vector3.new(24, 2, 24), position = Vector3.new(0, 62, 170), color = LEDGE },
		{ name = "Ledge3", size = Vector3.new(24, 2, 24), position = Vector3.new(0, 84, 244), color = LEDGE },
		{ name = "FinishPad", size = Vector3.new(30, 2, 30), position = Vector3.new(0, 88, 305), color = STEEL },
	},

	magnetic = {
		-- ── 1. 정지한 벽 ────────────────────────────────────────────────────
		-- Alternating sides, each one overlapping the next so the transfer is a
		-- grapple across open air rather than a leap of faith.
		{ name = "HangarWall1", size = Vector3.new(3, 28, 32), position = Vector3.new(14, 14, 34), surface = true },
		{ name = "HangarWall2", size = Vector3.new(3, 28, 30), position = Vector3.new(-14, 26, 65), surface = true },

		-- ── 3. 마지막 구간 ──────────────────────────────────────────────────
		-- One long static wall out to the finish, as a breather after the ferry.
		{ name = "HangarWall3", size = Vector3.new(3, 26, 40), position = Vector3.new(14, 90, 275), surface = true },
	},

	kinetics = {
		-- ── 2. 극성이 바뀌는 벽 ─────────────────────────────────────────────
		{
			name = "PulseWall1",
			size = Vector3.new(3, 30, 32),
			position = Vector3.new(14, 44, 118),
			period = BEAT,
			phase = 0,
			pulses = true,
			dutyCycle = 0.5,
			surface = true,
		},
		{
			name = "PulseWall2",
			size = Vector3.new(3, 30, 32),
			position = Vector3.new(-14, 58, 150),
			period = BEAT,
			phase = 0.5,
			pulses = true,
			dutyCycle = 0.5,
			surface = true,
		},

		-- ── 3. 움직이는 벽 ──────────────────────────────────────────────────
		-- Travels up *and* forward, so the ride gains the height the next ledge
		-- needs. Boarding at the near-low end is the whole trick.
		{
			name = "HangarFerry",
			size = Vector3.new(18, 28, 3),
			position = Vector3.new(0, 74, 205),
			travel = Vector3.new(0, 14, 30),
			period = BEAT * 1.6,
			phase = 0.75,
			surface = true,
		},
	},

	enemies = {
		-- Nothing under any of them. A Push is a kill; a miss costs you the wall.
		{ kind = "Spark", position = Vector3.new(6, 22, 40), group = "hangar1" },
		{ kind = "Spark", position = Vector3.new(-6, 34, 68), group = "hangar1" },
		{ kind = "Spark", position = Vector3.new(8, 50, 120), group = "hangar2" },
		{ kind = "Scrapper", position = Vector3.new(-8, 64, 152), group = "hangar2" },
		{ kind = "Hauler", position = Vector3.new(0, 70, 200), group = "hangar3" },
		{ kind = "Spark", position = Vector3.new(8, 92, 272), group = "hangar3" },
	},

	start = { position = Vector3.new(0, 6, 8), size = Vector3.new(28, 10, 6) },
	checkpoints = {
		{ position = Vector3.new(0, 36, 90), size = Vector3.new(20, 10, 6) },
		{ position = Vector3.new(0, 68, 170), size = Vector3.new(20, 10, 6) },
		{ position = Vector3.new(0, 90, 244), size = Vector3.new(20, 10, 6) },
	},
	finish = { position = Vector3.new(0, 94, 305), size = Vector3.new(26, 10, 8) },
}

return layout
