--!nonstrict
--[[
	Stage08Foundry.luau — 주조 공장 (puzzle)

	"조립 퍼즐과 타이밍 퍼즐의 결합. 실수하면 처음부터."

	Stage 6 taught assembly, stage 7 taught tempo. This alternates them, so
	neither skill gets to settle: build, cross on the beat, build again, cross
	again. Four checkpoints mark those four beats of the structure.

	The one genuinely new idea is in room B. Two of its three slabs sit on the
	floor, but the third is on a high ledge reachable only by riding the ferry
	wall — and the slab has to come back down with you. Pull drops an object at
	the hold point in front of the player, so the answer is to ride up, pull the
	slab off its ledge, and let it fall to the room below before following it.
	Assembly and timing in one action rather than in alternating rooms.

	Shares stage 7's tempo on purpose: a player arriving here already knows the
	beat, and re-teaching it would waste their time.
]]

local StageBuilder = require(script.Parent.Parent.StageBuilder)

local STEEL = StageBuilder.Palette.Steel
local LEDGE = Color3.fromRGB(96, 104, 114)
local FLOOR = Color3.fromRGB(84, 90, 99)

local BEAT = 6
local SLAB = Vector3.new(10, 2, 12)

local layout: StageBuilder.Layout = {
	spawn = Vector3.new(0, 6, -14),
	killY = -70,

	parts = {
		{ name = "SpawnPad", size = Vector3.new(40, 2, 40), position = Vector3.new(0, 0, 0), color = STEEL },

		-- ── Room A: assembly ────────────────────────────────────────────────
		{ name = "RoomAFloor", size = Vector3.new(56, 2, 60), position = Vector3.new(0, 0, 48), color = FLOOR },
		{ name = "SupplyA", size = Vector3.new(40, 2, 12), position = Vector3.new(0, 3, 26), color = LEDGE },

		-- Sockets sit over the chasm past room A: z 78..134 is open.
		{ name = "LandingA", size = Vector3.new(34, 2, 34), position = Vector3.new(0, 0, 151), color = STEEL },

		-- ── Crossing 1: on the beat. z 168..238 open. ───────────────────────
		{ name = "LandingB", size = Vector3.new(40, 2, 40), position = Vector3.new(0, 0, 258), color = STEEL },

		-- ── Room B: assembly with a ride ────────────────────────────────────
		{ name = "RoomBFloor", size = Vector3.new(64, 2, 66), position = Vector3.new(0, 0, 311), color = FLOOR },
		{ name = "SupplyB", size = Vector3.new(28, 2, 12), position = Vector3.new(-16, 3, 288), color = LEDGE },
		-- The third slab lives up here.
		{ name = "HighLedge", size = Vector3.new(16, 2, 16), position = Vector3.new(24, 26, 330), color = LEDGE },
		{
			name = "HighLedgeSupport",
			size = Vector3.new(5, 26, 5),
			position = Vector3.new(24, 13, 330),
			color = Color3.fromRGB(70, 76, 84),
		},

		-- Room B's sockets bridge z 344..400.
		{ name = "LandingC", size = Vector3.new(34, 2, 34), position = Vector3.new(0, 0, 417), color = STEEL },

		-- ── Crossing 2. z 434..500 open. ────────────────────────────────────
		{ name = "LandingD", size = Vector3.new(36, 2, 40), position = Vector3.new(0, 0, 520), color = STEEL },
		{ name = "FinishPad", size = Vector3.new(34, 2, 36), position = Vector3.new(0, 0, 558), color = STEEL },
	},

	magnetic = {
		-- A static handhold beside each assembly room, for recovering a botched
		-- pull without losing the whole run.
		{ name = "RecoveryA", size = Vector3.new(3, 26, 40), position = Vector3.new(-30, 13, 48), surface = true },
		{ name = "RecoveryB", size = Vector3.new(3, 26, 44), position = Vector3.new(-34, 13, 311), surface = true },
	},

	kinetics = {
		-- Crossing 1: alternating stretches, same tempo as stage 7.
		{
			name = "BeatWallA",
			size = Vector3.new(3, 30, 38),
			position = Vector3.new(11, 18, 186),
			period = BEAT,
			phase = 0,
			pulses = true,
			dutyCycle = 0.5,
			surface = true,
		},
		{
			name = "BeatWallB",
			size = Vector3.new(3, 30, 38),
			position = Vector3.new(11, 18, 222),
			period = BEAT,
			phase = 0.5,
			pulses = true,
			dutyCycle = 0.5,
			surface = true,
		},

		-- Room B's ferry: rides up to the high ledge and back. Vertical travel,
		-- so this one lifts rather than carries forward.
		{
			name = "LiftWall",
			size = Vector3.new(14, 3, 20),
			position = Vector3.new(24, 15, 312),
			travel = Vector3.new(0, 12, 0),
			period = BEAT * 1.5,
			phase = 0.75,
			surface = true,
		},

		-- Crossing 2: a travelling ferry that dies on its return leg.
		{
			name = "FoundryFerry",
			size = Vector3.new(16, 28, 3),
			position = Vector3.new(0, 17, 467),
			travel = Vector3.new(0, 0, 30),
			period = BEAT * 2,
			phase = 0.75,
			pulses = true,
			dutyCycle = 0.6,
			pulsePhase = 0.3,
			surface = true,
		},
	},

	blocks = {
		-- Room A: three slabs on the supply ledge.
		{ position = Vector3.new(-14, 5, 26), size = SLAB, group = "bridgeA" },
		{ position = Vector3.new(0, 5, 26), size = SLAB, group = "bridgeA" },
		{ position = Vector3.new(14, 5, 26), size = SLAB, group = "bridgeA" },

		-- Room B: two down here…
		{ position = Vector3.new(-22, 5, 288), size = SLAB, group = "bridgeB" },
		{ position = Vector3.new(-8, 5, 288), size = SLAB, group = "bridgeB" },
		-- …and one up on the high ledge, reachable only by the lift.
		{ position = Vector3.new(24, 29, 330), size = SLAB, group = "bridgeB" },
	},

	sockets = {
		{ position = Vector3.new(0, 0, 92), size = Vector3.new(9, 1, 11), group = "bridgeA" },
		{ position = Vector3.new(0, 0, 106), size = Vector3.new(9, 1, 11), group = "bridgeA" },
		{ position = Vector3.new(0, 0, 120), size = Vector3.new(9, 1, 11), group = "bridgeA" },

		{ position = Vector3.new(0, 0, 358), size = Vector3.new(9, 1, 11), group = "bridgeB" },
		{ position = Vector3.new(0, 0, 372), size = Vector3.new(9, 1, 11), group = "bridgeB" },
		{ position = Vector3.new(0, 0, 386), size = Vector3.new(9, 1, 11), group = "bridgeB" },
	},

	gates = {
		{
			id = "bridgeA",
			position = Vector3.new(0, 9, 137),
			size = Vector3.new(34, 18, 3),
			openBy = { kind = "Sockets", group = "bridgeA" },
		},
		{
			id = "bridgeB",
			position = Vector3.new(0, 9, 403),
			size = Vector3.new(34, 18, 3),
			openBy = { kind = "Sockets", group = "bridgeB" },
		},
	},

	-- Molten channels. It is a foundry; the floor should be part of the hazard.
	-- Two per assembly room, running the full width and jumpable, so every trip
	-- between the supply ledge and the sockets crosses them twice. Placed clear
	-- of both supply ledges — the spot you stand on to work is never the spot
	-- that hurts.
	hazards = {
		{ name = "ChannelA1", size = Vector3.new(56, 0.6, 5), position = Vector3.new(0, 1.3, 36) },
		{ name = "ChannelA2", size = Vector3.new(56, 0.6, 5), position = Vector3.new(0, 1.3, 62) },
		{ name = "ChannelB1", size = Vector3.new(64, 0.6, 5), position = Vector3.new(0, 1.3, 300) },
		{ name = "ChannelB2", size = Vector3.new(64, 0.6, 5), position = Vector3.new(0, 1.3, 330) },
	},

	start = { position = Vector3.new(0, 6, 12), size = Vector3.new(30, 10, 6) },
	checkpoints = {
		{ position = Vector3.new(0, 6, 151), size = Vector3.new(30, 10, 6) },
		{ position = Vector3.new(0, 6, 258), size = Vector3.new(34, 10, 6) },
		{ position = Vector3.new(0, 6, 417), size = Vector3.new(30, 10, 6) },
		{ position = Vector3.new(0, 6, 520), size = Vector3.new(30, 10, 6) },
	},
	finish = { position = Vector3.new(0, 6, 558), size = Vector3.new(30, 10, 8) },
}

return layout
