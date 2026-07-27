--!nonstrict
--[[
	Entitlements.luau

	One question — "does this player have X?" — with two answers behind it:

	  • **Game passes** are asked of Roblox and cached briefly. They are never
	    written into the profile, because ownership can change outside the game
	    (a refund, a gift) and a cached-forever copy would be wrong.

	  • **Everything else** — developer product grants, and later season pass
	    rewards or ad rewards — lives in `profile.entitlements` and flows through
	    Grant().

	Grant() is the single door for non-purchase rewards, which is the extension
	point the planned season pass and rewarded video hook into. It refuses to
	grant anything the config has not declared, so a future feature cannot
	quietly invent an entitlement that skips MonetizationConfig's pay-to-win
	check.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local GameConfig = require(Shared.Config.GameConfig)
local MonetizationConfig = require(Shared.Config.MonetizationConfig)
local Net = require(Shared.Net)
local Signal = require(Shared.Util.Signal)

local DataService = require(script.Parent.Parent.Data.DataService)

local Entitlements = {}

local PASS_CACHE_SECONDS = 120

type PassCache = { [string]: { owned: boolean, at: number } }
local passCache: { [Player]: PassCache } = {}

Entitlements.Changed = Signal.new() -- (player, snapshot)

local function studioCosmeticGrant(key: string): boolean
	if not RunService:IsStudio() or not GameConfig.Debug.GrantCosmeticsInStudio then
		return false
	end
	local product = MonetizationConfig.GamePassByKey[key]
	return product ~= nil and product.category == "Cosmetic"
end

--- Game pass ownership, cached for PASS_CACHE_SECONDS.
function Entitlements.OwnsPass(player: Player, key: string): boolean
	local product = MonetizationConfig.GamePassByKey[key]
	if not product then
		return false
	end

	if studioCosmeticGrant(key) then
		return true
	end

	-- Not yet created in the creator dashboard.
	if product.assetId == 0 then
		return false
	end

	local cache = passCache[player]
	if not cache then
		cache = {}
		passCache[player] = cache
	end

	local entry = cache[key]
	if entry and (os.clock() - entry.at) < PASS_CACHE_SECONDS then
		return entry.owned
	end

	local ok, owned = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, product.assetId)
	end)

	if not ok then
		warn(`[Entitlements] ownership check failed for {player.Name}/{key}: {owned}`)
		return entry ~= nil and entry.owned
	end

	cache[key] = { owned = owned, at = os.clock() }
	return owned
end

--- True for a pass the player owns, or a stored grant.
function Entitlements.Has(player: Player, key: string): boolean
	if MonetizationConfig.GamePassByKey[key] then
		return Entitlements.OwnsPass(player, key)
	end

	local profile = DataService.Get(player)
	if not profile then
		return false
	end
	return profile.entitlements[key] == true
end

--- Grants a non-purchase entitlement. The only way anything reaches
--- `profile.entitlements`, and it refuses undeclared keys on purpose.
function Entitlements.Grant(player: Player, key: string): boolean
	local product = MonetizationConfig.DeveloperProductByKey[key] or MonetizationConfig.GamePassByKey[key]
	if not product then
		warn(`[Entitlements] refusing to grant undeclared entitlement "{key}"`)
		return false
	end

	local profile = DataService.Get(player)
	if not profile then
		return false
	end

	profile.entitlements[key] = true
	Entitlements.Changed:Fire(player, Entitlements.Snapshot(player))
	return true
end

--- Consumable counters (retry skips, ghost tickets).
function Entitlements.AddConsumable(player: Player, key: string, amount: number): boolean
	local profile = DataService.Get(player)
	if not profile then
		return false
	end
	profile.consumables[key] = (profile.consumables[key] or 0) + amount
	Entitlements.Changed:Fire(player, Entitlements.Snapshot(player))
	return true
end

--- Spends one, returning false if there was nothing to spend.
function Entitlements.ConsumeOne(player: Player, key: string): boolean
	local profile = DataService.Get(player)
	if not profile then
		return false
	end

	local count = profile.consumables[key] or 0
	if count <= 0 then
		return false
	end

	profile.consumables[key] = count - 1
	Entitlements.Changed:Fire(player, Entitlements.Snapshot(player))
	return true
end

--- What the client is allowed to know: which keys are owned, and how many of
--- each consumable are banked.
function Entitlements.Snapshot(player: Player): { passes: { [string]: boolean }, consumables: { [string]: number } }
	local passes: { [string]: boolean } = {}
	for key in MonetizationConfig.GamePassByKey do
		passes[key] = Entitlements.Has(player, key)
	end

	local profile = DataService.Get(player)
	local consumables: { [string]: number } = {}
	if profile then
		for key, count in profile.consumables do
			consumables[key] = count
		end
	end

	return { passes = passes, consumables = consumables }
end

function Entitlements.Invalidate(player: Player)
	passCache[player] = nil
end

--- Records a pass as owned without asking Roblox.
---
--- Only ever called from PromptGamePassPurchaseFinished, and it exists because
--- `UserOwnsGamePassAsync` frequently still answers *false* in the seconds after
--- a purchase completes. Re-querying there would cache that stale false for
--- PASS_CACHE_SECONDS, so a player who had just paid for the colour pack would
--- watch the swatches stay locked for two minutes. The purchase-finished event
--- is the more authoritative signal at that instant; the cache still expires
--- normally afterwards, so a refund is picked up on the next miss.
local function markOwned(player: Player, key: string)
	local cache = passCache[player]
	if not cache then
		cache = {}
		passCache[player] = cache
	end
	cache[key] = { owned = true, at = os.clock() }
end

function Entitlements.Start()
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, passId, wasPurchased)
		if not wasPurchased then
			return
		end

		local product = MonetizationConfig.FindGamePassByAssetId(passId)
		if product then
			markOwned(player, product.key)
			Net.Notify:FireClient(player, { text = `{product.displayName} 구매 완료!`, tone = "Good" })
		else
			-- Unknown asset: no key to mark, so fall back to a re-query.
			Entitlements.Invalidate(player)
		end

		Entitlements.Changed:Fire(player, Entitlements.Snapshot(player))
	end)

	Entitlements.Changed:Connect(function(player: Player, snapshot)
		Net.EntitlementsChanged:FireClient(player, snapshot)
	end)

	Players.PlayerRemoving:Connect(Entitlements.Invalidate)
end

return Entitlements
