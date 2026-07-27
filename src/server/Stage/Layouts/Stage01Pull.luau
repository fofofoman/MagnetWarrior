--!nonstrict
--[[
	Stage01Pull.luau — 인력 시험장 (Pull only)

	Teaches the two things Pull does, in order:

	  1. Pull on something that will not move pulls *you* instead. Two chasms are
	     crossed by grappling to an anchored magnet block hanging over the far
	     side; the momentum carries you onto the landing.
	  2. Pull on something light brings it to you. One steel block has to be
	     dragged off a side ledge onto a socket to open the mid-stage gate.

	Push is not merely absent from the geometry — StageConfig lists this stage's
	allowedActions as { "Pull" }, so the server refuses the right hand outright.

	Geometry note: the grapple stops once the player is within
	MagnetConfig.ClingRange of the anchor, keeping their inbound velocity. The
	anchors are therefore placed *past* each gap, so letting go drops you onto
	the far platform rather than into it.
]]

local StageBuilder = require(script.Parent.Parent.StageBuilder)

local STEEL = StageBuilder.Palette.Steel

local layout: StageBuilder.Layout = {
	spawn = Vector3.new(0, 6, -14),
	killY = -60,

	parts = {
		-- Start plateau.
		{ name = "SpawnPad", size = Vector3.new(44, 2, 44), position = Vector3.new(0, 0, 0), color = STEEL },
		{
			name = "SpawnRail",
			size = Vector3.new(44, 3, 2),
			position = Vector3.new(0, 2.5, -22),
			color = Color3.fromRGB(70, 76, 84),
		},

		-- Landing after the first chasm; runs up to the gate.
		{ name = "PlatformA", size = Vector3.new(44, 2, 60), position = Vector3.new(0, 0, 80), color = STEEL },

		-- Ledge holding the puzzle block, out of walking reach on purpose.
		{
			name = "SideLedge",
			size = Vector3.new(14, 2, 14),
			position = Vector3.new(30, 10, 72),
			color = Color3.fromRGB(96, 104, 114),
		},
		{
			name = "SideLedgeSupport",
			size = Vector3.new(4, 10, 4),
			position = Vector3.new(30, 5, 72),
			color = Color3.fromRGB(70, 76, 84),
		},

		-- Finish plateau across the second chasm.
		{ name = "FinishPad", size = Vector3.new(40, 2, 40), position = Vector3.new(0, 0, 150), color = STEEL },
	},

	magnetic = {
		-- Anchored, but *not* a MagneticSurface: these are grapple anchors, not
		-- climbable walls, which keeps stage 1 to a single new verb.
		{
			name = "GrappleAnchor1",
			size = Vector3.new(6, 6, 6),
			position = Vector3.new(0, 20, 56),
			material = Enum.Material.Neon,
		},
		{
			name = "GrappleAnchor2",
			size = Vector3.new(6, 6, 6),
			position = Vector3.new(0, 18, 140),
			material = Enum.Material.Neon,
		},
	},

	blocks = {
		{ position = Vector3.new(30, 14, 72), size = Vector3.new(6, 6, 6), group = "gate1" },
	},

	sockets = {
		{ position = Vector3.new(0, 1.5, 74), size = Vector3.new(8, 1, 8), group = "gate1" },
	},

	gates = {
		{
			id = "gate1",
			position = Vector3.new(0, 9, 95),
			size = Vector3.new(44, 16, 3),
			openBy = { kind = "Sockets", group = "gate1" },
		},
	},

	start = { position = Vector3.new(0, 6, 10), size = Vector3.new(30, 10, 6) },
	checkpoints = {
		{ position = Vector3.new(0, 6, 60), size = Vector3.new(30, 10, 6) },
		{ position = Vector3.new(0, 6, 102), size = Vector3.new(30, 10, 6) },
	},
	finish = { position = Vector3.new(0, 6, 150), size = Vector3.new(30, 10, 8) },
}

return layout
