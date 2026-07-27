--!nonstrict
--[[
	RespawnService.luau

	Takes respawning off Roblox's automatic path so there is a wait to skip —
	which is the entire product surface of the "즉시 재시도" developer product.
	The wait is short (GameConfig.RespawnDelay) and skipping it changes nothing
	about a run: the timer only starts when the player re-enters the start
	volume, so a faster retry buys impatience relief, not a better time.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local GameConfig = require(Shared.Config.GameConfig)
local Net = require(Shared.Net)
local RateLimiter = require(Shared.Util.RateLimiter)

local Entitlements = require(script.Parent.Parent.Monetization.Entitlements)

local RespawnService = {}

local respawnLimiter = RateLimiter.new(1, 3)

--- Players waiting to respawn, and the time they became eligible.
local pending: { [Player]: number } = {}

local function respawn(player: Player)
	if not pending[player] or not player.Parent then
		return
	end
	pending[player] = nil
	player:LoadCharacter()
end

local function onDied(player: Player)
	if pending[player] then
		return
	end

	local readyAt = os.clock() + GameConfig.RespawnDelay
	pending[player] = readyAt

	task.delay(GameConfig.RespawnDelay, function()
		-- Only respawn if this is still the same pending request; a skip may
		-- have already consumed it.
		if pending[player] == readyAt then
			respawn(player)
		end
	end)
end

local function onRequestRespawn(player: Player)
	if not respawnLimiter:Consume(player) then
		return
	end
	if not pending[player] then
		return
	end

	if not Entitlements.ConsumeOne(player, "SkipRetryWait") then
		Net.Notify:FireClient(player, { text = "즉시 재시도 이용권이 없습니다.", tone = "Warn" })
		return
	end

	respawn(player)
end

local function watchCharacter(player: Player, character: Model)
	local humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid?
	if not humanoid then
		return
	end
	humanoid.Died:Connect(function()
		onDied(player)
	end)
end

function RespawnService.Start()
	Players.CharacterAutoLoads = false

	local function setup(player: Player)
		player.CharacterAdded:Connect(function(character)
			watchCharacter(player, character)
		end)
		if not player.Character then
			player:LoadCharacter()
		end
	end

	for _, player in Players:GetPlayers() do
		setup(player)
	end
	Players.PlayerAdded:Connect(setup)

	Players.PlayerRemoving:Connect(function(player)
		pending[player] = nil
		respawnLimiter:Release(player)
	end)

	Net.RequestRespawn.OnServerEvent:Connect(function(player)
		local ok, err = pcall(onRequestRespawn, player)
		if not ok then
			warn(`[RespawnService] {err}`)
		end
	end)
end

return RespawnService
