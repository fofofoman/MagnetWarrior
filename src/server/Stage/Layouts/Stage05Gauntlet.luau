--!nonstrict
--[[
	Stage05Gauntlet.luau — 자기장 회랑 (Pull + Push, combat)

	"이동과 전투를 동시에. 벽을 타면서 적을 떨어뜨린다."

	Everything happens over a void, on walkways narrow enough that a Push is a
	kill rather than a nudge. EnemyService kills anything that drops below the
	stage and credits whoever launched it, so "밀어서 떨어뜨리기" is a real
	answer here and not just a way to lose a target.

	The middle section removes the floor entirely: a single long magnet wall
	spans the gap, and the drones hovering in it have nothing under them. You
	cross by clinging and climbing, which means fighting while attached to a
	wall — the two verbs at once, which is the whole point of the stage.
]]

local StageBuilder = require(script.Parent.Parent.StageBuilder)

local STEEL = StageBuilder.Palette.Steel
local WALKWAY = Color3.fromRGB(92, 98, 108)

local layout: StageBuilder.Layout = {
	spawn = Vector3.new(0, 6, -14),
	killY = -60,

	parts = {
		{ name = "SpawnPad", size = Vector3.new(44, 2, 44), position = Vector3.new(0, 0, 0), color = STEEL },

		-- Narrow. A drone shoved sideways here has nowhere to land.
		{ name = "WalkwayA", size = Vector3.new(14, 2, 64), position = Vector3.new(0, 0, 54), color = WALKWAY },
		{ name = "LandingA", size = Vector3.new(34, 2, 28), position = Vector3.new(0, 0, 100), color = STEEL },

		-- z 114..170 is deliberately empty; WallB is the only way across.
		{ name = "LandingB", size = Vector3.new(34, 2, 40), position = Vector3.new(0, 0, 190), color = STEEL },

		{ name = "WalkwayC", size = Vector3.new(14, 2, 60), position = Vector3.new(0, 0, 240), color = WALKWAY },
		{ name = "LandingC", size = Vector3.new(34, 2, 30), position = Vector3.new(0, 0, 285), color = STEEL },

		{ name = "Arena", size = Vector3.new(60, 2, 70), position = Vector3.new(0, 0, 335), color = WALKWAY },
		{ name = "FinishPad", size = Vector3.new(34, 2, 40), position = Vector3.new(0, 0, 390), color = STEEL },
	},

	magnetic = {
		-- One wall per walkway, on one side only: the open side is where the
		-- enemies go.
		{ name = "WallA", size = Vector3.new(3, 24, 64), position = Vector3.new(-12, 12, 54), surface = true },
		{ name = "WallC", size = Vector3.new(3, 24, 60), position = Vector3.new(-12, 12, 240), surface = true },

		-- The crossing. Long, tall, and the only solid thing in the gap.
		{ name = "WallB", size = Vector3.new(3, 34, 64), position = Vector3.new(12, 17, 142), surface = true },

		-- Arena slam walls.
		{ name = "ArenaWall", size = Vector3.new(3, 22, 70), position = Vector3.new(-32, 11, 335), surface = true },
		{ name = "ArenaWall", size = Vector3.new(3, 22, 70), position = Vector3.new(32, 11, 335), surface = true },

		-- Two crates for the arena, and nothing anywhere else.
		{
			name = "ScrapCrate",
			size = Vector3.new(6, 6, 6),
			position = Vector3.new(-16, 5, 320),
			anchored = false,
			density = 0.22,
			material = Enum.Material.CorrodedMetal,
			color = Color3.fromRGB(146, 118, 92),
		},
		{
			name = "ScrapCrate",
			size = Vector3.new(6, 6, 6),
			position = Vector3.new(16, 5, 320),
			anchored = false,
			density = 0.22,
			material = Enum.Material.CorrodedMetal,
			color = Color3.fromRGB(146, 118, 92),
		},
	},

	enemies = {
		{ kind = "Scrapper", position = Vector3.new(0, 6, 36), group = "walkwayA" },
		{ kind = "Spark", position = Vector3.new(0, 6, 58), group = "walkwayA" },
		{ kind = "Scrapper", position = Vector3.new(0, 6, 78), group = "walkwayA" },

		-- Hovering over nothing. Pushed, they simply keep going.
		{ kind = "Spark", position = Vector3.new(4, 14, 126), group = "crossing" },
		{ kind = "Spark", position = Vector3.new(4, 20, 142), group = "crossing" },
		{ kind = "Spark", position = Vector3.new(4, 14, 158), group = "crossing" },

		{ kind = "Scrapper", position = Vector3.new(0, 6, 222), group = "walkwayC" },
		{ kind = "Hauler", position = Vector3.new(0, 8, 244), group = "walkwayC" },
		{ kind = "Scrapper", position = Vector3.new(0, 6, 264), group = "walkwayC" },

		{ kind = "Hauler", position = Vector3.new(0, 8, 340), group = "arena" },
		{ kind = "Scrapper", position = Vector3.new(-18, 6, 330), group = "arena" },
		{ kind = "Scrapper", position = Vector3.new(18, 6, 330), group = "arena" },
		{ kind = "Spark", position = Vector3.new(-18, 6, 352), group = "arena" },
		{ kind = "Spark", position = Vector3.new(18, 6, 352), group = "arena" },
		{ kind = "Spark", position = Vector3.new(0, 6, 360), group = "arena" },
	},

	gates = {
		{
			id = "walkwayA",
			position = Vector3.new(0, 9, 88),
			size = Vector3.new(34, 18, 3),
			openBy = { kind = "Enemies", group = "walkwayA" },
		},
		{
			id = "crossing",
			position = Vector3.new(0, 9, 212),
			size = Vector3.new(20, 18, 3),
			openBy = { kind = "Enemies", group = "crossing" },
		},
		{
			id = "walkwayC",
			position = Vector3.new(0, 9, 302),
			size = Vector3.new(60, 18, 3),
			openBy = { kind = "Enemies", group = "walkwayC" },
		},
		{
			id = "arena",
			position = Vector3.new(0, 9, 372),
			size = Vector3.new(34, 18, 3),
			openBy = { kind = "Enemies", group = "arena" },
		},
	},

	start = { position = Vector3.new(0, 6, 12), size = Vector3.new(30, 10, 6) },
	checkpoints = {
		{ position = Vector3.new(0, 6, 100), size = Vector3.new(30, 10, 6) },
		{ position = Vector3.new(0, 6, 190), size = Vector3.new(30, 10, 6) },
		{ position = Vector3.new(0, 6, 285), size = Vector3.new(30, 10, 6) },
		{ position = Vector3.new(0, 6, 308), size = Vector3.new(50, 10, 6) },
	},
	finish = { position = Vector3.new(0, 6, 392), size = Vector3.new(30, 10, 8) },
}

return layout
