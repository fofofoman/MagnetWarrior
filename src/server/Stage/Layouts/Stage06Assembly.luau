--!nonstrict
--[[
	Stage06Assembly.luau — 조립 구역 (puzzle)

	The assembly puzzle stage. Pull steers an object to a hold point roughly
	MagnetConfig.HoldDistance in front of the player's torso, which makes it
	precise enough to place things deliberately — so this stage is built entirely
	out of that precision.

	Two puzzles:

	  1. **Bridge.** Four slabs are stranded on side ledges over a chasm. Pull
	     each one to the socket in front of you, step onto it, and repeat. The
	     placed slab is what you stand on to reach the next socket, so the
	     solution order is forced by the geometry rather than by a script.

	  2. **Stairs.** Three slabs build a rising staircase. Each socket sits about
	     a torso-height above the last placed slab, which is exactly where the
	     hold point lands when you stand on it.

	PuzzleService anchors a slab and strips its Magnetic tag on placement, so a
	stray Push cannot dismantle a finished bridge from under you.
]]

local StageBuilder = require(script.Parent.Parent.StageBuilder)

local STEEL = StageBuilder.Palette.Steel
local LEDGE = Color3.fromRGB(96, 104, 114)

local SLAB = Vector3.new(10, 2, 12)

local layout: StageBuilder.Layout = {
	spawn = Vector3.new(0, 6, -14),
	killY = -70,

	parts = {
		{ name = "StartPad", size = Vector3.new(40, 2, 44), position = Vector3.new(0, 0, 0), color = STEEL },

		-- Slab ledges, alternating sides across the chasm.
		{ name = "Ledge1", size = Vector3.new(14, 2, 14), position = Vector3.new(26, 3, 30), color = LEDGE },
		{ name = "Ledge2", size = Vector3.new(14, 2, 14), position = Vector3.new(-26, 3, 44), color = LEDGE },
		{ name = "Ledge3", size = Vector3.new(14, 2, 14), position = Vector3.new(26, 3, 58), color = LEDGE },
		{ name = "Ledge4", size = Vector3.new(14, 2, 14), position = Vector3.new(-26, 3, 72), color = LEDGE },

		-- Landing on the far side of the bridge.
		{ name = "FarPad", size = Vector3.new(40, 2, 60), position = Vector3.new(0, 0, 110), color = STEEL },

		-- Staircase slab supply.
		{ name = "SupplyLedge", size = Vector3.new(34, 2, 12), position = Vector3.new(0, 3, 128), color = LEDGE },

		-- Top of the staircase, and the run out to the finish.
		{ name = "TopPad", size = Vector3.new(34, 2, 40), position = Vector3.new(0, 22, 196), color = STEEL },
		{
			name = "TopPillar",
			size = Vector3.new(12, 22, 12),
			position = Vector3.new(0, 11, 196),
			color = Color3.fromRGB(70, 76, 84),
		},
	},

	magnetic = {
		-- A cling wall beside the staircase: not required, but it gives a
		-- recovery option after a mis-thrown slab, and rewards players who
		-- remember stage 2.
		{
			name = "RecoveryWall",
			size = Vector3.new(3, 30, 60),
			position = Vector3.new(-20, 15, 165),
			surface = true,
		},
	},

	blocks = {
		-- Bridge slabs, resting on their ledges.
		{ position = Vector3.new(26, 5, 30), size = SLAB, group = "bridge" },
		{ position = Vector3.new(-26, 5, 44), size = SLAB, group = "bridge" },
		{ position = Vector3.new(26, 5, 58), size = SLAB, group = "bridge" },
		{ position = Vector3.new(-26, 5, 72), size = SLAB, group = "bridge" },

		-- Staircase slabs, stacked on the supply ledge.
		{ position = Vector3.new(-12, 5, 128), size = SLAB, group = "stairs" },
		{ position = Vector3.new(0, 5, 128), size = SLAB, group = "stairs" },
		{ position = Vector3.new(12, 5, 128), size = SLAB, group = "stairs" },
	},

	sockets = {
		-- Bridge: level with the start pad, one stride apart.
		{ position = Vector3.new(0, 0, 34), size = Vector3.new(9, 1, 11), group = "bridge" },
		{ position = Vector3.new(0, 0, 48), size = Vector3.new(9, 1, 11), group = "bridge" },
		{ position = Vector3.new(0, 0, 62), size = Vector3.new(9, 1, 11), group = "bridge" },
		{ position = Vector3.new(0, 0, 76), size = Vector3.new(9, 1, 11), group = "bridge" },

		-- Stairs: each one a step above the last.
		{ position = Vector3.new(0, 6, 150), size = Vector3.new(9, 1, 11), group = "stairs" },
		{ position = Vector3.new(0, 13, 164), size = Vector3.new(9, 1, 11), group = "stairs" },
		{ position = Vector3.new(0, 20, 178), size = Vector3.new(9, 1, 11), group = "stairs" },
	},

	gates = {
		-- Sealed until the bridge is finished, so the chasm cannot be skipped by
		-- a lucky launch off the ledges.
		{
			id = "bridge",
			position = Vector3.new(0, 9, 84),
			size = Vector3.new(40, 18, 3),
			openBy = { kind = "Sockets", group = "bridge" },
		},
	},

	start = { position = Vector3.new(0, 6, 12), size = Vector3.new(30, 10, 6) },
	checkpoints = {
		{ position = Vector3.new(0, 6, 96), size = Vector3.new(30, 10, 6) },
		{ position = Vector3.new(0, 28, 190), size = Vector3.new(28, 10, 6) },
	},
	finish = { position = Vector3.new(0, 28, 210), size = Vector3.new(28, 10, 8) },
}

return layout
