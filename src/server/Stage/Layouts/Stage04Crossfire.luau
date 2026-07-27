--!nonstrict
--[[
	Stage04Crossfire.luau — 교차 사격장 (Pull + Push, combat)

	"한 놈을 다른 놈에게 던져라." Stage 3 taught you to throw scrap at enemies;
	this one takes most of the scrap away and makes the enemies the ammunition.

	CombatService already supports this — an enemy is a magnetic body like any
	other, so a Pulled drone that gets Pushed into a second drone damages both
	(the victim by impact, the projectile by hitting something solid). What the
	stage supplies is the *reason*: enemies are grouped in tight clusters on
	raised islands, so a single well-aimed throw is worth three separate fights.

	The three rooms escalate the idea:
	  1. one loose drone, one cluster — learn the throw
	  2. two clusters facing each other across a gap — pick a direction
	  3. a crowd with almost no scrap — the enemies are the only ammunition left
]]

local StageBuilder = require(script.Parent.Parent.StageBuilder)

local STEEL = StageBuilder.Palette.Steel
local FLOOR = Color3.fromRGB(80, 86, 96)
local PILLAR = Color3.fromRGB(66, 72, 82)

local magnetic = {}

--- Slam walls down both sides of a room.
local function sideWalls(centreZ: number, halfWidth: number, depth: number, height: number)
	for _, side in { -1, 1 } do
		table.insert(magnetic, {
			name = "SlamWall",
			size = Vector3.new(3, height, depth),
			position = Vector3.new(side * halfWidth, height / 2, centreZ),
			surface = true,
		})
	end
end

sideWalls(24, 38, 76, 22)
sideWalls(116, 38, 76, 22)
sideWalls(210, 44, 84, 24)

-- Raised islands. Enemies spawn on them, which keeps clusters tight and gives
-- a thrown drone somewhere to knock its neighbours off.
local function island(x: number, z: number, y: number, size: number)
	return {
		name = "Island",
		size = Vector3.new(size, 2, size),
		position = Vector3.new(x, y, z),
		color = STEEL,
	}
end

-- Deliberately sparse: two crates in room 1, one in room 2, none in room 3.
for _, spec in
	{
		{ position = Vector3.new(-20, 4, 8), size = Vector3.new(5, 5, 5) },
		{ position = Vector3.new(20, 4, 8), size = Vector3.new(5, 5, 5) },
		{ position = Vector3.new(0, 4, 92), size = Vector3.new(6, 6, 6) },
	}
do
	table.insert(magnetic, {
		name = "ScrapCrate",
		size = spec.size,
		position = spec.position,
		anchored = false,
		density = 0.22,
		material = Enum.Material.CorrodedMetal,
		color = Color3.fromRGB(146, 118, 92),
	})
end

local layout: StageBuilder.Layout = {
	spawn = Vector3.new(0, 6, -14),
	killY = -60,

	parts = {
		{ name = "Room1Floor", size = Vector3.new(76, 2, 76), position = Vector3.new(0, 0, 24), color = FLOOR },
		{ name = "Corridor1", size = Vector3.new(20, 2, 16), position = Vector3.new(0, 0, 68), color = STEEL },
		{ name = "Room2Floor", size = Vector3.new(76, 2, 76), position = Vector3.new(0, 0, 116), color = FLOOR },
		{ name = "Corridor2", size = Vector3.new(20, 2, 16), position = Vector3.new(0, 0, 162), color = STEEL },
		{ name = "Room3Floor", size = Vector3.new(88, 2, 84), position = Vector3.new(0, 0, 210), color = FLOOR },
		{ name = "Corridor3", size = Vector3.new(20, 2, 16), position = Vector3.new(0, 0, 260), color = STEEL },
		{ name = "FinishPad", size = Vector3.new(40, 2, 34), position = Vector3.new(0, 0, 285), color = STEEL },

		-- Room 1: one island holding the cluster.
		island(18, 34, 8, 18),
		{ name = "IslandPillar", size = Vector3.new(6, 8, 6), position = Vector3.new(18, 4, 34), color = PILLAR },

		-- Room 2: two facing islands.
		island(-22, 116, 10, 18),
		{ name = "IslandPillar", size = Vector3.new(6, 10, 6), position = Vector3.new(-22, 5, 116), color = PILLAR },
		island(22, 116, 10, 18),
		{ name = "IslandPillar", size = Vector3.new(6, 10, 6), position = Vector3.new(22, 5, 116), color = PILLAR },

		-- Room 3: a central dais the crowd stands on.
		island(0, 210, 12, 26),
		{ name = "DaisPillar", size = Vector3.new(10, 12, 10), position = Vector3.new(0, 6, 210), color = PILLAR },
	},

	magnetic = magnetic,

	enemies = {
		-- Room 1: the loose drone is the projectile, the island is the target.
		{ kind = "Scrapper", position = Vector3.new(-18, 6, 20), group = "room1" },
		{ kind = "Spark", position = Vector3.new(14, 16, 30), group = "room1" },
		{ kind = "Spark", position = Vector3.new(22, 16, 34), group = "room1" },
		{ kind = "Spark", position = Vector3.new(18, 16, 38), group = "room1" },

		-- Room 2: two clusters, one crate. Throwing across the room is the
		-- efficient answer.
		{ kind = "Spark", position = Vector3.new(-26, 18, 112), group = "room2" },
		{ kind = "Spark", position = Vector3.new(-18, 18, 120), group = "room2" },
		{ kind = "Scrapper", position = Vector3.new(-22, 18, 116), group = "room2" },
		{ kind = "Spark", position = Vector3.new(26, 18, 112), group = "room2" },
		{ kind = "Spark", position = Vector3.new(18, 18, 120), group = "room2" },
		{ kind = "Scrapper", position = Vector3.new(22, 18, 116), group = "room2" },

		-- Room 3: no scrap at all. The Hauler is heavy enough to be a wrecking
		-- ball and slow enough to be caught.
		{ kind = "Hauler", position = Vector3.new(0, 22, 210), group = "room3" },
		{ kind = "Spark", position = Vector3.new(-10, 22, 204), group = "room3" },
		{ kind = "Spark", position = Vector3.new(10, 22, 204), group = "room3" },
		{ kind = "Spark", position = Vector3.new(-10, 22, 216), group = "room3" },
		{ kind = "Spark", position = Vector3.new(10, 22, 216), group = "room3" },
		{ kind = "Scrapper", position = Vector3.new(-28, 6, 210), group = "room3" },
		{ kind = "Scrapper", position = Vector3.new(28, 6, 210), group = "room3" },
	},

	gates = {
		{
			id = "room1",
			position = Vector3.new(0, 9, 62),
			size = Vector3.new(24, 18, 3),
			openBy = { kind = "Enemies", group = "room1" },
		},
		{
			id = "room2",
			position = Vector3.new(0, 9, 154),
			size = Vector3.new(24, 18, 3),
			openBy = { kind = "Enemies", group = "room2" },
		},
		{
			id = "room3",
			position = Vector3.new(0, 9, 252),
			size = Vector3.new(24, 18, 3),
			openBy = { kind = "Enemies", group = "room3" },
		},
	},

	start = { position = Vector3.new(0, 6, -12), size = Vector3.new(30, 10, 6) },
	checkpoints = {
		{ position = Vector3.new(0, 6, 70), size = Vector3.new(18, 10, 6) },
		{ position = Vector3.new(0, 6, 162), size = Vector3.new(18, 10, 6) },
		{ position = Vector3.new(0, 6, 262), size = Vector3.new(18, 10, 6) },
	},
	finish = { position = Vector3.new(0, 6, 287), size = Vector3.new(30, 10, 8) },
}

return layout
