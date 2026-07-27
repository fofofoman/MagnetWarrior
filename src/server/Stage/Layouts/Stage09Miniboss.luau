--!nonstrict
--[[
	Stage09Miniboss.luau — 미니보스: 폐기물 수집기

	"장갑이 열리는 순간에만 자석이 통한다. 패턴을 읽어라."

	The armour cycle is the whole fight. For six seconds the core is sealed —
	Invulnerable, untagged, completely inert to the magnet — and the boss lobs
	scrap at you. For four seconds the plates retract and the core is a magnetic
	body like any other, which means both magnet verbs finally do something:

	  · Push the scrap it just threw at you back into the exposed core
	  · Pull the core itself hard enough to wrench it out of its cradle

	So the closed phase is not dead time, it is preparation: you spend it
	dodging, and gathering the ammunition the boss keeps handing you.

	The arena is ringed with cling walls. They are an escape route during the
	closed phase, and BossService leads its throws slightly upward, so getting
	off the floor is a real answer rather than a stall.
]]

local StageBuilder = require(script.Parent.Parent.StageBuilder)

local BossService = require(script.Parent.Parent.Parent.Combat.BossService)

local STEEL = StageBuilder.Palette.Steel
local FLOOR = Color3.fromRGB(78, 84, 94)

local magnetic = {}

-- Cling walls on all four sides — this is a closed arena, not a corridor.
for _, wall in
	{
		{ size = Vector3.new(3, 26, 94), position = Vector3.new(-44, 13, 112) },
		{ size = Vector3.new(3, 26, 94), position = Vector3.new(44, 13, 112) },
		{ size = Vector3.new(90, 26, 3), position = Vector3.new(0, 13, 66) },
		{ size = Vector3.new(90, 26, 3), position = Vector3.new(0, 13, 158) },
	}
do
	table.insert(magnetic, {
		name = "ArenaWall",
		size = wall.size,
		position = wall.position,
		surface = true,
	})
end

-- Starting ammunition, so the first open window is not spent empty-handed.
for _, position in
	{
		Vector3.new(-30, 5, 88),
		Vector3.new(30, 5, 88),
		Vector3.new(-30, 5, 140),
		Vector3.new(30, 5, 140),
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
	killY = -60,

	parts = {
		{ name = "SpawnPad", size = Vector3.new(40, 2, 40), position = Vector3.new(0, 0, 0), color = STEEL },
		{ name = "Approach", size = Vector3.new(20, 2, 46), position = Vector3.new(0, 0, 42), color = STEEL },
		{ name = "ArenaFloor", size = Vector3.new(90, 2, 94), position = Vector3.new(0, 0, 112), color = FLOOR },
		{ name = "FinishPad", size = Vector3.new(34, 2, 46), position = Vector3.new(0, 0, 182), color = STEEL },
	},

	magnetic = magnetic,

	boss = {
		id = "collector",
		kind = "CollectorCore",
		-- Raised so the machine body sits on the floor rather than sunk into it.
		position = Vector3.new(0, 13, 122),
		closedSeconds = 6,
		openSeconds = 4,
		throwInterval = 2.6,
		throwSpeed = 82,
	},

	gates = {
		{
			id = "collector",
			position = Vector3.new(0, 9, 161),
			size = Vector3.new(34, 18, 3),
			openBy = { kind = "Enemies", group = BossService.GroupFor("collector") },
		},
	},

	start = { position = Vector3.new(0, 6, 24), size = Vector3.new(18, 10, 6) },
	checkpoints = {
		-- One checkpoint, at the arena mouth: the fight is a single segment, and
		-- dying to the boss should send you back to its start rather than to the
		-- lobby.
		{ position = Vector3.new(0, 6, 60), size = Vector3.new(18, 10, 6) },
	},
	finish = { position = Vector3.new(0, 6, 184), size = Vector3.new(30, 10, 8) },
}

return layout
