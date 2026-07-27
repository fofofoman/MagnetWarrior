--!strict
--[[
	MonetizationConfig.luau

	Every sellable item in one table, each declaring a `category` and an
	`impact`. `impact` is the pay-to-win guard: the only legal values are
	"None" (pure cosmetic) and "Convenience" (saves time outside a timed run,
	never inside one). `Validate()` runs at server boot and hard-errors if a
	product ever declares anything else — a ranking board is only worth having
	if nobody can buy their way up it.

	Asset ids are 0 until the products are created in the Roblox creator
	dashboard. MonetizationService skips unconfigured entries with a warning
	instead of crashing, so the game runs fine in Studio before any of them
	exist.
]]

local Types = require(script.Parent.Parent.Types)

local MonetizationConfig = {}

-- ─────────────────────────────────────────────────────────────────────────────
-- Game passes — priority 1 (cosmetic) then priority 2 (convenience)
-- ─────────────────────────────────────────────────────────────────────────────

local gamePasses: { Types.ProductDefinition } = {
	-- 1. 코스메틱
	{
		key = "MagnetColorPack",
		assetId = 0,
		displayName = "자기장 컬러 팩",
		description = "Pull/Push 이펙트 색상 8종을 해금합니다.",
		category = "Cosmetic",
		impact = "None",
		cosmetic = {
			unlocksBeamColors = {
				"Crimson",
				"Azure",
				"Toxic",
				"Violet",
				"Solar",
				"Frost",
				"Void",
				"Chrome",
			},
		},
	},
	{
		key = "TrailPack",
		assetId = 0,
		displayName = "이동 트레일 팩",
		description = "고속 이동 시 남는 트레일 이펙트를 해금합니다.",
		category = "Cosmetic",
		impact = "None",
		cosmetic = {
			unlocksTrails = { "Sparks", "Ion", "Magnetite", "Aurora" },
		},
	},
	{
		key = "VictoryPosePack",
		assetId = 0,
		displayName = "승리 포즈 팩",
		-- Says what it actually does. It used to promise "포즈와 이모트", which
		-- would have needed uploaded animations — and until VictoryPose.luau
		-- existed it delivered nothing at all.
		description = "스테이지 클리어 시 재생되는 승리 연출 4종을 해금합니다. 같은 서버의 모두에게 보입니다.",
		category = "Cosmetic",
		impact = "None",
		cosmetic = {
			unlocksPoses = { "Salute", "Hover", "Crush", "Polarity" },
		},
	},

	-- 2. 편의
	{
		key = "CheckpointSave",
		assetId = 0,
		displayName = "체크포인트 저장",
		description = "서버를 나갔다 와도 마지막 체크포인트에서 재개합니다. 기록에는 영향을 주지 않습니다.",
		category = "Convenience",
		impact = "Convenience",
	},
	{
		key = "VipServer",
		assetId = 0,
		displayName = "VIP 프라이빗 서버",
		description = "친구들과 단독 서버에서 연습할 수 있습니다.",
		category = "Convenience",
		impact = "Convenience",
	},
}

-- ─────────────────────────────────────────────────────────────────────────────
-- Developer products — priority 3 (consumables)
-- ─────────────────────────────────────────────────────────────────────────────

local developerProducts: { Types.ProductDefinition } = {
	{
		key = "SkipRetryWait",
		assetId = 0,
		displayName = "즉시 재시도",
		description = "사망 후 리스폰 대기시간을 건너뜁니다.",
		category = "Consumable",
		impact = "Convenience",
	},
	{
		key = "GhostReplayTicket",
		assetId = 0,
		displayName = "고스트 리플레이 열람권",
		description = "상위 랭커의 주행 고스트를 1회 열람합니다.",
		category = "Consumable",
		impact = "None",
	},
}

MonetizationConfig.GamePasses = gamePasses
MonetizationConfig.DeveloperProducts = developerProducts

-- Key indexes, built here rather than at the bottom of the file because the
-- cosmetic helpers below close over them.
local passByKey: { [string]: Types.ProductDefinition } = {}
for _, product in gamePasses do
	passByKey[product.key] = product
end

local productByKey: { [string]: Types.ProductDefinition } = {}
for _, product in developerProducts do
	productByKey[product.key] = product
end

MonetizationConfig.GamePassByKey = passByKey
MonetizationConfig.DeveloperProductByKey = productByKey

-- ─────────────────────────────────────────────────────────────────────────────
-- Cosmetic slots
-- ─────────────────────────────────────────────────────────────────────────────

--- Shared so the shop UI and the server's ownership check read the same table.
--- `attribute` is the Player attribute the accepted value is published to;
--- attributes replicate on their own, which is how other clients see your
--- cosmetics without a broadcast remote.
export type CosmeticSlot = {
	order: number,
	displayName: string,
	attribute: string,
	default: string,
	passKey: string,
	unlockField: string,
}

local cosmeticSlots: { [string]: CosmeticSlot } = {
	beamColor = {
		order = 1,
		displayName = "자기장 색상",
		attribute = "BeamColor",
		default = "Default",
		passKey = "MagnetColorPack",
		unlockField = "unlocksBeamColors",
	},
	trail = {
		order = 2,
		displayName = "이동 트레일",
		attribute = "Trail",
		default = "None",
		passKey = "TrailPack",
		unlockField = "unlocksTrails",
	},
	pose = {
		order = 3,
		displayName = "승리 포즈",
		attribute = "Pose",
		default = "None",
		passKey = "VictoryPosePack",
		unlockField = "unlocksPoses",
	},
}

MonetizationConfig.CosmeticSlots = cosmeticSlots

--- Display names for cosmetic values. The values themselves are internal keys —
--- they are what the client sends, what the server validates and what gets
--- written to the profile, so they stay stable English identifiers. Without this
--- the 외형 tab showed a Korean-speaking player a grid of buttons reading
--- "Salute", "Crimson", "Magnetite".
local cosmeticLabels: { [string]: string } = {
	-- 공통
	Default = "기본",
	None = "없음",

	-- 자기장 색상
	Crimson = "크림슨",
	Azure = "애저",
	Toxic = "톡식",
	Violet = "바이올렛",
	Solar = "솔라",
	Frost = "프로스트",
	Void = "보이드",
	Chrome = "크롬",

	-- 이동 트레일
	Sparks = "스파크",
	Ion = "이온",
	Magnetite = "마그네타이트",
	Aurora = "오로라",

	-- 승리 연출
	Salute = "경례",
	Hover = "부양",
	Crush = "압쇄",
	Polarity = "극성",
}

MonetizationConfig.CosmeticLabels = cosmeticLabels

--- Falls back to the raw key so a value added without a label still renders.
function MonetizationConfig.LabelFor(value: string): string
	return cosmeticLabels[value] or value
end

--- Slot names in display order.
function MonetizationConfig.OrderedCosmeticSlots(): { string }
	local names = {}
	for name in cosmeticSlots do
		table.insert(names, name)
	end
	table.sort(names, function(a, b)
		return cosmeticSlots[a].order < cosmeticSlots[b].order
	end)
	return names
end

--- The values a slot's pass unlocks, excluding the free default.
function MonetizationConfig.UnlockedValues(slotName: string): { string }
	local slot = cosmeticSlots[slotName]
	if not slot then
		return {}
	end
	local product = passByKey[slot.passKey]
	if not product or not product.cosmetic then
		return {}
	end
	return product.cosmetic[slot.unlockField] or {}
end

--- Everything selectable in a slot: the free default first, then the paid ones.
function MonetizationConfig.CosmeticOptions(slotName: string): { string }
	local slot = cosmeticSlots[slotName]
	if not slot then
		return {}
	end
	local options = { slot.default }
	for _, value in MonetizationConfig.UnlockedValues(slotName) do
		table.insert(options, value)
	end
	return options
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Extension points (not implemented yet, deliberately)
-- ─────────────────────────────────────────────────────────────────────────────

--- Season pass and rewarded video are out of scope for this phase. They are
--- listed here so the shape they will plug into is fixed now: a season pass is
--- just another game pass whose entitlement unlocks cosmetic tracks, and a
--- rewarded ad is a non-purchase grant that flows through the same
--- Entitlements.Grant path. Neither may ever carry impact ~= "None".
MonetizationConfig.PlannedRevenueStreams = {
	SeasonPass = { enabled = false, allowedImpact = "None" },
	RewardedVideo = { enabled = false, allowedImpact = "None" },
}

local legalImpacts: { [string]: boolean } = {
	None = true,
	Convenience = true,
}

--- Called once at server boot. Raises rather than warns: shipping a pay-to-win
--- product by accident should stop the server, not produce a log line.
function MonetizationConfig.Validate()
	local seenKeys: { [string]: boolean } = {}
	local seenAssets: { [number]: string } = {}

	local function check(list: { Types.ProductDefinition }, label: string)
		for _, product in list do
			assert(not seenKeys[product.key], `duplicate product key: {product.key}`)
			seenKeys[product.key] = true

			assert(
				legalImpacts[product.impact],
				`[PAY-TO-WIN GUARD] {label} "{product.key}" declares impact "{product.impact}". `
					.. `Only "None" and "Convenience" are sellable — anything that changes magnet power, `
					.. `run timing or scoring is banned.`
			)

			if product.category == "Cosmetic" then
				assert(
					product.impact == "None",
					`[PAY-TO-WIN GUARD] cosmetic "{product.key}" must have impact "None"`
				)
			end

			if product.assetId ~= 0 then
				local owner = seenAssets[product.assetId]
				assert(owner == nil, `asset id {product.assetId} used by both {owner} and {product.key}`)
				seenAssets[product.assetId] = product.key
			end
		end
	end

	check(gamePasses, "game pass")
	check(developerProducts, "developer product")

	for name, stream in MonetizationConfig.PlannedRevenueStreams do
		assert(legalImpacts[stream.allowedImpact], `planned stream {name} declares an illegal impact`)
	end
end

function MonetizationConfig.FindDeveloperProductByAssetId(assetId: number): Types.ProductDefinition?
	for _, product in developerProducts do
		if product.assetId == assetId then
			return product
		end
	end
	return nil
end

function MonetizationConfig.FindGamePassByAssetId(assetId: number): Types.ProductDefinition?
	for _, product in gamePasses do
		if product.assetId == assetId then
			return product
		end
	end
	return nil
end

return MonetizationConfig
