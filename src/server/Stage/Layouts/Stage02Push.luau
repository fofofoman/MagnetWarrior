--!nonstrict
--[[
	Stage02Push.luau — 척력 시험장 (Push only)

	Push against something immovable throws *you* in the opposite direction, and
	the two useful cases feel completely different, so the stage teaches both:

	  • **Wall push** — aim backwards at a magnet wall and you are launched
	    forwards. MagnetConfig.SelfPushSpeed (92) with SelfPushUpBias (0.35)
	    works out to roughly 36 studs of horizontal distance, so every gap here
	    is 24-30 studs: comfortably clearable, not walkable.

	  • **Floor push** — aim straight down at a magnet pad and the reaction is
	    pure lift. 92 studs/s against gravity 145 apexes at about 29 studs, so the
	    one vertical step is 24 studs.

	Those two numbers are why the geometry is spaced the way it is. If
	MagnetConfig's push values change, the gap and step sizes here need to move
	with them.
]]

local StageBuilder = require(script.Parent.Parent.StageBuilder)

local STEEL = StageBuilder.Palette.Steel

local layout: StageBuilder.Layout = {
	spawn = Vector3.new(0, 6, -14),
	killY = -60,

	parts = {
		{ name = "SpawnPad", size = Vector3.new(40, 2, 40), position = Vector3.new(0, 0, 0), color = STEEL },

		-- Cleared with a wall push off BackWall. Gap: 30 studs.
		{ name = "PlatformB", size = Vector3.new(44, 2, 44), position = Vector3.new(0, 0, 72), color = STEEL },

		-- Reached with a floor push off BPad. Step up: 24 studs.
		{ name = "PlatformC", size = Vector3.new(36, 2, 36), position = Vector3.new(0, 24, 108), color = STEEL },
		{
			name = "PlatformCPillar",
			size = Vector3.new(10, 24, 10),
			position = Vector3.new(0, 12, 108),
			color = Color3.fromRGB(70, 76, 84),
		},

		-- Cleared with a wall push off CWall. Gap: 14 studs.
		{ name = "PlatformD", size = Vector3.new(44, 2, 50), position = Vector3.new(0, 24, 165), color = STEEL },
		{
			name = "PlatformDPillar",
			size = Vector3.new(12, 24, 12),
			position = Vector3.new(0, 12, 165),
			color = Color3.fromRGB(70, 76, 84),
		},

		-- Cleared with a wall push off DWall. Gap: 24 studs.
		{ name = "FinishPad", size = Vector3.new(36, 2, 36), position = Vector3.new(0, 24, 232), color = STEEL },
		{
			name = "FinishPillar",
			size = Vector3.new(10, 24, 10),
			position = Vector3.new(0, 12, 232),
			color = Color3.fromRGB(70, 76, 84),
		},
	},

	magnetic = {
		-- Kick walls. Each sits at the *back* of the platform it launches from,
		-- so the player has to turn around and aim behind themselves — the whole
		-- point of the mechanic.
		{
			name = "BackWall",
			size = Vector3.new(40, 22, 3),
			position = Vector3.new(0, 11, -22),
			surface = true,
		},
		{
			name = "CWall",
			size = Vector3.new(36, 20, 3),
			position = Vector3.new(0, 35, 90),
			surface = true,
		},
		{
			name = "DWall",
			size = Vector3.new(44, 20, 3),
			position = Vector3.new(0, 35, 139),
			surface = true,
		},

		-- Launch pad: stand on it, aim down, go up.
		{
			name = "BPad",
			size = Vector3.new(20, 1, 20),
			position = Vector3.new(0, 1.5, 86),
			surface = true,
			material = Enum.Material.Neon,
		},
	},

	start = { position = Vector3.new(0, 6, 10), size = Vector3.new(30, 10, 6) },
	checkpoints = {
		{ position = Vector3.new(0, 6, 72), size = Vector3.new(30, 10, 6) },
		{ position = Vector3.new(0, 30, 165), size = Vector3.new(30, 10, 6) },
	},
	finish = { position = Vector3.new(0, 30, 232), size = Vector3.new(30, 10, 8) },
}

return layout
