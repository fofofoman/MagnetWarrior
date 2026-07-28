--!strict
--[[
	StageConfig.luau
	The full 12-stage roster with medal thresholds.

	**These numbers are generated, not hand-picked.** `tools/estimate_medals.py`
	reads the layout files, measures the route a run has to walk, adds the fixed
	cost of everything that makes a player stop moving (enemies, sockets, gates,
	polarity waits, boss armour cycles), and writes the result here. Re-run it
	after a tuning change rather than guessing:

	    python3 tools/estimate_medals.py            # show the proposed table
	    python3 tools/estimate_medals.py --apply    # write it here

	Its assumptions are deliberately pessimistic — a medal nobody can earn is a
	dead goal, while one that is slightly generous still works. Once the game has
	real players, `MedalCalibration` reports what they actually achieve, which
	beats any static estimate.

	`minPossibleMs` is the anti-cheat floor: below this, no run happened. It is a
	fraction of Gold rather than a raw path-length figure, because
	RunSessionService divides it across the stage's segments — a floor of a few
	seconds would let a clipped segment through at half a second.

	`hasLayout = false` means the stage is rostered but has no geometry yet; the
	stage select shows it as coming soon and the server refuses to start it.
]]

local Types = require(script.Parent.Parent.Types)

local StageConfig = {}

local function seconds(n: number): number
	return math.floor(n * 1000)
end

local definitions: { Types.StageDefinition } = {
	-- ── 1. 튜토리얼 존 ────────────────────────────────────────────────────────
	{
		id = "stage_01_pull",
		order = 1,
		displayName = "인력 시험장",
		kind = "Tutorial",
		description = "왼손 Pull만으로 협곡을 건넌다. 철제 발판을 끌어와 발 밑에 깔아라.",
		allowedActions = { "Pull" },
		medals = { Gold = seconds(29), Silver = seconds(36), Bronze = seconds(46) },
		minPossibleMs = seconds(10),
		checkpointCount = 2,
		originX = 0,
		hasLayout = true,
	},
	{
		id = "stage_02_push",
		order = 2,
		displayName = "척력 시험장",
		kind = "Tutorial",
		description = "오른손 Push만 사용한다. 벽을 밀어 그 반작용으로 몸을 띄워라.",
		allowedActions = { "Push" },
		medals = { Gold = seconds(26), Silver = seconds(32), Bronze = seconds(42) },
		minPossibleMs = seconds(9),
		checkpointCount = 2,
		originX = 2000,
		hasLayout = true,
		requires = "stage_01_pull",
	},

	-- ── 2. 전투 응용 존 ───────────────────────────────────────────────────────
	{
		id = "stage_03_scrapyard",
		order = 3,
		displayName = "고철 처리장",
		kind = "Combat",
		description = "끌어당겨 붙잡고, 밀어서 벽에 처박는다. 충돌 속도가 곧 데미지다.",
		allowedActions = { "Pull", "Push" },
		medals = { Gold = seconds(83), Silver = seconds(104), Bronze = seconds(133) },
		minPossibleMs = seconds(29),
		checkpointCount = 3,
		originX = 4000,
		hasLayout = true,
		requires = "stage_02_push",
	},
	{
		id = "stage_04_crossfire",
		order = 4,
		displayName = "교차 사격장",
		kind = "Combat",
		description = "다수의 적을 동시에 처리한다. 한 놈을 다른 놈에게 던져라.",
		allowedActions = { "Pull", "Push" },
		medals = { Gold = seconds(104), Silver = seconds(130), Bronze = seconds(166) },
		minPossibleMs = seconds(36),
		checkpointCount = 3,
		originX = 6000,
		hasLayout = true,
		requires = "stage_03_scrapyard",
	},
	{
		id = "stage_05_gauntlet",
		order = 5,
		displayName = "자기장 회랑",
		kind = "Combat",
		description = "이동과 전투를 동시에. 벽을 타면서 적을 떨어뜨린다.",
		allowedActions = { "Pull", "Push" },
		medals = { Gold = seconds(104), Silver = seconds(130), Bronze = seconds(166) },
		minPossibleMs = seconds(36),
		checkpointCount = 4,
		originX = 8000,
		hasLayout = true,
		requires = "stage_04_crossfire",
	},

	-- ── 3. 퍼즐 응용 존 ───────────────────────────────────────────────────────
	{
		id = "stage_06_assembly",
		order = 6,
		displayName = "조립 구역",
		kind = "Puzzle",
		description = "흩어진 철제 블록을 소켓에 맞춰 다리를 완성한다.",
		allowedActions = { "Pull", "Push" },
		medals = { Gold = seconds(117), Silver = seconds(146), Bronze = seconds(187) },
		minPossibleMs = seconds(41),
		checkpointCount = 2,
		originX = 10000,
		hasLayout = true,
		requires = "stage_05_gauntlet",
	},
	{
		id = "stage_07_cadence",
		order = 7,
		displayName = "박자 실험실",
		kind = "Puzzle",
		description = "움직이는 자석 벽. 극성이 바뀌는 순간에 맞춰 붙어라.",
		allowedActions = { "Pull", "Push" },
		medals = { Gold = seconds(50), Silver = seconds(62), Bronze = seconds(80) },
		minPossibleMs = seconds(18),
		checkpointCount = 3,
		originX = 12000,
		hasLayout = true,
		requires = "stage_06_assembly",
	},
	{
		id = "stage_08_foundry",
		order = 8,
		displayName = "주조 공장",
		kind = "Puzzle",
		description = "조립 퍼즐과 타이밍 퍼즐의 결합. 실수하면 처음부터.",
		allowedActions = { "Pull", "Push" },
		medals = { Gold = seconds(159), Silver = seconds(199), Bronze = seconds(254) },
		minPossibleMs = seconds(56),
		checkpointCount = 4,
		originX = 14000,
		hasLayout = true,
		requires = "stage_07_cadence",
	},

	-- ── 4. 보스전 ─────────────────────────────────────────────────────────────
	{
		id = "stage_09_miniboss",
		order = 9,
		displayName = "미니보스: 폐기물 수집기",
		kind = "Boss",
		description = "장갑이 열리는 순간에만 자석이 통한다. 패턴을 읽어라.",
		allowedActions = { "Pull", "Push" },
		medals = { Gold = seconds(65), Silver = seconds(81), Bronze = seconds(104) },
		minPossibleMs = seconds(23),
		checkpointCount = 1,
		originX = 16000,
		hasLayout = true,
		requires = "stage_08_foundry",
	},
	{
		id = "stage_10_finalboss",
		order = 10,
		displayName = "최종보스: 대자석로",
		kind = "Boss",
		description = "이동, 전투, 퍼즐 전부. 배운 것을 전부 쓰지 않으면 이길 수 없다.",
		allowedActions = { "Pull", "Push" },
		medals = { Gold = seconds(176), Silver = seconds(220), Bronze = seconds(282) },
		minPossibleMs = seconds(62),
		checkpointCount = 2,
		originX = 18000,
		hasLayout = true,
		requires = "stage_09_miniboss",
	},

	-- ── 5. 확장 (클리어 후 도전) ──────────────────────────────────────────────
	-- 원래 "확장 여유분"으로 비워둔 슬롯이었다. 채워 넣어도 확장 여지는 줄지 않는다 —
	-- 로스터는 그냥 배열이라 13번 이후를 덧붙이는 데 아무 제약이 없다.
	{
		id = "stage_11_extra",
		order = 11,
		displayName = "무중력 격납고",
		kind = "Extra",
		description = "바닥이 없다. 벽만 있다. 붙어 있지 않으면 떨어진다.",
		allowedActions = { "Pull", "Push" },
		medals = { Gold = seconds(56), Silver = seconds(70), Bronze = seconds(90) },
		minPossibleMs = seconds(20),
		checkpointCount = 3,
		originX = 20000,
		hasLayout = true,
		requires = "stage_10_finalboss",
	},
	{
		id = "stage_12_extra",
		order = 12,
		displayName = "폐기 라인",
		kind = "Extra",
		description = "전 구간 이동식. 멈추면 떨어진다.",
		allowedActions = { "Pull", "Push" },
		medals = { Gold = seconds(105), Silver = seconds(131), Bronze = seconds(168) },
		minPossibleMs = seconds(37),
		checkpointCount = 3,
		originX = 22000,
		hasLayout = true,
		requires = "stage_11_extra",
	},
}

StageConfig.Definitions = definitions

local byId: { [string]: Types.StageDefinition } = {}
for _, definition in definitions do
	assert(byId[definition.id] == nil, `duplicate stage id: {definition.id}`)
	assert(
		definition.medals.Gold < definition.medals.Silver and definition.medals.Silver < definition.medals.Bronze,
		`medal thresholds for {definition.id} must be strictly increasing (gold fastest)`
	)
	assert(
		definition.minPossibleMs < definition.medals.Gold,
		`minPossibleMs for {definition.id} must be below the gold threshold`
	)
	byId[definition.id] = definition
end

StageConfig.ById = byId

function StageConfig.Get(stageId: string): Types.StageDefinition?
	return byId[stageId]
end

--- Ordered list, useful for stage select.
function StageConfig.Ordered(): { Types.StageDefinition }
	local copy = table.clone(definitions)
	table.sort(copy, function(a, b)
		return a.order < b.order
	end)
	return copy
end

--- Which medal a time earns. Ties count as the better medal.
function StageConfig.MedalFor(stageId: string, timeMs: number): Types.MedalTier
	local definition = byId[stageId]
	if not definition then
		return "None"
	end
	if timeMs <= definition.medals.Gold then
		return "Gold"
	elseif timeMs <= definition.medals.Silver then
		return "Silver"
	elseif timeMs <= definition.medals.Bronze then
		return "Bronze"
	end
	return "None"
end

local medalRank: { [Types.MedalTier]: number } = {
	None = 0,
	Bronze = 1,
	Silver = 2,
	Gold = 3,
}

function StageConfig.MedalRank(medal: Types.MedalTier): number
	return medalRank[medal] or 0
end

function StageConfig.IsActionAllowed(stageId: string, action: Types.MagnetAction): boolean
	local definition = byId[stageId]
	if not definition then
		-- Outside a stage (hub, free roam) both hands work.
		return true
	end
	return table.find(definition.allowedActions, action) ~= nil
end

return StageConfig
