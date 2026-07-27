--!nonstrict
--[[
	Stage03Scrapyard.luau — 고철 처리장 (Pull + Push, combat)

	Three arenas, each gated until it is cleared. The combat verb is a
	combination, not a choice: Pull an enemy or a scrap crate off its path, then
	Push it into something solid. CombatService turns closing speed into damage,
	so the walls are the weapon and the enemies are the ammunition.

	Every arena is ringed with MagneticSurface walls. They serve double duty —
	something to slam enemies into, and something to cling to when three drones
	are converging on you.
]]

local StageBuilder = require(script.Parent.Parent.StageBuilder)

local STEEL = StageBuilder.Palette.Steel
local FLOOR = Color3.fromRGB(84, 90, 99)

--- Side walls only. The arenas are entered and left along Z, so walling those
--- faces would seal the stage shut — the gates handle the exits, and these are
--- purely the surfaces you slam enemies into (and cling to when cornered).
local function arenaWalls(centreZ: number, halfWidth: number, halfDepth: number, height: number)
	local walls = {}
	local thickness = 3

	for _, side in { -1, 1 } do
		table.insert(walls, {
			name = "ArenaWall",
			size = Vector3.new(thickness, height, halfDepth * 2),
			position = Vector3.new(side * halfWidth, height / 2, centreZ),
			surface = true,
		})
	end

	return walls
end

local magnetic = {}
for _, wall in arenaWalls(20, 36, 35, 20) do
	table.insert(magnetic, wall)
end
for _, wall in arenaWalls(100, 36, 35, 20) do
	table.insert(magnetic, wall)
end
for _, wall in arenaWalls(185, 41, 40, 20) do
	table.insert(magnetic, wall)
end

-- Loose scrap: the ammunition. Unanchored and under
-- MagnetConfig.ImmovableMassThreshold, so these fly when pushed.
for _, spec in
	{
		{ position = Vector3.new(-18, 4, 8), size = Vector3.new(5, 5, 5) },
		{ position = Vector3.new(18, 4, 30), size = Vector3.new(5, 5, 5) },
		{ position = Vector3.new(-20, 4, 88), size = Vector3.new(6, 6, 6) },
		{ position = Vector3.new(20, 4, 112), size = Vector3.new(6, 6, 6) },
		{ position = Vector3.new(0, 4, 100), size = Vector3.new(7, 7, 7) },
		{ position = Vector3.new(-24, 4, 170), size = Vector3.new(5, 5, 5) },
		{ position = Vector3.new(24, 4, 200), size = Vector3.new(5, 5, 5) },
		{ position = Vector3.new(0, 4, 185), size = Vector3.new(6, 6, 6) },
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
		{ name = "Arena1Floor", size = Vector3.new(72, 2, 70), position = Vector3.new(0, 0, 20), color = FLOOR },
		{ name = "Corridor1", size = Vector3.new(20, 2, 12), position = Vector3.new(0, 0, 60), color = STEEL },
		{ name = "Arena2Floor", size = Vector3.new(72, 2, 70), position = Vector3.new(0, 0, 100), color = FLOOR },
		{ name = "Corridor2", size = Vector3.new(20, 2, 12), position = Vector3.new(0, 0, 140), color = STEEL },
		{ name = "Arena3Floor", size = Vector3.new(82, 2, 80), position = Vector3.new(0, 0, 185), color = FLOOR },
		{ name = "Corridor3", size = Vector3.new(20, 2, 12), position = Vector3.new(0, 0, 230), color = STEEL },
		{ name = "FinishPad", size = Vector3.new(40, 2, 34), position = Vector3.new(0, 0, 253), color = STEEL },
	},

	magnetic = magnetic,

	enemies = {
		{ kind = "Scrapper", position = Vector3.new(-16, 6, 24), group = "arena1" },
		{ kind = "Scrapper", position = Vector3.new(16, 6, 24), group = "arena1" },
		{ kind = "Scrapper", position = Vector3.new(0, 6, 40), group = "arena1" },

		{ kind = "Scrapper", position = Vector3.new(-18, 6, 92), group = "arena2" },
		{ kind = "Scrapper", position = Vector3.new(18, 6, 92), group = "arena2" },
		{ kind = "Hauler", position = Vector3.new(0, 8, 118), group = "arena2" },

		{ kind = "Spark", position = Vector3.new(-22, 6, 170), group = "arena3" },
		{ kind = "Spark", position = Vector3.new(22, 6, 170), group = "arena3" },
		{ kind = "Spark", position = Vector3.new(-22, 6, 200), group = "arena3" },
		{ kind = "Spark", position = Vector3.new(22, 6, 200), group = "arena3" },
		{ kind = "Scrapper", position = Vector3.new(0, 6, 196), group = "arena3" },
		{ kind = "Hauler", position = Vector3.new(0, 8, 176), group = "arena3" },
	},

	gates = {
		{
			id = "arena1",
			position = Vector3.new(0, 9, 55),
			size = Vector3.new(24, 18, 3),
			openBy = { kind = "Enemies", group = "arena1" },
		},
		{
			id = "arena2",
			position = Vector3.new(0, 9, 135),
			size = Vector3.new(24, 18, 3),
			openBy = { kind = "Enemies", group = "arena2" },
		},
		{
			id = "arena3",
			position = Vector3.new(0, 9, 225),
			size = Vector3.new(24, 18, 3),
			openBy = { kind = "Enemies", group = "arena3" },
		},
	},

	start = { position = Vector3.new(0, 6, -12), size = Vector3.new(30, 10, 6) },
	checkpoints = {
		{ position = Vector3.new(0, 6, 62), size = Vector3.new(18, 10, 6) },
		{ position = Vector3.new(0, 6, 142), size = Vector3.new(18, 10, 6) },
		{ position = Vector3.new(0, 6, 232), size = Vector3.new(18, 10, 6) },
	},
	finish = { position = Vector3.new(0, 6, 255), size = Vector3.new(30, 10, 8) },
}

return layout
