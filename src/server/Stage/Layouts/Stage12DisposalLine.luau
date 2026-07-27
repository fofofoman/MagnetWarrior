--!nonstrict
--[[
	Stage12DisposalLine.luau — 폐기 라인 (post-game challenge)

	"멈추면 떨어진다."

	Where stage 11 removes the floor, this one removes standing still. The
	opening is a chain of three ferries whose phases are staggered, so each
	transfer only exists for part of the cycle: arrive late at a handoff and the
	next wall has already left.

	The middle section is the campaign's assembly puzzle done on a clock — the
	bridge you build is the only way onward, and the drones waiting past the gate
	do not wait politely.

	Deliberately the last stage in the roster and the only one gated behind the
	final boss. Nothing here is a new mechanic; the ask is doing all of them
	without a pause.
]]

local StageBuilder = require(script.Parent.Parent.StageBuilder)

local STEEL = StageBuilder.Palette.Steel
local FLOOR = Color3.fromRGB(84, 90, 99)
local LEDGE = Color3.fromRGB(96, 104, 114)

local BEAT = 8
local SLAB = Vector3.new(10, 2, 12)

local layout: StageBuilder.Layout = {
	spawn = Vector3.new(0, 6, -14),
	killY = -50,

	parts = {
		{ name = "SpawnPad", size = Vector3.new(36, 2, 36), position = Vector3.new(0, 0, 0), color = STEEL },

		-- Landing after the ferry chain.
		{ name = "Platform1", size = Vector3.new(30, 2, 36), position = Vector3.new(0, 0, 122), color = STEEL },

		-- Assembly room, flush against the landing.
		{ name = "PuzzlePad", size = Vector3.new(44, 2, 60), position = Vector3.new(0, 0, 170), color = FLOOR },
		{ name = "SupplyLedge", size = Vector3.new(36, 2, 12), position = Vector3.new(0, 3, 152), color = LEDGE },

		-- Reached across the bridge the player builds.
		{ name = "Platform3", size = Vector3.new(32, 2, 38), position = Vector3.new(0, 0, 265), color = FLOOR },
		{ name = "Landing", size = Vector3.new(20, 2, 16), position = Vector3.new(0, 0, 292), color = STEEL },

		{ name = "FinishPad", size = Vector3.new(32, 2, 40), position = Vector3.new(0, 0, 350), color = STEEL },
	},

	magnetic = {
		-- Two crates for the room past the gate, and nothing before it.
		{
			name = "ScrapCrate",
			size = Vector3.new(6, 6, 6),
			position = Vector3.new(-12, 5, 256),
			anchored = false,
			density = 0.22,
			material = Enum.Material.CorrodedMetal,
			color = Color3.fromRGB(146, 118, 92),
		},
		{
			name = "ScrapCrate",
			size = Vector3.new(6, 6, 6),
			position = Vector3.new(12, 5, 256),
			anchored = false,
			density = 0.22,
			material = Enum.Material.CorrodedMetal,
			color = Color3.fromRGB(146, 118, 92),
		},
	},

	kinetics = {
		-- The chain. Phases 0.75 / 0.25 / 0.75 put neighbouring ferries on
		-- opposite legs of the same beat, so each handoff is a moment rather
		-- than a standing invitation.
		{
			name = "Ferry1",
			size = Vector3.new(16, 26, 3),
			position = Vector3.new(0, 14, 40),
			travel = Vector3.new(0, 0, 20),
			period = BEAT,
			phase = 0.75,
			surface = true,
		},
		{
			name = "Ferry2",
			size = Vector3.new(16, 26, 3),
			position = Vector3.new(0, 14, 70),
			travel = Vector3.new(0, 0, 18),
			period = BEAT,
			phase = 0.25,
			surface = true,
		},
		{
			name = "Ferry3",
			size = Vector3.new(16, 26, 3),
			position = Vector3.new(0, 14, 98),
			travel = Vector3.new(0, 0, 16),
			period = BEAT,
			phase = 0.75,
			surface = true,
		},

		-- The last crossing, and the only one that also pulses: board late and
		-- it drops you halfway.
		{
			name = "Ferry4",
			size = Vector3.new(16, 26, 3),
			position = Vector3.new(0, 14, 318),
			travel = Vector3.new(0, 0, 16),
			period = BEAT,
			phase = 0.75,
			pulses = true,
			dutyCycle = 0.65,
			pulsePhase = 0.3,
			surface = true,
		},
	},

	blocks = {
		{ position = Vector3.new(-14, 5, 152), size = SLAB, group = "bridge" },
		{ position = Vector3.new(0, 5, 152), size = SLAB, group = "bridge" },
		{ position = Vector3.new(14, 5, 152), size = SLAB, group = "bridge" },
	},

	sockets = {
		{ position = Vector3.new(0, 0, 212), size = Vector3.new(9, 1, 11), group = "bridge" },
		{ position = Vector3.new(0, 0, 226), size = Vector3.new(9, 1, 11), group = "bridge" },
		{ position = Vector3.new(0, 0, 240), size = Vector3.new(9, 1, 11), group = "bridge" },
	},

	enemies = {
		{ kind = "Scrapper", position = Vector3.new(-12, 6, 262), group = "final" },
		{ kind = "Scrapper", position = Vector3.new(12, 6, 262), group = "final" },
		{ kind = "Spark", position = Vector3.new(0, 6, 274), group = "final" },
		{ kind = "Spark", position = Vector3.new(-10, 6, 274), group = "final" },
		{ kind = "Hauler", position = Vector3.new(0, 8, 254), group = "final" },
	},

	gates = {
		{
			id = "bridge",
			position = Vector3.new(0, 9, 248),
			size = Vector3.new(32, 18, 3),
			openBy = { kind = "Sockets", group = "bridge" },
		},
		{
			id = "final",
			position = Vector3.new(0, 9, 285),
			size = Vector3.new(20, 18, 3),
			openBy = { kind = "Enemies", group = "final" },
		},
	},

	start = { position = Vector3.new(0, 6, 8), size = Vector3.new(28, 10, 6) },
	checkpoints = {
		{ position = Vector3.new(0, 6, 122), size = Vector3.new(26, 10, 6) },
		{ position = Vector3.new(0, 6, 252), size = Vector3.new(28, 10, 6) },
		{ position = Vector3.new(0, 6, 292), size = Vector3.new(16, 10, 6) },
	},
	finish = { position = Vector3.new(0, 6, 350), size = Vector3.new(28, 10, 8) },
}

return layout
