--!nonstrict
--[[
	Stage07Cadence.luau — 박자 실험실 (puzzle, timing)

	"움직이는 자석 벽. 극성이 바뀌는 순간에 맞춰 붙어라."

	Every wall here shares one `period`, so the whole stage runs on a single bar
	of music and the player learns one tempo instead of six. What differs is
	`phase` — which beat each wall takes.

	Three ideas, one per section:

	  1. **주고받기.** Two walls, phase 0 and 0.5, covering consecutive stretches
	     of the same gap. Climb the first while it is live; the moment it dies
	     the second is already live, and you have to have re-grappled by then.

	  2. **타고 가기.** A wall that travels instead of pulsing. Latch on at the
	     near end of its sweep and let it carry you — ClingController keeps the
	     latch point in the wall's object space, so riding is simply clinging to
	     something that happens to be moving.

	  3. **둘 다.** A wall that travels *and* pulses, with `pulsePhase` set so it
	     is only live across the outbound half of its sweep. Board late and it
	     dies under you halfway across.

	Timing note: climbing runs at MagnetConfig.ClingMoveSpeed (16 studs/s), so a
	40-stud stretch is about 2.5s of climb — comfortably inside the 3s live
	window a 6s period at 0.5 duty gives. The margin is the difficulty knob.
]]

local StageBuilder = require(script.Parent.Parent.StageBuilder)

local STEEL = StageBuilder.Palette.Steel

--- One tempo for the whole stage.
local BEAT = 6

local layout: StageBuilder.Layout = {
	spawn = Vector3.new(0, 6, -14),
	killY = -70,

	parts = {
		{ name = "SpawnPad", size = Vector3.new(40, 2, 40), position = Vector3.new(0, 0, 0), color = STEEL },

		-- Section 1 lands here. z 20..92 is open air.
		{ name = "Landing1", size = Vector3.new(34, 2, 36), position = Vector3.new(0, 0, 110), color = STEEL },

		-- Section 2 lands here. z 128..198 is open air.
		{ name = "Landing2", size = Vector3.new(40, 2, 48), position = Vector3.new(0, 0, 222), color = STEEL },

		-- Section 3 lands here. z 246..344 is open air.
		{ name = "Landing3", size = Vector3.new(34, 2, 40), position = Vector3.new(0, 0, 365), color = STEEL },

		{ name = "FinishPad", size = Vector3.new(34, 2, 40), position = Vector3.new(0, 0, 405), color = STEEL },
	},

	kinetics = {
		-- ── 1. 주고받기 ──────────────────────────────────────────────────────
		-- Consecutive stretches of the same wall line, on opposite beats.
		{
			name = "CadenceWallA",
			size = Vector3.new(3, 30, 40),
			position = Vector3.new(10, 18, 38),
			period = BEAT,
			phase = 0,
			pulses = true,
			dutyCycle = 0.5,
			surface = true,
		},
		{
			name = "CadenceWallB",
			size = Vector3.new(3, 30, 40),
			position = Vector3.new(10, 18, 74),
			period = BEAT,
			phase = 0.5,
			pulses = true,
			dutyCycle = 0.5,
			surface = true,
		},

		-- ── 2. 타고 가기 ─────────────────────────────────────────────────────
		-- Always live; the challenge is boarding at the right end of the sweep.
		-- Sweeps z 134..198 around its centre.
		{
			name = "FerryWall",
			size = Vector3.new(16, 30, 3),
			position = Vector3.new(0, 18, 166),
			travel = Vector3.new(0, 0, 32),
			period = BEAT * 2,
			phase = 0.75, -- starts at the near end of the sweep
			surface = true,
		},

		-- ── 3. 둘 다 ────────────────────────────────────────────────────────
		{
			name = "CadenceWallC",
			size = Vector3.new(3, 30, 40),
			position = Vector3.new(12, 18, 268),
			period = BEAT,
			phase = 0,
			pulses = true,
			dutyCycle = 0.45,
			surface = true,
		},
		-- Travels *and* pulses. pulsePhase 0.3 shifts the live window onto the
		-- outbound half of the sweep, so it carries you across and then dies.
		{
			name = "FerryWallLive",
			size = Vector3.new(14, 28, 3),
			position = Vector3.new(0, 17, 310),
			travel = Vector3.new(0, 0, 26),
			period = BEAT * 2,
			phase = 0.75,
			pulses = true,
			dutyCycle = 0.6,
			pulsePhase = 0.3,
			surface = true,
		},
		{
			name = "CadenceWallD",
			size = Vector3.new(3, 30, 36),
			position = Vector3.new(12, 18, 336),
			period = BEAT,
			phase = 0.5,
			pulses = true,
			dutyCycle = 0.45,
			surface = true,
		},
	},

	start = { position = Vector3.new(0, 6, 10), size = Vector3.new(30, 10, 6) },
	checkpoints = {
		{ position = Vector3.new(0, 6, 110), size = Vector3.new(30, 10, 6) },
		{ position = Vector3.new(0, 6, 222), size = Vector3.new(34, 10, 6) },
		{ position = Vector3.new(0, 6, 365), size = Vector3.new(30, 10, 6) },
	},
	finish = { position = Vector3.new(0, 6, 407), size = Vector3.new(30, 10, 8) },
}

return layout
