--!nonstrict
--[[
	MonetizationService.luau

	MarketplaceService wiring: purchase prompts, receipt processing, and applying
	cosmetic choices.

	**The pay-to-win rule is enforced in code, not in review.**
	MonetizationConfig.Validate() runs first thing in Start() and hard-errors if
	any product declares gameplay impact beyond "Convenience". Nothing in this
	file can grant magnet power, alter a timer, or touch a record, and the grant
	table below is the exhaustive list of what a purchase can do.

	**Receipts are idempotent.** Roblox re-delivers a receipt until it is
	acknowledged with Granted, so every receipt id is checked against — and then
	written into — `profile.purchaseHistory` before the grant runs. Without that,
	one purchase can pay out several times.

	**Cosmetic choices are validated server-side.** A client asking to wear
	something it does not own is refused; the accepted value is published as a
	Player attribute so every client can render it without another remote.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local MonetizationConfig = require(Shared.Config.MonetizationConfig)
local Net = require(Shared.Net)
local RateLimiter = require(Shared.Util.RateLimiter)

local DataService = require(script.Parent.Parent.Data.DataService)
local Entitlements = require(script.Parent.Entitlements)

local MonetizationService = {}

local promptLimiter = RateLimiter.new(1, 4)
local cosmeticLimiter = RateLimiter.new(2, 5)

-- ─────────────────────────────────────────────────────────────────────────────
-- Cosmetics
-- ─────────────────────────────────────────────────────────────────────────────

--- The slot table lives in the shared config so the shop UI offers exactly the
--- values this check accepts.
local cosmeticSlots = MonetizationConfig.CosmeticSlots

local function isCosmeticAllowed(player: Player, slotName: string, value: any): boolean
	local slot = cosmeticSlots[slotName]
	if not slot or typeof(value) ~= "string" then
		return false
	end
	if value == slot.default then
		return true -- the free option is always available
	end
	if not table.find(MonetizationConfig.UnlockedValues(slotName), value) then
		return false -- not a value this game sells at all
	end
	return Entitlements.Has(player, slot.passKey)
end

--- Publishes the player's cosmetics as attributes. Attributes replicate to
--- every client automatically, so other players can render your beam colour
--- without a broadcast remote.
local function applyCosmetics(player: Player)
	local profile = DataService.Get(player)
	if not profile then
		return
	end

	for slotName, slot in cosmeticSlots do
		local value = profile.cosmetics[slotName] or slot.default
		-- Re-validate on apply: a pass may have been refunded since it was set.
		if not isCosmeticAllowed(player, slotName, value) then
			value = slot.default
			profile.cosmetics[slotName] = value
		end
		player:SetAttribute(slot.attribute, value)
	end
end

MonetizationService.ApplyCosmetics = applyCosmetics

local function onSetCosmetic(player: Player, payload: any)
	if not cosmeticLimiter:Consume(player) then
		return
	end
	if typeof(payload) ~= "table" then
		return
	end

	local slotName = payload.slot
	local value = payload.value
	local slot = cosmeticSlots[slotName]
	if not slot then
		return
	end

	if not isCosmeticAllowed(player, slotName, value) then
		Net.Notify:FireClient(player, { text = "해당 외형을 보유하고 있지 않습니다.", tone = "Warn" })
		return
	end

	local profile = DataService.Get(player)
	if not profile then
		return
	end

	profile.cosmetics[slotName] = value
	player:SetAttribute(slot.attribute, value)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Grants
-- ─────────────────────────────────────────────────────────────────────────────

--- The complete list of what money can do in this game. Every entry is a
--- cosmetic unlock, a convenience toggle, or a consumable counter. If a future
--- entry here would change how fast a player can finish a stage, it does not
--- belong in this table.
local grants: { [string]: (Player) -> boolean } = {
	SkipRetryWait = function(player)
		return Entitlements.AddConsumable(player, "SkipRetryWait", 1)
	end,
	GhostReplayTicket = function(player)
		return Entitlements.AddConsumable(player, "GhostReplayTicket", 1)
	end,
}

--- Purchases granted in memory this session but not yet durably saved. Keeps a
--- retry from applying the same grant twice while the save is still failing.
local grantedThisSession: { [Player]: { [string]: boolean } } = {}

local function processReceipt(receiptInfo): Enum.ProductPurchaseDecision
	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	if not player then
		-- They left before we could grant. NotProcessedYet keeps the receipt
		-- alive so it is delivered again next session.
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local profile = DataService.Get(player)
	if not profile then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local purchaseKey = tostring(receiptInfo.PurchaseId)
	if profile.purchaseHistory[purchaseKey] then
		-- Already granted; acknowledging stops the redelivery loop.
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	local product = MonetizationConfig.FindDeveloperProductByAssetId(receiptInfo.ProductId)
	if not product then
		warn(`[Monetization] receipt for unknown product {receiptInfo.ProductId}`)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local grant = grants[product.key]
	if not grant then
		warn(`[Monetization] no grant handler for "{product.key}"`)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local applied = grantedThisSession[player]
	if not applied then
		applied = {}
		grantedThisSession[player] = applied
	end

	-- Apply the grant at most once, even across retries of a failing save.
	if not applied[purchaseKey] then
		local ok, granted = pcall(grant, player)
		if not ok or not granted then
			warn(`[Monetization] grant failed for {player.Name}/{product.key}: {granted}`)
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
		applied[purchaseKey] = true
	end

	-- Only acknowledge once the receipt is durably recorded. If the save fails
	-- we leave the receipt unacknowledged so Roblox redelivers it — and because
	-- nothing was persisted, redelivery in a later session is the correct
	-- outcome rather than a double payout.
	profile.purchaseHistory[purchaseKey] = true
	local saved = DataService.Save(player, false)
	if not saved and not DataService.IsUsingFallback() then
		profile.purchaseHistory[purchaseKey] = nil
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	applied[purchaseKey] = nil

	Net.Notify:FireClient(player, { text = `{product.displayName} 지급 완료!`, tone = "Good" })
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Prompts
-- ─────────────────────────────────────────────────────────────────────────────

local function onRequestPurchase(player: Player, payload: any)
	if not promptLimiter:Consume(player) then
		return
	end
	if typeof(payload) ~= "table" or typeof(payload.productKey) ~= "string" then
		return
	end

	local key = payload.productKey

	local pass = MonetizationConfig.GamePassByKey[key]
	if pass then
		if pass.assetId == 0 then
			Net.Notify:FireClient(player, { text = "아직 판매 준비 중입니다.", tone = "Warn" })
			return
		end
		if Entitlements.Has(player, key) then
			Net.Notify:FireClient(player, { text = "이미 보유 중입니다.", tone = "Info" })
			return
		end
		MarketplaceService:PromptGamePassPurchase(player, pass.assetId)
		return
	end

	local product = MonetizationConfig.DeveloperProductByKey[key]
	if product then
		if product.assetId == 0 then
			Net.Notify:FireClient(player, { text = "아직 판매 준비 중입니다.", tone = "Warn" })
			return
		end
		MarketplaceService:PromptProductPurchase(player, product.assetId)
	end
end

function MonetizationService.Start()
	-- Boot-time guard. Raises if any product declares gameplay impact.
	MonetizationConfig.Validate()

	Entitlements.Start()

	MarketplaceService.ProcessReceipt = processReceipt

	Net.RequestPurchase.OnServerEvent:Connect(function(player, payload)
		local ok, err = pcall(onRequestPurchase, player, payload)
		if not ok then
			warn(`[Monetization] prompt error: {err}`)
		end
	end)

	Net.SetCosmetic.OnServerEvent:Connect(function(player, payload)
		local ok, err = pcall(onSetCosmetic, player, payload)
		if not ok then
			warn(`[Monetization] cosmetic error: {err}`)
		end
	end)

	Net.GetEntitlements.OnServerInvoke = function(player: Player)
		return Entitlements.Snapshot(player)
	end

	DataService.ProfileLoaded:Connect(function(player: Player)
		applyCosmetics(player)
		Net.EntitlementsChanged:FireClient(player, Entitlements.Snapshot(player))
	end)

	Players.PlayerRemoving:Connect(function(player)
		promptLimiter:Release(player)
		cosmeticLimiter:Release(player)
		grantedThisSession[player] = nil
	end)
end

return MonetizationService
