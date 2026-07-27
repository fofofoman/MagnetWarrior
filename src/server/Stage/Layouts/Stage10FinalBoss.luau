--!nonstrict
--[[
	Stage10FinalBoss.luau — 최종보스: 대자석로

	"이동, 전투, 퍼즐 전부. 배운 것을 전부 쓰지 않으면 이길 수 없다."

	Three segments, one per pillar of the game, and then the fight that needs all
	three at once:

	  1. **이동** — the stage-7 crossing: alternating pulsing walls over open air.
	  2. **퍼즐** — a stage-6 style assembly bridge that opens the furnace door.
	  3. **전투** — the boss, which is the miniboss's armour pattern plus two
	     things it did not have: reinforcements every 16 seconds, and two
	     travelling magnet walls sweeping the arena.

	The travelling walls are the reason this is the final fight rather than a
	tougher miniboss. They are cover you have to keep re-earning: live the whole
	time, but never where you left them, so the escape route during the closed
	phase has to be re-read every cycle.

	Its windows are tighter than the miniboss's (3.5s open against 7s closed) and
	the core has far more health, so a player who has not learned to convert the
	boss's own scrap into damage will run out of window long before it runs out
	of hit points.
]]

local StageBuilder = require(script.Parent.Parent.StageBuilder)

local BossService = require(script.Parent.Parent.Parent.Combat.BossService)

local STEEL = StageBuilder.Palette.Steel
local FLOOR = Color3.fromRGB(72, 76, 88)
local LEDGE = Color3.fromRGB(96, 104, 114)

local BEAT = 6
local SLAB = Vector3.new(10, 2, 12)

local magnetic = {
	-- Arena cling walls.
	{ name = "ArenaWall", size = Vector3.new(3, 30, 110), position = Vector3.new(-49, 15, 350), surface = true },
	{ name = "ArenaWall", size = Vector3.new(3, 30, 110), position = Vector3.new(49, 15, 350), surface = true },
	{ name = "ArenaWall", size = Vector3.new(100, 30, 3), position = Vector3.new(0, 15, 404), surface = true },
	-- A handhold in the puzzle room, for recovering a bad pull.
	{ name = "RecoveryWall", size = Vector3.new(3, 26, 56), position = Vector3.new(-27, 13, 170), surface = true },
}

for _, position in
	{
		Vector3.new(-36, 5, 312),
		Vector3.new(36, 5, 312),
		Vector3.new(-36, 5, 392),
		Vector3.new(36, 5, 392),
		Vector3.new(0, 5, 306),
	}
do
	table.insert(magnetic, {
		name = "ScrapCrate",
		size = Vector3.new(6, 6, 6),
		position = position,
		anchored = false,
		density = 0.6,
		material = Enum.Material.CorrodedMetal,
		color = Color3.fromRGB(146, 118, 92),
	})
end

local layout: StageBuilder.Layout = {
	spawn = Vector3.new(0, 6, -14),
	killY = -70,

	parts = {
		{ name = "SpawnPad", size = Vector3.new(40, 2, 40), position = Vector3.new(0, 0, 0), color = STEEL },

		-- 1. 이동 — z 20..90 is open air.
		{ name = "Landing1", size = Vector3.new(34, 2, 50), position = Vector3.new(0, 0, 115), color = STEEL },

		-- 2. 퍼즐 — assembly room, then a socket bridge over z 202..240.
		{ name = "PuzzleFloor", size = Vector3.new(50, 2, 60), position = Vector3.new(0, 0, 170), color = FLOOR },
		{ name = "SupplyLedge", size = Vector3.new(38, 2, 12), position = Vector3.new(0, 3, 150), color = LEDGE },
		{ name = "Landing2", size = Vector3.new(34, 2, 56), position = Vector3.new(0, 0, 268), color = STEEL },

		-- 3. 전투 — the furnace floor.
		{ name = "ArenaFloor", size = Vector3.new(100, 2, 110), position = Vector3.new(0, 0, 350), color = FLOOR },
		{ name = "FinishPad", size = Vector3.new(34, 2, 46), position = Vector3.new(0, 0, 428), color = STEEL },
	},

	magnetic = magnetic,

	kinetics = {
		-- The approach: same tempo the player learned in stage 7.
		{
			name = "ApproachWallA",
			size = Vector3.new(3, 30, 38),
			position = Vector3.new(11, 18, 38),
			period = BEAT,
			phase = 0,
			pulses = true,
			dutyCycle = 0.5,
			surface = true,
		},
		{
			name = "ApproachWallB",
			size = Vector3.new(3, 30, 38),
			position = Vector3.new(11, 18, 74),
			period = BEAT,
			phase = 0.5,
			pulses = true,
			dutyCycle = 0.5,
			surface = true,
		},

		-- Arena cover. Always live, never still — sweeping laterally on
		-- opposite phases so the safe side keeps changing.
		{
			name = "SweepWallLeft",
			size = Vector3.new(3, 24, 30),
			position = Vector3.new(-22, 12, 330),
			travel = Vector3.new(0, 0, 24),
			period = BEAT * 1.5,
			phase = 0,
			surface = true,
		},
		{
			name = "SweepWallRight",
			size = Vector3.new(3, 24, 30),
			position = Vector3.new(22, 12, 370),
			travel = Vector3.new(0, 0, 24),
			period = BEAT * 1.5,
			phase = 0.5,
			surface = true,
		},
	},

	blocks = {
		{ position = Vector3.new(-14, 5, 150), size = SLAB, group = "door" },
		{ position = Vector3.new(0, 5, 150), size = SLAB, group = "door" },
		{ position = Vector3.new(14, 5, 150), size = SLAB, group = "door" },
	},

	sockets = {
		{ position = Vector3.new(0, 0, 208), size = Vector3.new(9, 1, 11), group = "door" },
		{ position = Vector3.new(0, 0, 222), size = Vector3.new(9, 1, 11), group = "door" },
		{ position = Vector3.new(0, 0, 236), size = Vector3.new(9, 1, 11), group = "door" },
	},

	boss = {
		id = "furnace",
		kind = "FurnaceCore",
		position = Vector3.new(0, 14, 356),
		closedSeconds = 7,
		openSeconds = 3.5,
		throwInterval = 2.0,
		throwSpeed = 95,
		adds = { kind = "Spark", count = 3, interval = 16, spread = 22 },
	},

	gates = {
		{
			id = "door",
			position = Vector3.new(0, 9, 246),
			size = Vector3.new(34, 18, 3),
			openBy = { kind = "Sockets", group = "door" },
		},
		{
			id = "furnace",
			position = Vector3.new(0, 9, 407),
			size = Vector3.new(34, 18, 3),
			openBy = { kind = "Enemies", group = BossService.GroupFor("furnace") },
		},
	},

	start = { position = Vector3.new(0, 6, 10), size = Vector3.new(30, 10, 6) },
	checkpoints = {
		{ position = Vector3.new(0, 6, 115), size = Vector3.new(30, 10, 6) },
		{ position = Vector3.new(0, 6, 268), size = Vector3.new(30, 10, 6) },
	},
	finish = { position = Vector3.new(0, 6, 430), size = Vector3.new(30, 10, 8) },
}

return layout
